# Research: Clinician Access to Patient Medical Records (v1, narrow scope)

**Branch**: `009-clinician-record-access` | **Date**: 2026-05-17

> **Trial-context note**: This is a teaching/research trial of speckit, not a real clinical deployment. The governance-review block in the spec checklist is retained as a documentation artefact; it is not gating planning here. In a real engagement this plan would not be written until the clinical-safety case had validated the no-break-glass model.

The spec is resolved as **Q1 = A** (UK NHS), **Q2 = A** (read-only), **Q3 = A** (care-team-membership). 009 picks up several invariant patterns from earlier features in this repo:

- **Byte-equivalent denied/not-found responses** (FR-007) — same shape as 005's and 008's not-found helpers, including `Content-Length` pinning.
- **Audit-write SLA with fail-fast 503** (FR-013) — same in-transaction commit + `OperationalError` pattern as 005's 2-second SLA and 008's 1-second SLA, here at the 2-second budget.
- **OAuth-like bearer-token auth boundary** — bearer-stub introspector, same pattern as the rest of the repo.
- **Append-only audit at code-layer + 8-year retention via code-path absence** — same as 005/007/008.

What's new in 009:

1. **The reading model is itself the authorisation boundary** — there's no creation, no editing, no sharing; the only operation is a care-team-gated read. The whole feature is effectively one decision: "is this clinician on this patient's care team for an active episode?" and the read-or-deny outcome flows from that.
2. **DCB0129/0160 clinical-safety guards** as first-class FRs (FR-014, FR-015) — patient identifier + DoB + allergies + key warnings rendered first in every response. This is a *response-shape* constraint, not a behaviour-on-mutation constraint, and is unique to 009 in this repo.
3. **No patient identifiers in URL paths** (FR-004) — `POST /records/lookup` and `POST /audit/search` with body-only identifiers, instead of `GET /records/{patient_id}`. Common pattern in healthcare APIs; new for this repo.
4. **A second endpoint surface for the IG role** — `POST /audit/search` is only accessible to `audit_officer`. Non-IG callers get the byte-equivalent not-found, so the existence of the IG endpoint does not leak to clinicians.

This document records the technical design choices below. **Most patterns are carried forward from 005 and 008 with minor adjustments**; flagged where they differ.

## HTTP server: stdlib `http.server` (ThreadingHTTPServer)

**Decision**: As in every prior feature in this repo. `http.server.ThreadingHTTPServer` + dispatch in `server.py`. No framework.

**Rationale**: Constitution I. Two POST endpoints with simple JSON bodies.

## Storage: stdlib `sqlite3` with WAL mode

**Decision**: SQLite via `sqlite3` in WAL mode. Same PRAGMAs as 008 (`journal_mode = WAL`, `synchronous = NORMAL`, `temp_store = MEMORY`, `mmap_size = 128 MiB`). Connection opened with `timeout=1.8` (matches 005's 2-second budget) so contended writes fail fast within FR-013's 2-second audit SLA.

Tables: `users` (clinicians + IG officers — same table, distinguished by `role`), `tokens` (auth stub), `patients`, `patient_summaries` (denormalised cache of allergies, warnings, current meds — see "Patient Summary shape" below), `encounters` (per-patient chronological encounters), `care_team_memberships`, `audit_entries`. Six tables; the only invariant-bearing one is `audit_entries` (append-only).

**Rationale**: WAL mode is reused from 008 even though 009 has no explicit performance target — concurrent readers under WAL avoid contention with the (relatively rare) audit-write transaction.

## Authentication: bearer-token stub

**Decision**: As in prior features. `Authorization: Bearer <token>` resolved against a seeded `tokens` table to a `User` with a `clinician_role` ∈ {`doctor`, `nurse`, `pharmacist`, `audit_officer`, `clinical_admin`}. Missing/invalid → `401 unauthenticated` before any handler logic.

**Rationale**: The host product's identity system (NHS smartcard / OIDC) is out of scope per FR-001 / Assumptions. The bearer-stub is the smallest construct that satisfies "the caller is authenticated and we know their clinician_role"; in a real deployment, the stub is swapped for a real identity-provider integration behind the same `TokenIntrospector`-style seam (this repo's 005 / 008 used a Protocol-based seam; here we keep it simpler since 009's interface is internal to the host product, but the swap point is documented).

**No OAuth introspection Protocol seam here**: 009 is integrated *into* a host product (an EHR / clinical system) and authenticates against the host's identity layer; there is no third-party OAuth flow to introspect. The bearer-token stub is documented in `auth.py` with a comment block on how to swap it for the host's actual identity check.

## Authorisation: care-team membership check (the central decision)

**Decision**: The single authorisation predicate is:

```python
def can_access(clinician_id: str, patient_id: str) -> bool:
    """True iff there exists an active care_team_membership row (clinician_id, patient_id, episode_of_care_id)."""
    ...
```

A SQL query against `care_team_memberships`:

```sql
SELECT 1 FROM care_team_memberships
 WHERE clinician_id = ?
   AND patient_id = ?
   AND status = 'active'
   AND (end_date IS NULL OR end_date > ?)
 LIMIT 1
```

The query is executed on **every** record-lookup request, before any record content is touched (FR-006).

**IG role** is a separate predicate: `clinician_role == 'audit_officer'` (no care-team gating; IG sees audit entries for any patient).

Both predicates live in `permissions.py`. A permission decision is computed once per request and fed into the service-layer call.

**Why no caching of the predicate result**: care-team membership can change in seconds (admission → discharge); a 60-second cache would be a clinical-safety failure mode (a discharged-from-team clinician still seeing the record after they should not). The cost of a one-row indexed SQL lookup is ~0.1 ms, well within FR-013's 2-second budget.

## The byte-equivalent denied / not-found response (FR-007)

**Decision**: Same pattern as 005 and 008. A canonical helper:

```python
def not_found_response() -> Response:
    return Response(
        status=404,
        headers={"Content-Type": "application/json; charset=utf-8", "Content-Length": "53"},
        body=b'{"error":"not_found","message":"No such record."}',
    )
```

Used at every "you can't see this" code path:

- `patient_id` doesn't exist.
- `patient_id` exists but the calling clinician is not on the care team.
- The caller is not the IG role attempting `/audit/search`.
- The caller is the IG role but the `patient_id` has no audit entries (and may or may not exist) — same byte-equivalent response so we don't leak whether the patient exists vs whether they exist but have no recorded accesses.

Body bytes, `Content-Type`, and `Content-Length` are identical across all cases (FR-007, SC-003). `Date`-style transport headers are out of scope.

**Why the message is generic** (`"No such record."` rather than `"Patient not found."`): it works equally well for the patient-lookup endpoint and the audit-search endpoint, so the *same* helper covers both. The IG endpoint and the clinician endpoint can share the byte-equivalent shape.

## Patient Summary shape (FR-014, FR-015) — clinical-safety-driven response layout

**Decision**: The successful-read response has a fixed field ordering, with patient verification fields and clinical-safety fields at the **top** of the JSON object. The shape is defined in `clinical_safety.py` as a single `build_patient_summary(patient, encounters) -> dict` function so the rendering rule lives in exactly one place:

```python
{
    # FR-015 — patient verification, top of response
    "patient_id":  "...",
    "date_of_birth": "...",
    "name": "...",

    # FR-014 — clinical-safety, prominently placed
    "allergies": [...],
    "key_warnings": [...],

    # Remainder of summary
    "current_medications": [...],
    "recent_encounters": [...]
}
```

A test in `test_clinical_safety.py` walks the response key order (`response.keys()` on a dict in Python 3.7+ is insertion-ordered) and asserts the first five keys are exactly `["patient_id", "date_of_birth", "name", "allergies", "key_warnings"]`. The host application's UI is responsible for *rendering* this prominently; this feature is responsible for *positioning* the data in the JSON response such that any reasonable renderer hits the safety fields first.

**Rationale**: FR-014 / FR-015 are response-shape constraints, not behaviour constraints. Putting them in one builder function with a position test gives us a single audit point for the DCB0129/0160 case.

## Audit log: always-on, immutable, 2-second SLA, 8-year retention

**Decision**: One audit entry per access attempt, written in the same `BEGIN IMMEDIATE … COMMIT` transaction as the access itself (which, for v1 = read-only, is just a SELECT followed by an INSERT into `audit_entries`):

1. Validate request body.
2. Authenticate; resolve clinician_id / role.
3. Compute permission. **Crucially: build the audit row before deciding whether to return content**. The audit row is INSERTed regardless of outcome (`permitted` / `denied` / `not_found_or_denied`).
4. If permitted, build the patient summary.
5. INSERT audit entry; COMMIT.
6. Return the patient summary or the byte-equivalent not-found response.

The transaction wraps step 5 only (the only write); step 4 is a read. The 2-second SLA covers from request start to response sent.

**Why audit even denied/not-found attempts**: FR-008 mandates it. From an IG perspective, attempted accesses to a patient's record by clinicians not on their care team are exactly the events worth reviewing (insider-threat / browse-curiosity patterns). The audit captures the denied attempt with the patient_id as presented; for a patient_id that doesn't exist, we still log the attempt against the (non-existent) id so a pattern of guessing can be detected.

**Connection timeout 1.8s** maps to FR-013's 2-second budget. Same pattern as 005. Under contention, `BEGIN IMMEDIATE` raises `OperationalError`; we catch and return `503 service_unavailable` with no audit entry written (the transaction rolled back). SC-007 (≤1% of accesses → 503) is the testable invariant.

**8-year retention via code-path absence**: no `UPDATE audit_entries` or `DELETE FROM audit_entries` SQL in `store.py`. Static probe in `test_invariants.py` greps for the strings; runtime probe samples row hashes across snapshots. Same pattern as 005/007/008. **No chained-hash tamper detection in v1** — Q1 = A (UK NHS) doesn't require it at the application layer (it's an infrastructure / operational-security concern), and adding it without governance review would over-scope.

For paediatric records (retention until 25th birthday): handled by the same "no DELETE path" mechanism — the retention floor is satisfied if the floor is *at least* 8 years and the system never deletes. The patient-age-aware retention boundary becomes meaningful only when an operational deletion policy is layered on top, which is out of scope for v1.

## No patient identifiers in URL paths (FR-004)

**Decision**: Both endpoints are `POST` with the `patient_id` in the request body. This is uncommon for a "read" operation (the conventional choice is `GET /records/{id}`), but it's the standard healthcare-API pattern when PHI identifiers are involved, and FR-004 mandates it.

Routes:

- `POST /records/lookup` — body: `{"patient_id": "..."}`
- `POST /audit/search` — body: `{"patient_id": "..."}` (IG role only)

A static probe in `test_no_url_pii.py` greps `server.py`'s routing table for any path that includes `{patient_id}` or `{id}` and fails if one is found.

**What this guards against**: web-server access logs (e.g., nginx default `access.log`), browser histories, screenshots-in-tickets, referrer headers — all of which routinely capture URL paths but not POST bodies. NHS Digital and most EHR vendors follow this pattern for the same reason.

## Endpoint surface: just two

The user description doesn't enumerate endpoints; the spec defines the access shape but not the wire shape. Per the simplicity principle of this repo:

- `POST /records/lookup` — single-record lookup. The *only* endpoint accessible to clinical roles.
- `POST /audit/search` — list audit entries for one patient. Accessible only to `audit_officer`.

There is **no** list-records endpoint, **no** patient-search endpoint, **no** write endpoint, **no** patient-facing endpoint. Each of those would require its own clinical-safety case.

The host application can build a richer UI on top of these two endpoints (search by clinician's open patient list, etc.) but that data comes from the host's other systems, not from this feature.

## Care-team-data feed and fail-closed default

**Decision**: The `care_team_memberships` table is the authoritative source of care-team data inside this feature. It is populated by a (future) data feed from the host product's care-team management system, which is **out of scope** for 009. For the v1 PoC, the seed fixture (`--seed`) creates a small set of memberships for testing.

If the table is empty or the SELECT fails, `can_access` returns `False` — the system fails-closed (denies all clinical accesses). FR-006's check happens on every request, so a stale or missing membership row means no access. This is the safe default for v1; the clinical-safety case must validate that the operational fallback (paper records, IG manual access) is acceptable.

## Project layout: `src/clinician_record_access/` package

**Decision**: New top-level package `src/clinician_record_access/` parallel to the existing seven packages. Tests under `tests/clinician_record_access/`.

**Rationale**: Distinct domain. Sharing a package with any prior feature would be confusing.

**The shared-`_common/` extraction noted at 008 is even more relevant here** — 009 is the eighth near-identical-shape package and reuses (a) the bearer-token boundary, (b) the byte-equivalent not-found helper, (c) the audit-write-with-fail-fast-SLA pattern. Out of scope for 009; flagged.

## What is intentionally NOT researched

These are out of scope per the spec's Out of Scope and Assumptions:

- OAuth 2.0 token issuance / refresh / revocation (host product's responsibility).
- Care-team-data feed pipeline from the host product's care-team management system.
- Patient identity merge / split.
- Full clinical notes, imaging, lab values, mental-health records, sexual-health records, genetic data, social-care records.
- Writes (amend, prescribe, note-write) — Q2 = A.
- Break-glass / emergency access — Q3 = A.
- Patient-facing "view who accessed my record" endpoint (downstream feature; the audit data model supports it).
- Chained-hash audit tamper detection (the FCA-grade pattern in 005).
- Real-time SIEM-style alerting on suspicious access patterns.
- Cross-organisational record sharing; integration with national systems (Spine, NHS App).
- Anonymisation / pseudonymisation for research use.
- Patient consent capture (Q3 = A doesn't use consent as the basis).

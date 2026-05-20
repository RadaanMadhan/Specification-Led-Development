# Research: Hospital Clinical Record Access

**Branch**: `012-hospital-clinical-records` | **Date**: 2026-05-17

> **Governance / trial-context note**: this document treats the spec as the source of truth. The Phase 0 decisions below justify the technical choices independently from any other work in this repository. The governance review described in `spec.md`'s notice remains a prerequisite for real-world implementation; for the purposes of producing the plan, the spec's documented defaults are taken as given.

The spec is fully resolved (no `[NEEDS CLARIFICATION]` markers). This document records the technical design decisions that turn the spec's functional requirements into a concrete plan, with rationale and alternatives.

## HTTP server: stdlib `http.server` (`ThreadingHTTPServer`)

**Decision**: Build the service on `http.server.ThreadingHTTPServer` with a small dispatch in `server.py` that routes `(method, path)` to handler functions in `handlers.py`. No web framework.

**Rationale**: The Python standard library is the project's baseline. Three JSON endpoints with simple request/response shapes do not justify a framework dependency. `ThreadingHTTPServer` provides concurrent request handling adequate for the spec's responsiveness expectations (SC-010: 95% of correct-care-team reads in <3 seconds on a typical workload — well within stdlib capability).

**Alternatives considered**:
- **A web framework** (e.g., a popular Python web framework). Would add ergonomic routing and validation but pull in transitive dependencies for no functional gain at this surface size.
- **Async I/O**. Overkill for a correctness-focused service with low single-process throughput requirements.

## Storage: stdlib `sqlite3` in WAL mode

**Decision**: SQLite via the stdlib `sqlite3` module. File-backed on production-style runs; in-memory for tests. WAL (Write-Ahead Logging) journal mode is enabled at server startup with the following PRAGMAs:

```text
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 134217728;   -- 128 MiB
```

A single process-wide connection is opened with `timeout=1.8` seconds and guarded by a `threading.Lock`. The 1.8-second timeout sits comfortably below the spec's 2-second audit-write budget (FR-015), so a contended `BEGIN IMMEDIATE … COMMIT` raises `sqlite3.OperationalError` within the budget; the handler catches that and returns `503 service_unavailable` with the transaction rolled back.

**Rationale**:
- WAL mode gives concurrent readers full throughput while serialising writers — exactly the mix needed for a read-heavy clinical-record workload with a smaller proportion of note additions.
- A single shared connection avoids per-connection setup overhead (PRAGMAs, opens) and works well under the access workload.
- The 1.8-second timeout is the simplest way to enforce the spec's 2-second SLA: SQLite's `timeout` blocks waiting for the write lock; an `OperationalError` after that interval maps cleanly to the SLA-breach failure mode.

**Alternatives considered**:
- **Default rollback journal**. Blocks readers behind writers — bad for the read-heavy workload.
- **One connection per request**. Higher overhead for no functional gain; harder to guarantee the SLA.
- **A real RDBMS** (e.g., PostgreSQL). Would trivialise the performance story but adds a non-stdlib dependency. The spec's SC-010 target (95% in <3s) is well within SQLite's capability for this workload.

## Authentication: bearer-token stub for v1

**Decision**: Every request authenticates via the HTTP header `Authorization: Bearer <token>`. Tokens are resolved against a seeded `tokens` table to a `User` row. Missing or invalid tokens are rejected with `401 unauthenticated` before any business logic runs — and before any audit entry is written (the spec's FR-001 obligation is to refuse pre-business-logic and pre-audit). In production, the bearer-token resolver is replaced by the host product's identity-provider integration; the swap point is documented in `auth.py` with a clear interface boundary.

**Rationale**: The spec puts the host product's identity system out of scope. A bearer-token stub is the smallest construct that satisfies "the caller is authenticated and we know their role" and reads identically to the conventional production shape, so the real implementation can drop in 1:1 later.

**Alternatives considered**:
- **No auth at all (just trust a header)**. Would satisfy the literal text of FR-001 but reads unclearly; bearer-token is the conventional production shape.
- **A real OIDC / SAML integration**. Out of scope per the spec.

## Authorisation: explicit predicate + role check

**Decision**: A single function `permissions.can_access(user, patient_id) -> bool` implements the care-team-membership predicate from FR-004:

```python
def can_access(user: User, patient_id: str, db: Connection) -> bool:
    if user.role not in {"doctor", "nurse", "pharmacist", "clinical_admin"}:
        return False  # admins and others have no care-team-gated access
    row = db.execute(
        "SELECT 1 FROM care_team_memberships "
        "WHERE clinician_id = ? AND patient_id = ? "
        "AND status = 'active' "
        "AND (end_date IS NULL OR end_date > ?) LIMIT 1",
        (user.id, patient_id, now_iso()),
    ).fetchone()
    return row is not None
```

A separate one-liner `permissions.is_administrator(user)` checks `user.role == "hospital_administrator"` (FR-005, FR-017).

**Rationale**: The single authorisation rule is exactly what the spec mandates — "the patient's assigned care team can read or modify their records". An indexed SQL probe is fast (sub-millisecond on local SQLite) and runs on every request, so revocations take effect immediately. Fail-closed: a missing care-team-membership row denies access, the safest default for a regulated-domain feature.

**Alternatives considered**:
- **Cache the membership predicate result**. Would speed up repeated lookups but introduces staleness in revocation scenarios; the safety risk outweighs the speedup at this workload size.
- **Express the rule as a row-level security policy in SQL** (e.g., via attached views). Would push the check into the query layer but complicates testing and obscures the rule.

## The byte-equivalent unauthorised response (FR-006)

**Decision**: A single canonical response helper `responses.not_found_response()` returns:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8
Content-Length: 48

{"error":"not_found","message":"No such record."}
```

Used at every code path that resolves to "you cannot see this":

- A clinician not on the patient's care team requests a record read or attempts a note addition.
- A hospital administrator attempts the record-read or note-addition endpoints.
- A non-administrator attempts the access-log endpoint.
- Any caller requests a patient identifier that does not correspond to a real patient.

The bytes are pinned: same HTTP status (404), same body bytes (`{"error":"not_found","message":"No such record."}`, 48 bytes), same `Content-Type`, same `Content-Length`. A test in `test_byte_equivalence.py` constructs identifier triples — `(real-non-care-team, real-other-team, fabricated)` — and asserts the response tuple `(status, content_type, content_length, body_bytes)` is identical across every pair.

**Rationale**: The spec's FR-006 makes the byte-equivalence guarantee explicit. Centralising the response in one helper is the simplest way to make the guarantee structurally true; any code path that returns 404 from any of the three endpoints is required to go through this helper, and the test suite verifies it.

**Why 404 and not 403**: The unified envelope is "indistinguishable from non-existence". The natural shape of "this doesn't exist" is 404 not_found; using 403 would explicitly say "exists but not allowed", which leaks the existence of the record. 404 is the right unified envelope.

**Alternatives considered**:
- **Different responses for "doesn't exist" vs "you're not allowed"** — would leak record existence; rejected by FR-006.
- **Constant-time responses** (to defend against timing side channels). Out of scope for v1; the spec's byte-equivalence requirement is about the response body, not response timing. Mentioned here as a future-work consideration if the threat model requires it.

## Audit log: synchronous in-transaction write within a 2-second budget

**Decision**: For every clinical-access attempt — whether the outcome is `permitted`, `denied`, or `not_found_or_denied` — an audit entry is INSERTed in the same `BEGIN IMMEDIATE … COMMIT` transaction as the access decision (and, for `add_note`, the note INSERT). The SQLite connection's `timeout=1.8s` enforces the 2-second SLA: a contended `COMMIT` raises `OperationalError` after at most 1.8 seconds, which the handler maps to `503 service_unavailable` with the transaction rolled back. The 200ms of headroom (1.8s vs 2s) covers response serialisation and network egress.

**Why audit even on denied attempts**: The spec's FR-012 requires "every clinical-record access attempt" to be audited. Denied attempts (e.g., a clinician not on a patient's care team trying to read the record) are the events most worth reviewing for compliance — an audit-only-on-success log would miss exactly the suspicious-access patterns auditors need.

**Why same-transaction with the note INSERT (on `add_note`)**: To preserve the invariant that no observable state change exists without a matching audit entry (FR-012, SC-002). Either both writes succeed and commit, or both fail and roll back. A contended commit returns 503 with no note persisted and no audit entry.

**Append-only enforcement** (FR-014): no `UPDATE audit_entries` or `DELETE FROM audit_entries` SQL appears anywhere in `store.py`. A static grep probe in `test_invariants.py` enforces this; a runtime probe takes hash snapshots of existing audit rows before/after arbitrary endpoint activity and asserts no existing row's content has changed.

**Retention floor**: 7 years per FR-016; enforced by the absence of any DELETE code path against `audit_entries`. Operational retention scheduling beyond 7 years is out of scope.

**Alternatives considered**:
- **Async audit writer (queue + background worker)**. Decouples audit-write latency from the response path; would let the access return in <50ms even under heavy contention. **Rejected** because FR-012/FR-015 require the audit write to be durable before the response is sent — otherwise we could expose state without a matching audit entry on a crash.
- **Logging-based audit** (e.g., stderr / syslog). Loses queryability for the administrator endpoint; the spec requires a queryable per-patient access log (FR-017).

## Administrator response: separate response-builder module

**Decision**: A dedicated module `admin_response.py` is the **sole** code path that builds responses for the administrator endpoint. It deliberately does not import or query any clinical-content table or any clinical-content column from any joined table:

```python
# admin_response.py — FR-018 content-blindness invariant module
#
# Allowed imports: stdlib + the AuditEntry dataclass for shape.
# DELIBERATELY NOT IMPORTED: clinical-notes content, patient-summary content,
#                            encounter narratives, patient demographic name fields.

from .models import AuditEntry

def build_admin_audit_response(patient_id: str, entries: list[AuditEntry]) -> dict:
    """Returns a content-blind administrator response. Every key is from the
    audit-event schema only — no clinical-content keys can appear here."""
    return {
        "patient_id": patient_id,
        "events": [
            {
                "user_id":              e.user_id,
                "user_display_name":    e.user_display_name,
                "user_role":            e.user_role,
                "occurred_at":          e.occurred_at,
                "access_type":          e.access_type,
                "note_id":              e.note_id,    # opaque id only; never note content
                "outcome":              e.outcome,
                "authorisation_basis":  e.authorisation_basis,
            }
            for e in entries
        ],
    }
```

The forbidden-keys list from FR-018 is enforced by two independent probes:

1. **Static probe** in `test_invariants.py` greps `admin_response.py` for any access to columns belonging to clinical-content tables (`clinical_notes.body`, `patient_summaries.*`, `encounters.summary`, `patients.name`/`date_of_birth`). Fails if any such access is present.
2. **Runtime probe** in `test_admin_content_blindness.py` walks every administrator response across every seeded scenario (including patients with long note bodies, allergies, key warnings, recent encounters) and recursively asserts that none of the forbidden keys (`body`, `note_body`, `content`, `note_content`, `allergies`, `key_warnings`, `current_medications`, `recent_encounters`, `encounters`, `summary`, `name`, `patient_name`, `date_of_birth`, `dob`) appear at any depth of the response.

**Why a separate module rather than a flag on a shared response builder**: A flag is a runtime check; a separate module is a static structural guarantee. FR-018 is an absence invariant — proving absence by code-path structure is stronger than proving absence by a runtime conditional. The module split also makes the security audit trivial: a reviewer reads `admin_response.py` (one short file) and confirms by inspection that no clinical content can leak.

**What the administrator can see**: the audit-event metadata enumerated in FR-013 — `user_id`, `user_display_name`, `user_role`, `occurred_at`, `access_type`, `note_id`, `outcome`, `authorisation_basis`. The `note_id` is opaque and reveals no content; it is useful for cross-referencing in operational tooling.

**What the administrator cannot see**: any note body, any allergy or warning detail, any medication name, any encounter narrative, the patient's name, or the patient's date of birth.

## Clinical-record response: separate response-builder module with fixed field order

**Decision**: A dedicated module `clinical_safety.py` is the sole code path that builds the successful patient-record-read response. The response shape is a fixed-order dict (Python 3.7+ dict is insertion-ordered; the order is the order in which the function's return statement populates the dict literal):

```python
# clinical_safety.py — FR-007 / FR-019 / FR-020 field-order enforcer

def build_patient_record(patient: Patient, summary: PatientSummary,
                         encounters: list[Encounter], notes: list[ClinicalNote]) -> dict:
    return {
        # FR-019: patient verification at the very top
        "patient_id":           patient.id,
        "date_of_birth":        patient.date_of_birth,
        "name":                 patient.name,

        # FR-019: clinical-safety fields immediately after verification
        "allergies":            summary.allergies,
        "key_warnings":         summary.key_warnings,

        # Remainder of patient summary
        "current_medications":  summary.current_medications,
        "recent_encounters":    [render_encounter(e) for e in encounters],

        # FR-020: notes count for quick orientation
        "notes_count":          len(notes),

        # Chronological notes list (oldest first)
        "notes":                [render_note(n) for n in notes],
    }
```

A test in `test_clinical_safety.py` walks `list(response.keys())` from a representative seeded read and asserts the prefix is exactly `["patient_id", "date_of_birth", "name", "allergies", "key_warnings"]` (FR-019); a second assertion verifies that `notes_count` appears before `notes` (FR-020). The host application's UI is responsible for *rendering* these prominently; this feature is responsible for *positioning* them in the JSON response so any reasonable renderer hits the safety fields first.

## Endpoints — three POST endpoints, all with body-only patient identifiers

**Decision**: The feature exposes exactly three endpoints. All are `POST` with the patient identifier in the request body, never in the URL path (FR-003):

- `POST /records/lookup` — clinician reads a record. Body: `{"patient_id": "..."}`. Authorised: clinician on the care team.
- `POST /records/notes` — clinician adds a note. Body: `{"patient_id": "...", "body": "...", "note_type": "...", "encounter_date": "..."}`. Authorised: clinician on the care team.
- `POST /audit/search` — administrator views access log for a patient. Body: `{"patient_id": "..."}`. Authorised: `hospital_administrator` role only.

**Rationale**: FR-003 prohibits patient identifiers in URL paths to prevent unintended capture in web-server access logs, browser histories, referrer headers, and screenshots. POST with a body is the natural conventional choice in healthcare APIs for the same reason. The semantic awkwardness of a "POST to read" is accepted as the cost of FR-003 compliance.

**Static probe**: `test_no_url_pii.py` greps `server.py`'s routing table for any path containing `{patient_id}`, `{id}`, `{patient}`, or any placeholder; fails if any is found. The probe also asserts that the routing table contains exactly the three registered POST endpoints.

## Note creation transaction (`POST /records/notes`)

**Decision**: A `POST /records/notes` request runs:

1. Resolve authentication; on failure → `401`, no audit entry.
2. Validate the body (all fields, all together, per FR-009). On failure → `400 validation_error` with `field_errors` array, no audit entry.
3. Open `BEGIN IMMEDIATE` transaction.
4. Look up the patient. Compute the care-team-membership predicate.
5. If patient not found OR caller not on care team: INSERT one audit entry with the appropriate `outcome` (`not_found_or_denied` or `denied`); COMMIT; return the byte-equivalent 404 response.
6. Otherwise: INSERT into `clinical_notes` with snapshotted author display name and role; INSERT one audit entry with `access_type="add_note"`, `note_id=<the new note's id>`, `outcome="permitted"`; COMMIT; return 201 with the new note's id.
7. On `OperationalError` during COMMIT (timeout reached): roll back; return `503 service_unavailable` with no note persisted and no audit entry.

The note INSERT and audit INSERT are atomic — they succeed or fail together. The CHECK constraint on `audit_entries` (see data-model.md) enforces that `note_id` is non-null exactly when `access_type = "add_note" AND outcome = "permitted"`, so a coding error that fails to insert the note but still inserts the audit entry with a non-null `note_id` would be rejected at the schema layer.

## Project layout

**Decision**: All code lives in a new top-level Python package `src/hospital_clinical_records/`. Tests live under `tests/hospital_clinical_records/`. The package's module shape:

```text
src/hospital_clinical_records/
├── __init__.py
├── __main__.py               # Entry point: python -m hospital_clinical_records
├── server.py                 # ThreadingHTTPServer wiring + request dispatch + CLI
├── handlers.py               # Per-endpoint request handlers
├── responses.py              # Canonical not_found_response() helper (FR-006 envelope)
├── auth.py                   # Bearer-token resolution; AuthenticatedCaller dataclass
├── permissions.py            # can_access() care-team predicate; is_administrator() check
├── service.py                # Business logic: lookup_patient, add_note, list_audit_for_patient
├── clinical_safety.py        # build_patient_record() — FR-007/019/020 field-order enforcer
├── admin_response.py         # build_admin_audit_response() — FR-018 content-blindness invariant
├── validation.py             # Field-level validation; reports all errors at once
├── store.py                  # SQLite schema, connection, all SQL (WAL mode)
├── models.py                 # Dataclasses + enums
└── errors.py                 # Typed exceptions
```

13 source modules. The module split places each invariant (or pair of related invariants) into one auditable place: `responses.py` for byte-equivalence, `clinical_safety.py` for field order, `admin_response.py` for content-blindness, `permissions.py` for authorisation, `store.py` for append-only by code-path absence.

## What is intentionally NOT researched

The following are out of scope per the spec and need no design here:

- Authentication implementation (token issuance / refresh / revocation; sign-in UI).
- Identity / role assignment; care-team-roster management (host-product features).
- Emergency-access (break-glass) override.
- Editing or deleting clinical notes after submission.
- Cross-record search; cross-record reporting.
- Notifications (email / push / in-app).
- Real-time SIEM-style alerting on suspicious access patterns.
- Tamper detection on audit entries beyond append-only-by-code-path-absence.
- Patient-facing endpoints.
- National-system integration.
- Encryption at rest / in transit (host-deployment concerns).
- Performance targets beyond the spec's SC-009 (1% allowed 503 rate under the 2s SLA) and SC-010 (95% in <3s for the happy path).

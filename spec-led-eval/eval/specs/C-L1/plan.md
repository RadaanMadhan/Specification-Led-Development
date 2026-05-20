# Implementation Plan: Clinician Access to Patient Medical Records (v1, narrow scope)

**Branch**: `009-clinician-record-access` | **Date**: 2026-05-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/009-clinician-record-access/spec.md`

> ## 📋 Governance notice — documentation artefact only
>
> The spec carries a governance-review block (product owner / clinical-safety officer DCB0129-0160 / legal-and-IG sign-offs) reflecting the regulated-healthcare nature of the domain. The user has explicitly confirmed that this is a **teaching/research trial of speckit, not a real clinical deployment**, and instructed this plan to proceed and retain the governance notice as a documentation artefact.
>
> **In any real engagement, this plan would not be written until the clinical-safety case had validated the no-break-glass model (Q3 = A) for the host product's operational workflows.** That review is what would catch, for example, "actually the host product has no out-of-hours fallback for ward-cover doctors, so the no-break-glass design will fail-deny in genuine emergencies — revisit Q3."
>
> The plan below treats Q1 = A (UK NHS), Q2 = A (read-only), Q3 = A (care-team membership) as locked, and designs accordingly. If a real review later changes any of these, **discard this plan and re-spec** — do not work around the change during implementation.

## Summary

A small Python 3.11+ HTTP backend service exposing exactly two endpoints — `POST /records/lookup` (clinical roles) and `POST /audit/search` (`audit_officer` role only) — implementing a UK NHS narrow-v1 clinician record-lookup feature with **care-team-membership-only authorisation** (no break-glass), **read-only access scope** (no amendment / prescribing / note-writing), **always-on immutable audit** within a 2-second SLA, **byte-equivalent denied/not-found responses** so non-care-team callers cannot infer the existence of a patient, **patient identifiers always in request bodies, never in URL paths**, and **clinical-safety field ordering** (patient identifier + DoB + allergies + key warnings rendered first in every response). Built on the Python standard library only (`http.server`, `sqlite3` in WAL mode with tuned PRAGMAs, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`). The single decisive predicate is `permissions.can_access(clinician_id, patient_id)` — a one-row indexed SQL probe against `care_team_memberships` that runs on every request, before any record content is touched, with fail-closed default on a missing membership row. The 2-second audit SLA is enforced by the SQLite connection `timeout=1.8`: a contended `BEGIN IMMEDIATE … COMMIT` raises `OperationalError`, which is mapped to `503 service_unavailable` with no audit written (the only spec-permitted case of an access attempt without a corresponding audit entry, capped at ≤1% by SC-007). The byte-equivalent not-found helper (FR-007) pins `(status, content_type, content_length, body_bytes)` across every "you can't see this" code path: nonexistent patient, in-team-but-no-care-team-membership, non-IG caller of the IG endpoint, IG caller for a patient with no recorded accesses — all return identical bytes. The FR-014/FR-015 clinical-safety field ordering is enforced in one function (`clinical_safety.build_patient_summary`) and tested by walking `list(response.keys())` and asserting the prefix.

## Technical Context

**Language/Version**: Python 3.11+
**Primary Dependencies**: None at runtime (standard library only — `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `typing.Protocol`, `urllib.request` (tests only)). Dev-only: `pytest`, `ruff`.
**Storage**: SQLite via stdlib `sqlite3` in **WAL mode** with `synchronous=NORMAL`, `temp_store=MEMORY`, `mmap_size=128 MiB`, opened with `timeout=1.8` seconds for FR-013. Seven tables: `users`, `tokens`, `patients`, `patient_summaries`, `encounters`, `care_team_memberships`, `audit_entries`. The `care_team_memberships` table has the composite PK `(clinician_id, patient_id, episode_of_care_id)` and is indexed by `(clinician_id, patient_id, status)` to support the FR-006 lookup (the hottest query path). The `audit_entries` table is **append-only** at the code layer (no UPDATE/DELETE SQL targets it in `store.py`) and **not FK-constrained on `patient_id`** so audit entries can be written for nonexistent patient identifiers (FR-008's "audit even denied/not-found-or-denied attempts" rule).
**Testing**: pytest. End-to-end tests start a real `ThreadingHTTPServer` on an ephemeral port and hit it with `urllib.request`. Dedicated suites cover byte-equivalent isolation across every unauthorised-access code path (`test_byte_equivalence.py`), always-on audit semantics with snapshot fields (`test_audit.py`), the 2-second SLA contention path (`test_audit_sla.py`), the URL-path-PII static probe (`test_no_url_pii.py`), and the clinical-safety field-order constraint (`test_clinical_safety.py`).
**Target Platform**: Local developer machine (macOS / Linux), Python 3.11+. PoC, not a real clinical deployment.
**Project Type**: HTTP backend service (single project), parallel to the existing eight packages (002–008).
**Performance Goals**: No explicit performance SC like 008's 200 req/s. SC-009: ≥95% of correct-identifier lookups in <3 s. WAL-mode SQLite + indexed read paths trivially meet this on a developer machine.
**Constraints**: Standard library only (Constitution I). No web framework. Authentication is a bearer-token stub for v1; in a real NHS deployment it would be replaced by the host product's identity layer (NHS smartcard / OIDC). No tamper-detection / chained-hash audit log (out of scope for v1 — feature 005 has the pattern if needed later). No patient identifiers in URL paths (FR-004, SC-005). Audit log immutable at the code layer; out-of-band DB tampering is not defended against in v1. Care-team data is read from a table populated by an (out-of-scope) feed from the host product's care-team management system; if the table is empty, the system fails-closed (denies all clinical accesses) — the clinical-safety case must validate the operational fallback.
**Scale/Scope**: PoC. ≤5 seeded users (one per role + an outsider doctor), ≤2 seeded patients, ≤4 seeded care-team memberships. Approximately 900–1,200 LOC across `src/clinician_record_access/`. Mid-complexity by repo-LOC standards — simpler than 008 (no per-task sharing, no per-record permission predicates, no per-event audit decomposition); more complex than 006/007 (real cross-tenant byte-equivalence, real SLA on audit).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Initial check (pre-Phase 0)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | No runtime dependencies planned. |
| II. Test Every Module | PASS | Every module planned under `src/clinician_record_access/` has a corresponding `tests/clinician_record_access/test_*.py` (see Project Structure). Plus five invariant-focused suites: byte-equivalent isolation, always-on audit, 2-second SLA, URL-path-PII static probe, clinical-safety field-order. |
| III. PEP 8 and Type Hints | PASS | All public functions/methods will carry type hints with modern syntax. Linted with ruff. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | The deliverable is an HTTP service. The `python -m clinician_record_access.server` runner exposes `--help`, `--seed`, `--json`, `--port`, `--db-path` with errors on stderr. |
| V. Explicit Error Handling | PASS | Every failure mode in the spec maps to a typed exception in `errors.py` (`AuthError`, `ValidationError`, `NotFound`, `ServiceUnavailable`) and a documented HTTP status code. No bare `except`. SQLite `OperationalError` is the one stdlib exception we translate deliberately (FR-013 → `503 service_unavailable`). |
| VI. Clarity Over Cleverness | PASS | Module count is 12 — same as 008. Each module has a single responsibility. The care-team predicate lives in one function (`permissions.can_access`). The byte-equivalent helper lives in one function (`responses.not_found_response`). The clinical-safety field-order rule lives in one function (`clinical_safety.build_patient_summary`). The audit-row construction lives in one helper (`service.write_audit_entry`). |

No violations. Initial gate passed.

### Post-design re-check (after Phase 1)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | Phase 1 design did not introduce any non-stdlib dependency. |
| II. Test Every Module | PASS | Every module in the Project Structure below has a matching test file. The contract documents 10 numbered smoke-test steps in `quickstart.md`. |
| III. PEP 8 and Type Hints | PASS | Dataclasses and enums in `data-model.md` use `StrEnum`, modern type hints, and Protocol where appropriate (for the future identity-provider swap). |
| IV. Dual-Format CLI Output | PASS (scope-limited) | Documented in `quickstart.md`. |
| V. Explicit Error Handling | PASS | The HTTP API contract enumerates every error code and the precise condition that raises it; `errors.py` types map 1:1. The "503 with no audit entry under SLA breach" case is documented in the contract as the one spec-permitted exception to always-on audit. |
| VI. Clarity Over Cleverness | PASS | Phase 1 added no extra layers. The two endpoints in the contract map to two service-layer functions (`lookup_patient`, `list_audit_for_patient`); the per-request flow is linear: authenticate → resolve role → run predicate → build audit row → write audit entry → return content or not-found. |

No violations after design. Post-design gate passed.

## Project Structure

### Documentation (this feature)

```text
specs/009-clinician-record-access/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── http-api.md
├── checklists/
│   └── requirements.md
└── tasks.md            # Generated by /speckit-tasks (NOT this command)
```

### Source Code (repository root)

```text
src/
├── bank_transfer/                # Existing — 002 feature; unchanged.
├── loan_application/             # Existing — 003 feature; unchanged.
├── loan_workflow/                # Existing — 004 feature; unchanged.
├── fca_loans/                    # Existing — 005 feature; unchanged.
├── task_manager/                 # Existing — 006 feature; unchanged.
├── team_tasks/                   # Existing — 007 feature; unchanged.
├── task_sharing/                 # Existing — 008 feature; unchanged.
└── clinician_record_access/
    ├── __init__.py
    ├── __main__.py               # Entry point: python -m clinician_record_access
    ├── server.py                 # ThreadingHTTPServer wiring + request dispatch + auth boundary + CLI (argparse: --seed, --json, --port, --db-path). WAL PRAGMA setup. Routing table contains NO path with {patient_id} or {id} — FR-004 enforced here and tested by `test_no_url_pii.py`.
    ├── handlers.py               # Per-endpoint request handlers (parse, authenticate, authorise via permissions, call service, format response). Catches `ServiceUnavailable` and maps to 503.
    ├── responses.py              # Canonical response builders. `not_found_response()` returns the fixed byte-equivalent envelope (FR-007).
    ├── auth.py                   # Bearer-token resolution; `AuthenticatedCaller` dataclass `(clinician_id, clinician_display_name, clinician_role)`. Documented swap point for the host product's identity-provider integration.
    ├── permissions.py            # `can_access(clinician_id, patient_id) -> bool` (care-team predicate; FR-006) + `is_audit_officer(role) -> bool` (FR-011). Both predicates are pure functions over `(role, db)`.
    ├── service.py                # Business logic: `lookup_patient`, `list_audit_for_patient`. Always writes an audit entry on the clinical path (FR-008), regardless of outcome. Builds the patient summary by delegating to `clinical_safety.build_patient_summary` so field ordering lives in one place.
    ├── clinical_safety.py        # `build_patient_summary(patient, summary, encounters) -> dict` — the FR-014/FR-015 field-order enforcer. The only function in the codebase that constructs a successful-lookup response body.
    ├── validation.py             # Field-level validation; reports all errors at once; rejects request bodies missing `patient_id`.
    ├── store.py                  # SQLite schema (with WAL PRAGMAs) + connection (timeout=1.8 for FR-013) + all SQL. Every read query is parameterised. No UPDATE/DELETE SQL targets `audit_entries`. No FK from `audit_entries.patient_id` to `patients.id`.
    ├── models.py                 # Dataclasses: User, Token, Patient, PatientSummary, Encounter, CareTeamMembership, AuditEntry; ClinicianRole, AccessOutcome, AuthorisationBasis, MembershipStatus enums.
    └── errors.py                 # AuthError, ValidationError, NotFound, ServiceUnavailable.

tests/
└── clinician_record_access/
    ├── __init__.py
    ├── conftest.py               # Fixtures: in-memory DB (WAL), seeded users (one per role + an outsider doctor), seeded patients (with and without allergies/warnings), seeded care-team memberships, ephemeral-port server, write-lock contention helper for SLA tests.
    ├── test_auth.py              # Bearer-token resolution; 401 paths; assertion that no audit entry is written for a 401 (the authentication-boundary log lives elsewhere).
    ├── test_permissions.py       # Care-team-membership matrix: (clinical role × care-team relation × patient existence) — every cell. Includes the fail-closed-on-empty-table probe.
    ├── test_validation.py        # `400 validation_error` shape; per-field error reporting; absence of write-field validation paths (Q2 = A).
    ├── test_byte_equivalence.py  # Constructs (own-patient, other-care-team-patient, fabricated-id, IG-endpoint-as-clinician, IG-search-for-no-audits) tuples; asserts identical `(status, content_type, content_length, body_bytes)` across every cross-access-or-existence code path.
    ├── test_audit.py             # Always-on semantics: every clinical lookup produces one entry (`permitted` / `denied` / `not_found_or_denied`); snapshot semantics on display_name and role; immutability (static SQL probe + runtime snapshot-hash probe).
    ├── test_audit_sla.py         # Holds the SQLite write lock for 2.5 s in another thread; fires a lookup; asserts (a) `503 service_unavailable`, (b) zero audit entries written for that attempt, (c) no record content returned.
    ├── test_no_url_pii.py        # Static probe: greps `server.py`'s routing table for any path containing `{patient_id}` or `{id}`; fails if found. The probe also walks all generated test URLs and asserts none contain literal patient identifiers.
    ├── test_clinical_safety.py   # For every seeded patient (with and without allergies/warnings): performs a successful lookup, walks `list(response.keys())`, and asserts the first five keys are exactly `["patient_id", "date_of_birth", "name", "allergies", "key_warnings"]`. Also asserts that `allergies` and `key_warnings` arrays are *always present* (even if empty).
    ├── test_service.py           # Business logic against in-memory DB.
    ├── test_store.py             # Schema, CHECK constraints, FK behaviour (including the deliberate absence of an FK from `audit_entries.patient_id`), append-only SQL probe.
    ├── test_handlers.py          # HTTP-level: status codes, response shapes, error envelopes, `Content-Length` consistency.
    └── test_invariants.py        # SC-001…SC-011 catch-all probes including random-pair byte-equivalence sampling and runtime audit-immutability scan.
```

**Structure Decision**: A new top-level package `src/clinician_record_access/` parallel to the eight existing packages. The internal shape mirrors 008's with three substantive differences:

- **No per-task-style `permissions.py` relationship classifier** — the only authz decision is "is this clinician on this patient's care team?", which is one indexed SQL probe.
- **New `clinical_safety.py` module** — exists specifically to centralise the FR-014/FR-015 response-shape rule.
- **No sharing model** — there's no concept analogous to 008's `task_shares`. Care-team-membership is read-only from the host product's feed.

**This is the eighth near-identical-shape package in the repo.** The case for a `src/_common/` extraction (HTTP dispatch, bearer-token boundary, byte-equivalent not-found helper, validation primitives) is overwhelming, flagged in every plan from 005 onward, and unaddressed. Out of scope for *this* feature; should be the first thing done after 009 ships. The not-found helper specifically has now diverged across 005 / 007 / 008 / 009 with slightly different message strings (`"No such application."`, `"No such task."`, `"No such record."`) and slightly different `Content-Length` values — the extraction should preserve these as parameters rather than collapse them.

The separation between `service.py` (always writes an audit entry; returns `None` for any not-authorised-to-see case) and `handlers.py` (HTTP-aware, converts `None` → byte-equivalent not-found) is what lets unit tests exercise the always-on audit and byte-equivalent invariants without standing up a real server, while `test_byte_equivalence.py` and `test_audit.py` confirm the HTTP layer reproduces the same bytes and the same audit semantics.

## Complexity Tracking

No violations to justify.

009 sits at mid-complexity in the repo:

- **Simpler than 008** in several dimensions: only two endpoints (vs five); no per-task sharing; no per-event audit decomposition; no explicit performance target; only one authz predicate (care-team membership) vs 008's 5-class relationship matrix.
- **More complex than 006/007** in several dimensions: real byte-equivalent unauthorised-response invariant (vs 006's no isolation, vs 007's status+body only); real audit-write SLA with fail-fast 503 (vs 006/007's no SLA); response-shape constraints from FR-014/FR-015 that don't exist in any prior feature.
- **About on par with 005** structurally (audit + byte-equivalence + SLA + OAuth-like boundary), but **simpler in audit** (no chained-hash) and **stricter on URL hygiene** (009's FR-004 forbids patient_id in URL paths entirely).

# Implementation Plan: Hospital Clinical Record Access

**Branch**: `012-hospital-clinical-records` | **Date**: 2026-05-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/012-hospital-clinical-records/spec.md`

> ## 📋 Governance notice — documentation artefact
>
> `spec.md` carries a governance-review block listing the sign-offs that a real implementation would require before code is written (product owner, clinical-safety officer, legal/privacy/information-governance). This is a teaching trial of speckit and not a real clinical deployment; the governance block is retained as a documentation artefact and is not gating the plan.

## Summary

A small Python 3.11+ HTTP backend service exposing exactly three endpoints — `POST /records/lookup` (clinician reads a patient record), `POST /records/notes` (clinician adds a clinical note), `POST /audit/search` (hospital administrator views the access log for a patient) — implementing a clinical-record access feature with **care-team-membership-only authorisation for clinicians**, **append-only clinical notes** (no edit or delete endpoint exists in this feature's surface; the storage layer has no UPDATE/DELETE SQL targeting the notes table; the schema CHECK forbids administrator authorship), **administrator content-blindness** (the sole administrator response-builder module is structurally separated from any clinical-content code path; a static probe and a runtime probe verify the absence of every forbidden clinical-content key from administrator responses), **always-on immutable audit logging** with a 2-second write-budget that maps to fail-fast 503 on contention, **byte-equivalent unauthorised responses** (HTTP 404 with pinned status, body bytes, `Content-Type`, and `Content-Length` across every "you cannot see this" case to prevent existence-leakage of patient identifiers), and **no patient identifier in URL paths** (all three endpoints are POST with the identifier in the request body). Built on the Python standard library only (`http.server`, `sqlite3` in WAL mode with tuned PRAGMAs, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`). The SQLite connection is opened with `timeout=1.8` seconds, sized comfortably below the 2-second audit-write budget so a contended `BEGIN IMMEDIATE … COMMIT` raises `OperationalError` within the SLA window and maps to `503 service_unavailable` with the transaction rolled back. The 7-year audit retention floor (a conservative healthcare default; the host organisation's specific regulatory regime may impose longer requirements which this feature accommodates by setting its floor at 7 years and having no DELETE code path against audit entries) is enforced by code-path absence. The note INSERT and audit INSERT for the `add_note` path live in a single atomic transaction — they succeed or fail together — preserving the invariant that no observable state change exists without a matching audit entry.

## Technical Context

**Language/Version**: Python 3.11+
**Primary Dependencies**: None at runtime (standard library only — `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `urllib.request` for tests). Dev-only: `pytest`, `ruff`.
**Storage**: SQLite via stdlib `sqlite3` in WAL mode (`synchronous=NORMAL`, `temp_store=MEMORY`, `mmap_size=128 MiB`), with a single process-wide connection opened with `timeout=1.8` seconds and guarded by `threading.Lock`. Seven tables: `users`, `tokens`, `patients`, `patient_summaries`, `encounters`, `care_team_memberships`, `clinical_notes`, `audit_entries`. Two of these are append-only (`clinical_notes`, `audit_entries`) — no UPDATE/DELETE SQL targets them anywhere in `store.py`. The `clinical_notes.author_role` CHECK forbids `hospital_administrator` authorship structurally. The `audit_entries.note_id ↔ access_type/outcome` CHECK pairing prevents schema-corruption bugs where the audit-row claims a note was added but the note INSERT failed.
**Testing**: pytest. End-to-end tests start a real `ThreadingHTTPServer` on an ephemeral port and hit it with `urllib.request`; service-layer tests bypass HTTP and call the service directly with an in-memory DB. Dedicated suites cover the byte-equivalent isolation matrix (`test_byte_equivalence.py`), the always-on audit semantics including snapshot fields (`test_audit.py`), the 2-second SLA contention path (`test_audit_sla.py`), the URL-path-PII static probe (`test_no_url_pii.py`), the clinical-safety field-order constraint (`test_clinical_safety.py`), the note append-only behaviour (`test_notes.py`), and **`test_admin_content_blindness.py`** — the runtime probe that walks every administrator response across seeded scenarios and asserts no forbidden clinical-content key appears at any depth.
**Target Platform**: Local developer machine (macOS / Linux), Python 3.11+. PoC, not a real clinical deployment.
**Project Type**: HTTP backend service (single project).
**Performance Goals**: No explicit performance SLA in the spec beyond `SC-009` (≥99% of audit entries persisted within 2 seconds; ≤1% return `503`) and `SC-010` (≥95% of correct-care-team reads in <3 seconds on a representative workload). WAL-mode SQLite + indexed read paths trivially meet these on a developer machine.
**Constraints**: Standard library only. Authentication is a bearer-token stub for v1 (the host product's identity layer in real deployment). No tamper detection on notes or audit beyond append-only by code-path absence; out-of-band DB tampering is not defended against. No patient identifier appears in URL paths (FR-003, SC-005). Care-team data is read from a `care_team_memberships` table populated by an out-of-scope feed from the host product's care-team-management system; on missing/stale rows, the system fails closed (denies access). **Administrator content-blindness is enforced at the module boundary** — the administrator response-builder lives in a dedicated file that structurally does not reach any clinical-content table.
**Scale/Scope**: PoC. ≤6 seeded users (one per clinical role + one administrator + an outsider doctor), ≤2 seeded patients, ≤5 seeded care-team memberships, ≤1 seeded clinical note. Approximately 1,100–1,400 LOC across `src/hospital_clinical_records/`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The repository constitution requires: standard-library-first; tests for every module; PEP 8 + type hints with modern syntax; dual-format CLI output where applicable; explicit error handling; clarity over cleverness.

### Initial check (pre-Phase 0)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | No runtime dependencies planned. All modules in the design are stdlib. |
| II. Test Every Module | PASS | Every module planned under `src/hospital_clinical_records/` has a corresponding `tests/hospital_clinical_records/test_*.py`. Plus seven invariant-focused suites: byte-equivalent isolation, always-on audit, 2-second SLA, URL-path-PII, clinical-safety field-order, notes append-only, **admin content-blindness**. |
| III. PEP 8 and Type Hints | PASS | All public functions/methods will carry type hints with modern syntax (`str | None`, etc.). Linted with ruff. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | The deliverable is an HTTP service. The `python -m hospital_clinical_records.server` runner is a thin CLI wrapper exposing `--help`, `--seed`, `--json`, `--port`, `--db-path` with errors on stderr. With `--seed --json` the seeded fixture is emitted as JSON; without `--json` it is printed as a human-readable table. Endpoints are JSON-only by design. |
| V. Explicit Error Handling | PASS | Every failure mode in the spec maps to a typed exception in `errors.py` (`AuthError`, `ValidationError`, `NotFound`, `MethodNotAllowed`, `ServiceUnavailable`) and a documented HTTP status code. No bare `except`. SQLite `OperationalError` is the one stdlib exception we translate deliberately (FR-015 → `503 service_unavailable`). |
| VI. Clarity Over Cleverness | PASS | Module count is 13. Each module has a single responsibility. The administrator content-blindness invariant lives in one dedicated module (`admin_response.py`). The clinical-safety field-order rule lives in one dedicated module (`clinical_safety.py`). The byte-equivalent unauthorised envelope is one function (`responses.not_found_response`). The care-team-membership predicate is one indexed SQL query in `permissions.py`. No metaclasses, decorators-as-DSL, or hand-rolled framework. |

No violations. Initial gate passed.

### Post-design re-check (after Phase 1)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | Phase 1 design did not introduce any non-stdlib dependency. |
| II. Test Every Module | PASS | Every module in the Project Structure below has a matching test file. The contract documents 17 numbered smoke-test steps in `quickstart.md` covering happy paths, refused paths (byte-equivalent 404), and invariant probes. |
| III. PEP 8 and Type Hints | PASS | Dataclasses and enums in `data-model.md` use `StrEnum` and modern type-hint syntax. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | Documented in `quickstart.md`. |
| V. Explicit Error Handling | PASS | The HTTP API contract (`contracts/http-api.md`) enumerates every error code and the precise condition that raises it; the `errors.py` types map 1:1 to those codes. The `405 method_not_allowed` response for PATCH/DELETE attempts against the notes resource is documented as either-that-or-the-byte-equivalent-404 (both are acceptable; the routes do not exist). |
| VI. Clarity Over Cleverness | PASS | Phase 1 added no extra layers. The three endpoints map to three service-layer functions (`lookup_patient`, `add_note`, `list_audit_for_patient`); the two content-rendering modules (`clinical_safety.py`, `admin_response.py`) split the rendering rules so the FR-018 invariant is structurally provable in one place. |

No violations after design. Post-design gate passed.

## Project Structure

### Documentation (this feature)

```text
specs/012-hospital-clinical-records/
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
└── hospital_clinical_records/
    ├── __init__.py
    ├── __main__.py               # Entry point: python -m hospital_clinical_records
    ├── server.py                 # ThreadingHTTPServer wiring + request dispatch + auth boundary + CLI (argparse: --seed, --json, --port, --db-path). WAL PRAGMA setup. Routing has NO path with {patient_id}/{id}/{note_id} (FR-003, enforced by test_no_url_pii.py). PATCH/DELETE against /records/notes/* are not registered — they implicitly return 405 (or the byte-equivalent 404 depending on server config; both are spec-acceptable per FR-011).
    ├── handlers.py               # Per-endpoint request handlers (parse, authenticate, authorise via permissions, call service, format response). Catches ServiceUnavailable and maps to 503.
    ├── responses.py              # Canonical response builders. not_found_response() returns the fixed byte-equivalent envelope (FR-006). Pinned (status=404, content_type, content_length=48, body).
    ├── auth.py                   # Bearer-token resolution; AuthenticatedCaller dataclass (user_id, user_display_name, user_role). Documented swap point for the host product's identity-provider integration.
    ├── permissions.py            # can_access(user, patient_id, db) -> bool (care-team predicate; FR-004) + is_administrator(role) -> bool (FR-005, FR-017). Both predicates are pure functions over (user, db) — no caching, evaluated on every request.
    ├── service.py                # Business logic: lookup_patient, add_note, list_audit_for_patient. Always writes an audit entry on clinical-endpoint paths (FR-012). add_note runs note INSERT + audit INSERT in one transaction. Returns None for not-authorised-to-see cases; the handler converts None to the byte-equivalent 404.
    ├── clinical_safety.py        # build_patient_record(patient, summary, encounters, notes) -> dict — the FR-007/FR-019/FR-020 field-order enforcer for the clinician-facing endpoint. The only function in the codebase that constructs a successful-lookup clinician response.
    ├── admin_response.py         # build_admin_audit_response(patient_id, entries) -> dict — the FR-018 content-blind admin response builder. Statically does NOT import models or columns for patient_summaries, encounters, clinical_notes content fields, or patients.name/date_of_birth. The sole code path for /audit/search 200 OK responses.
    ├── validation.py             # Field-level validation; reports all errors at once (FR-009). Note-body trim + 1–8000 char check. Future-date rejection on encounter_date. note_type enum validation.
    ├── store.py                  # SQLite schema (WAL PRAGMAs) + connection (timeout=1.8 for FR-015) + all SQL. Every read query parameterised. No UPDATE/DELETE SQL targets clinical_notes or audit_entries. No FK from audit_entries.patient_id to patients.id (audit outlives any hypothetical patient deletion, which is out of scope anyway).
    ├── models.py                 # Dataclasses: User, Token, Patient, PatientSummary, Encounter, CareTeamMembership, ClinicalNote, AuditEntry; UserRole, NoteType, AccessType, AccessOutcome, AuthorisationBasis, MembershipStatus enums.
    └── errors.py                 # AuthError, ValidationError, NotFound, MethodNotAllowed, ServiceUnavailable.

tests/
└── hospital_clinical_records/
    ├── __init__.py
    ├── conftest.py               # Fixtures: in-memory DB (with WAL mode), seeded users covering every clinical role + an administrator + an outsider doctor, seeded patients with various data, seeded care-team memberships, seeded notes, ephemeral-port server, write-lock contention helper for SLA tests.
    ├── test_auth.py              # Bearer-token resolution; 401 paths; ensures no business logic runs on a 401 and no audit entry is written for the 401 path.
    ├── test_permissions.py       # Exhaustive (role × care-team relationship × patient existence) matrix for the record-read and add_note endpoints. Administrator-only check for the /audit/search endpoint.
    ├── test_validation.py        # Per-field validation; per-field error reporting; whitespace-trim on body; future-date rejection on encounter_date; note_type enum validation; body length boundaries (0, 1, 8000, 8001).
    ├── test_byte_equivalence.py  # Constructs (own-care-team, other-care-team, fabricated-id, admin-clinical-endpoint, clinician-admin-endpoint, missing-audit) tuples; asserts identical (status, content_type, content_length, body) across every cross-access code path.
    ├── test_audit.py             # Always-on audit for read AND add_note AND list_audit; snapshot semantics on user_display_name and user_role; immutability (static SQL probe + runtime snapshot-hash probe); the note_id ↔ access_type CHECK pairing under coverage.
    ├── test_audit_sla.py         # Holds the SQLite write lock for 2.5 s in another thread; fires both a lookup and an add_note; asserts (a) 503 service_unavailable, (b) zero audit entries written for the failed attempts, (c) no record content returned, (d) no note persisted.
    ├── test_no_url_pii.py        # Static probe: greps server.py routing for any path containing {patient_id}, {id}, {patient}, {note_id}, etc.; fails if found. Asserts the routing table contains exactly the three POST endpoints.
    ├── test_clinical_safety.py   # For every seeded patient: walks list(response.keys()) and asserts the first five keys are ['patient_id','date_of_birth','name','allergies','key_warnings']; asserts notes_count precedes notes; asserts allergies and key_warnings arrays are always present (even when empty).
    ├── test_admin_content_blindness.py  # The headline structural-absence test. Walks every administrator response across seeded scenarios (including patients with long note bodies, allergies, warnings, encounters); recursively asserts none of {body, note_body, content, note_content, allergies, key_warnings, current_medications, recent_encounters, encounters, summary, name, patient_name, date_of_birth, dob} appear at any depth.
    ├── test_notes.py             # Note creation; admin-cannot-author (schema CHECK on author_role); append-only enforcement (PATCH/DELETE return 405 or byte-equivalent 404); concurrent additions both succeed and produce two audit entries; encounter_date defaults to today; future-date rejection.
    ├── test_service.py           # Business logic — lookup_patient, add_note, list_audit_for_patient — against in-memory DB.
    ├── test_store.py             # Schema, CHECK constraints (incl. clinical_notes.author_role excluding administrator and the audit (access_type, note_id, outcome) pairing), append-only on clinical_notes and audit_entries (static SQL probe).
    ├── test_handlers.py          # HTTP-level: status codes, response shapes, error envelopes; Content-Length=48 consistency on the unauthorised envelope; 405 on PATCH/DELETE against notes.
    └── test_invariants.py        # SC-001…SC-009 catch-all probes including: a runtime audit-immutability scan; a static grep of admin_response.py for forbidden clinical-table accesses; a recursive walk of every administrator response across seeded scenarios.
```

**Structure Decision**: A single top-level package `src/hospital_clinical_records/` with 13 modules. Each invariant or invariant-pair gets its own module so the structural guarantee is auditable in one place:

- `responses.py` — the byte-equivalent unauthorised envelope (FR-006).
- `clinical_safety.py` — the patient-record field-order rule (FR-007, FR-019, FR-020).
- `admin_response.py` — the administrator content-blindness rule (FR-005, FR-018).
- `permissions.py` — the authorisation rule (FR-004, FR-005, FR-017).
- `store.py` — the append-only invariant for `clinical_notes` and `audit_entries` (FR-011, FR-014); the audit-SLA timeout (FR-015); the schema CHECK constraints that enforce structural invariants (administrator cannot author notes; `note_id ↔ access_type/outcome` pairing).

The separation between `service.py` (business logic, returns `None` for not-authorised-to-see cases) and `handlers.py` (HTTP-aware, converts `None` → byte-equivalent 404, dispatches per role) is what lets unit tests exercise the always-on audit, the byte-equivalent invariant, the administrator content-blindness invariant, and the patient-record field-order invariant without standing up a real server, while the byte-equivalence and SLA tests confirm the HTTP layer reproduces the same bytes / semantics through the wire.

## Complexity Tracking

No violations to justify.

The design's complexity sits at "mid-high" by general standards: 13 source modules, 8 SQL tables, three endpoints, two content-rendering invariants (clinical-safety field order and administrator content-blindness) that warrant dedicated modules, and a 2-second audit-write SLA on the synchronous-write path. Each piece of complexity corresponds to a specific functional requirement and is contained in a single auditable module. No piece of complexity is speculative — each is traceable to a numbered FR or SC.

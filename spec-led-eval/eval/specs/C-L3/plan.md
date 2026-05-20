# Implementation Plan: HIPAA Hospital Clinical Record Access

**Branch**: `013-hipaa-clinical-records` | **Date**: 2026-05-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/013-hipaa-clinical-records/spec.md`

> ## 📋 Governance notice — documentation artefact
>
> `spec.md` carries a governance-review block listing the sign-offs that a real HIPAA-regulated implementation would require before code is written (product owner, HIPAA Privacy Officer + HIPAA Security Officer, clinical-safety officer, performance engineer). This is a teaching trial and not a real clinical deployment; the governance block is retained as a documentation artefact and is not gating the plan.

## Summary

A small Python 3.11+ HTTP backend service exposing exactly four endpoints — `GET /records/{id}` (read a record, gated by care-team membership for clinicians or self-ownership for patients), `POST /records/{id}/notes` (append a clinical note, gated by care-team membership for clinicians only), `GET /records/{id}/audit` (read per-record audit log, accessible to care-team clinicians, patients on their own record, and compliance officers), and `GET /access-log` (system-wide audit log, compliance-officer only) — implementing a HIPAA-aligned record-access feature with three roles (`clinician`, `patient`, `compliance_officer`), care-team-membership-only authorisation for clinicians, append-only clinical notes, always-on immutable audit logging with originating-IP capture and a 1-second write SLA, a byte-equivalent HTTP 403 unauthorised envelope across every "you cannot see / do this" code path on the `{id}`-scoped endpoints, a 200ms p99 latency target on the non-care-team-clinician rejection path, and a 7-year audit retention floor satisfying HIPAA §164.530(j). Built on the Python standard library only (`http.server`, `sqlite3` in WAL mode with tuned PRAGMAs, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`). The SQLite connection is opened with `timeout=0.15` seconds (150 milliseconds) — sized to satisfy **both** the 200ms p99 latency SLA on the 403 path **and** the 1-second audit-write SLA from a single connection-level setting; a contended `BEGIN IMMEDIATE … COMMIT` raises `OperationalError` within the timeout and maps to `503 service_unavailable` with the transaction rolled back. The compliance-officer content-blindness invariant (FR-019) is enforced structurally by placing the compliance response-builder in its own module (`compliance_response.py`) that statically does not import or query any clinical-content table or column; a static probe greps the module for forbidden accesses, and a runtime probe walks every compliance response across seeded scenarios and asserts the absence of every forbidden clinical-content key. The note INSERT and audit INSERT for the `append_note` path are atomic — they succeed or fail together — preserving the invariant that no observable state change exists without a matching audit entry. The `record_id` in URL paths is acceptable (it is an opaque internal system handle, not a patient demographic); patient identifiers (name, date of birth, social security number) never appear in URL paths, verified by a static probe.

## Technical Context

**Language/Version**: Python 3.11+
**Primary Dependencies**: None at runtime (standard library only — `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `urllib.request` for tests). Dev-only: `pytest`, `ruff`.
**Storage**: SQLite via stdlib `sqlite3` in WAL mode (`journal_mode = WAL`, `synchronous = NORMAL`, `temp_store = MEMORY`, `mmap_size = 128 MiB`), with a single process-wide connection opened with `timeout=0.15` seconds (chosen to satisfy both SLAs from one setting; see `research.md` for the analysis). Eight tables: `users`, `tokens`, `records`, `patient_summaries`, `encounters`, `care_team_memberships`, `clinical_notes`, `audit_entries`. Two append-only tables (`clinical_notes`, `audit_entries`) — no UPDATE/DELETE SQL targets them anywhere in `store.py`. Schema CHECK constraints enforce: `users.role` paired with `assigned_record_id` (paired iff role is `patient`); `clinical_notes.author_role = 'clinician'` (excluding patient and compliance authors at the schema layer); the audit-entry `(operation, outcome, note_id)` and `(operation, record_id)` pairings (preventing schema-corruption bugs where the audit row's shape doesn't match reality).
**Testing**: pytest. End-to-end tests start a real `ThreadingHTTPServer` on an ephemeral port and hit it with `urllib.request`. Dedicated suites cover the full caller-archetype × endpoint × record-existence permission matrix (`test_permissions.py`), byte-equivalent 403 isolation (`test_byte_equivalence.py`), always-on audit semantics with IP capture (`test_audit.py`), the dual SLA — 200ms 403 latency (`test_perf_403_latency.py`) and 1-second audit-write fail-fast (`test_audit_sla.py`), patient self-access (`test_patient_self_access.py`), system-wide compliance access log (`test_access_log_endpoint.py`), and `test_compliance_content_blindness.py` — the structural-absence probe for FR-019.
**Target Platform**: Local developer machine (macOS / Linux), Python 3.11+. PoC, not a real clinical deployment.
**Project Type**: HTTP backend service (single project).
**Performance Goals**: Two explicit SLAs in the spec:
  - **FR-009 / SC-004**: p99 ≤ 200ms on the non-care-team-clinician 403 path under representative load. Met by tight `timeout=0.15` on the SQLite connection + indexed care-team-membership predicate + in-transaction audit write.
  - **FR-016 / SC-005**: 99% of audit entries durably persisted within 1 second. Trivially met because the 150ms timeout is well within 1 second; the ≤1% that exceed it return `503 service_unavailable`.
**Constraints**: Standard library only. Authentication is a bearer-token stub for v1 (the host product's HIPAA-compliant identity layer in real deployment). No tamper-detection / chained-hash audit log (append-only by code-path absence only; out-of-band DB tampering not defended against in v1). No patient demographic in URL paths (FR-020, SC-005); `record_id` is acceptable because it is an opaque internal handle. Care-team data read from a `care_team_memberships` table populated by an out-of-scope feed from the host product's care-team-management system; fail-closed on missing/stale rows. **Compliance content-blindness** enforced at the module boundary — the compliance response-builder lives in a dedicated file that structurally does not reach any clinical-content table.
**Scale/Scope**: PoC. ≤5 seeded users covering every caller archetype (clinician-in-CT, clinician-outside-CT, patient-on-own-record, patient-on-other-record, compliance officer), ≤2 seeded records, ≤1 seeded care-team membership, ≤1 seeded clinical note. Approximately 1,200–1,500 LOC across `src/hipaa_clinical_records/`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The repository constitution requires: standard-library-first; tests for every module; PEP 8 + type hints with modern syntax; dual-format CLI output where applicable; explicit error handling; clarity over cleverness.

### Initial check (pre-Phase 0)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | No runtime dependencies planned. The 200ms 403 latency SLA is met by stdlib SQLite + indexed predicate + tight write timeout, confirmed by the analysis in `research.md`. |
| II. Test Every Module | PASS | Every module planned under `src/hipaa_clinical_records/` has a corresponding `tests/hipaa_clinical_records/test_*.py`. Plus seven invariant-focused suites: full permission matrix, byte-equivalent 403, always-on audit + IP capture, **200ms 403 latency probe**, 1-second audit-SLA fail-fast, patient self-access matrix, **compliance content-blindness**. |
| III. PEP 8 and Type Hints | PASS | All public functions/methods will carry type hints with modern syntax. Linted with ruff. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | The deliverable is an HTTP service. The `python -m hipaa_clinical_records.server` runner is a thin CLI wrapper exposing `--help`, `--seed`, `--json`, `--port`, `--db-path` with errors on stderr. With `--seed --json` the seeded fixture is emitted as JSON; without `--json` it is printed as a human-readable table. |
| V. Explicit Error Handling | PASS | Every failure mode in the spec maps to a typed exception in `errors.py` (`AuthError`, `ValidationError`, `Forbidden`, `MethodNotAllowed`, `ServiceUnavailable`) and a documented HTTP status code. No bare `except`. SQLite `OperationalError` is the one stdlib exception we translate deliberately (FR-016 → `503 service_unavailable`). |
| VI. Clarity Over Cleverness | PASS | Module count is 13. Each module has a single responsibility. The relationship classifier in `permissions.py` returns one of five values (`OUTSIDER`, `CARE_TEAM_CLINICIAN`, `PATIENT_OWN_RECORD`, `PATIENT_OTHER_RECORD`, `COMPLIANCE_OFFICER`) that feeds into a small action-allow table. The byte-equivalent helper is one function; the compliance content-blindness builder is one module; the 200ms latency budget is one configuration value (`timeout=0.15`). No metaclasses, decorators-as-DSL, or hand-rolled framework. |

No violations. Initial gate passed.

### Post-design re-check (after Phase 1)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | Phase 1 design did not introduce any non-stdlib dependency. |
| II. Test Every Module | PASS | Every module in the Project Structure below has a matching test file. The contract documents 18 numbered smoke-test steps in `quickstart.md` covering happy paths, refused paths (byte-equivalent 403), and invariant probes. |
| III. PEP 8 and Type Hints | PASS | Dataclasses and enums in `data-model.md` use `StrEnum` and modern type-hint syntax. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | Documented in `quickstart.md`. |
| V. Explicit Error Handling | PASS | The HTTP API contract enumerates every error code and the precise condition that raises it; `errors.py` types map 1:1 to those codes. The 403-instead-of-404 envelope choice is documented prominently in `contracts/http-api.md` and `research.md`. |
| VI. Clarity Over Cleverness | PASS | Phase 1 added no extra layers. The four endpoints map to four service-layer functions (`get_record`, `append_note`, `get_record_audit`, `get_system_audit_log`); the two content-rendering modules (`clinical_record_response.py`, `compliance_response.py`) split the rendering rules so the FR-019 invariant is structurally provable in one place. |

No violations after design. Post-design gate passed.

## Project Structure

### Documentation (this feature)

```text
specs/013-hipaa-clinical-records/
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
└── hipaa_clinical_records/
    ├── __init__.py
    ├── __main__.py
    ├── server.py                       # ThreadingHTTPServer wiring + request dispatch + auth boundary + CLI (argparse: --seed, --json, --port, --db-path). WAL PRAGMA setup. Routing uses `{id}` (= record_id); FR-020 enforced — no `{patient_id}`/`{name}`/`{nhs_number}`/etc. PATCH/DELETE not registered for `/records/{id}/notes/{note_id}` — implicit 405 or byte-equivalent 403.
    ├── handlers.py                     # Per-endpoint request handlers (parse, authenticate, authorise via permissions, call service, format response). Captures originating IP from `client_address` plus optional `X-Forwarded-For` for configured trusted proxies. Catches `ServiceUnavailable` and maps to 503.
    ├── responses.py                    # Canonical `forbidden_response()` returns the **HTTP 403** byte-equivalent envelope (FR-008). Pinned `(status=403, content_type, content_length=47, body=b'{"error":"forbidden","message":"Access denied."}')`.
    ├── auth.py                         # Bearer-token resolution; `AuthenticatedCaller` dataclass `(user_id, user_display_name, role, assigned_record_id, originating_ip)`. Documented swap point for the host product's HIPAA-compliant identity-provider integration.
    ├── permissions.py                  # `relationship(user, record_id, db) -> Relationship` classifier; per-action allow table. `is_compliance_officer(role)` + `is_clinician(role)` + `is_patient(role)` role checks.
    ├── service.py                      # Business logic: `get_record`, `append_note`, `get_record_audit`, `get_system_audit_log`. Always writes one audit entry per record-access path (FR-013). `append_note` runs note INSERT + audit INSERT in one transaction.
    ├── clinical_record_response.py     # `build_record(record, summary, encounters, notes) -> dict` — FR-010-related fixed-shape record response. Also `build_per_record_audit_for_clinical(record_id, entries) -> dict` (used by clinician + patient callers on `/records/{id}/audit`). NOT used by compliance callers — they go through `compliance_response.py`.
    ├── compliance_response.py          # FR-019 content-blind response builders for compliance officers: `build_access_log_response(entries) -> dict` and `build_per_record_audit_for_compliance(record_id, entries) -> dict`. Statically does NOT import or query any clinical-content table or column.
    ├── validation.py                   # Field-level validation; reports all errors at once (FR-010). Note-body trim + 1–8000 char check. Future-date rejection on `encounter_date`. `note_type` enum. `limit`/`from`/`to` validation for `GET /access-log`.
    ├── store.py                        # SQLite schema (WAL PRAGMAs) + connection (timeout=0.15s for FR-009 + FR-016) + all SQL. Every read query parameterised. No UPDATE/DELETE SQL targets `clinical_notes` or `audit_entries`. Schema CHECKs enumerated in data-model.md.
    ├── models.py                       # Dataclasses: User, Token, Record, PatientSummary, Encounter, CareTeamMembership, ClinicalNote, AuditEntry, AuthenticatedCaller; Role, NoteType, Operation, Outcome, AuthorisationBasis, MembershipStatus, Relationship enums.
    └── errors.py                       # AuthError, ValidationError, Forbidden, MethodNotAllowed, ServiceUnavailable.

tests/
└── hipaa_clinical_records/
    ├── __init__.py
    ├── conftest.py                     # Fixtures: in-memory DB (WAL), seeded users covering every caller archetype, seeded records, care-team memberships, notes, ephemeral-port server, write-lock contention helper, latency-measurement helper.
    ├── test_auth.py                    # Bearer-token resolution; 401 paths; no audit on 401.
    ├── test_permissions.py             # Full (caller archetype × action × record-existence) matrix.
    ├── test_validation.py              # Per-field validation; per-field error envelope; future-date rejection; `limit`/`from`/`to` bounds.
    ├── test_byte_equivalence.py        # (real-unauthorised, fabricated-id) pairs for every caller archetype; asserts identical `(status, content_type, content_length, body)` across every refused code path.
    ├── test_audit.py                   # Always-on audit (read, append, list); snapshot semantics; `originating_ip_address` captured; immutability; CHECK pairings under coverage.
    ├── test_audit_sla.py               # Held-lock probe for 300ms; asserts `503` within budget; no state change, no audit entry persisted.
    ├── test_perf_403_latency.py        # The 200ms p99 probe (FR-009, SC-004). Fires 1000 non-care-team-clinician GETs; asserts p99 latency ≤ 200ms. Skipped on CI where wall-clock measurement is unreliable; re-enable with `--run-perf`.
    ├── test_no_url_pii.py              # Static probe: greps `server.py` routing for any path placeholder matching a patient demographic; asserts the only allowed placeholder is `{id}` (= record_id).
    ├── test_clinical_safety.py         # Walks `GET /records/{id}` response keys; asserts the first five are `["record_id","date_of_birth","patient_name","allergies","key_warnings"]`.
    ├── test_compliance_content_blindness.py  # Walks every compliance response (`/access-log` and per-record audit for compliance caller); recursively asserts no forbidden clinical-content key appears at any depth.
    ├── test_notes.py                   # Append-only enforcement (PATCH/DELETE return 405 or byte-equivalent 403); non-clinician authorship rejected.
    ├── test_patient_self_access.py     # Patient reads own record + own audit; refused on others; refused on writes; refused on `/access-log`.
    ├── test_access_log_endpoint.py     # System-wide audit retrieval; all four filters; content-blindness; non-compliance callers refused.
    ├── test_service.py                 # Business logic against in-memory DB.
    ├── test_store.py                   # Schema; all CHECK constraints; append-only static SQL probe.
    ├── test_handlers.py                # HTTP-level: status codes, response shapes, error envelopes, `Content-Length=47` consistency on the 403 envelope, IP captured correctly under various proxy configurations.
    └── test_invariants.py              # SC-001…SC-011 catch-all probes; static grep of `compliance_response.py` for forbidden clinical-table accesses; audit-immutability runtime scan.
```

**Structure Decision**: A single top-level package `src/hipaa_clinical_records/` with 13 modules. Each invariant or invariant-pair is contained in one auditable place:

- `responses.py` — the byte-equivalent 403 envelope (FR-008, SC-003).
- `permissions.py` — the relationship classifier + per-action allow table (FR-004 through FR-007, SC-009, SC-010).
- `clinical_record_response.py` — the record-content response shape with fixed field ordering for safety-relevant fields.
- `compliance_response.py` — the FR-019 content-blindness invariant (the FR-019 absence guarantee is verifiable by static inspection of this short module).
- `store.py` — the append-only invariants for `clinical_notes` and `audit_entries` (FR-012, FR-015), the 150ms write-timeout that satisfies both SLAs (FR-009, FR-016), and the schema CHECK constraints that encode structural invariants (single-role-per-user paired with `assigned_record_id`; clinician-only note authorship; audit `(operation, outcome, note_id)` and `(operation, record_id)` pairings).

The separation between `service.py` (business logic, returns `None` for not-authorised-to-see cases) and `handlers.py` (HTTP-aware, converts `None` → byte-equivalent 403, dispatches per relationship, captures IP) is what lets unit tests exercise the always-on audit, the byte-equivalent invariant, the compliance content-blindness invariant, and the dual-SLA latency guarantees without standing up a real server, while the byte-equivalence and SLA tests confirm the HTTP layer reproduces the same bytes / semantics through the wire.

## Complexity Tracking

No violations to justify.

The design's complexity sits at "mid-high" by general standards: 13 source modules, 8 SQL tables, four endpoints, two content-rendering invariants (clinical-record field order and compliance-officer content-blindness) that warrant dedicated modules, and a dual SLA on the synchronous-write path (200ms 403 latency + 1-second audit-write). Each piece of complexity corresponds to a specific functional requirement and is contained in a single auditable module. No piece of complexity is speculative — each is traceable to a numbered FR or SC.

The dual SLA being satisfied by a single connection-level timeout setting (`timeout=0.15s`) is the only design decision that requires careful reasoning, and that reasoning is documented in `research.md` with a throughput analysis.

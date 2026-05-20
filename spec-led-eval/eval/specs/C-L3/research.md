# Research: HIPAA Hospital Clinical Record Access

**Branch**: `013-hipaa-clinical-records` | **Date**: 2026-05-17

> **Governance / trial-context note**: this document treats `spec.md` as the source of truth. The Phase 0 decisions below justify the technical choices independently from any other work in the repository. The governance review described in `spec.md` is a prerequisite for real-world implementation; the plan here is produced taking the spec's documented defaults as given.

The spec is fully resolved (no `[NEEDS CLARIFICATION]` markers). This document records the technical design decisions that turn the spec's functional requirements into a concrete plan.

## HTTP server: stdlib `http.server` (`ThreadingHTTPServer`)

**Decision**: Build the service on `http.server.ThreadingHTTPServer` with a small dispatch in `server.py` that routes `(method, path)` to handler functions. No framework.

**Rationale**: The repository's constitution requires standard-library-first. Four JSON endpoints with simple request/response shapes do not justify a framework dependency. The threading variant gives concurrent request handling; the 200ms HTTP 403 latency target (FR-009 / SC-004) is achievable through tight storage timeouts and indexed-lookup predicates rather than through framework choice.

**Alternatives considered**:
- **A web framework** (e.g., a popular Python web framework). Would add ergonomic routing and validation but pull in transitive dependencies. Rejected.
- **Async I/O** (e.g., asyncio + an async HTTP server). Overkill for a correctness-focused service; the 200ms target is met with threading + tight SQLite timeouts.

## Storage: stdlib `sqlite3` in WAL mode with tight write timeout

**Decision**: SQLite via stdlib `sqlite3` in WAL (Write-Ahead Logging) mode. File-backed in normal runs; `:memory:` in tests. PRAGMAs applied at connection setup:

```text
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 134217728;   -- 128 MiB
```

A single process-wide connection is opened with `timeout=0.15` seconds (150 milliseconds) and guarded by a `threading.Lock`. This timeout is sized to satisfy **both** the spec's SLAs in a single setting:

- **FR-009 / SC-004 (200ms p99 on the 403 path)**: the 403 path performs authentication, role resolution, the care-team-membership predicate (one indexed SQL probe, ~1ms typical), the audit-entry INSERT, and the COMMIT. With a 150ms COMMIT timeout, the worst-case wait for the write lock leaves ~50ms of headroom for the other steps within the 200ms budget.
- **FR-016 / SC-005 (1-second audit SLA)**: 150ms is well within 1 second, so this SLA is satisfied trivially by the same timeout. The 1% of requests permitted to exceed the SLA per SC-005 are exactly those that hit the 150ms timeout and fail-fast with `503 service_unavailable`.

A contended `BEGIN IMMEDIATE` or `COMMIT` raises `sqlite3.OperationalError` after the timeout; the handler catches that and returns `503 service_unavailable` with the transaction rolled back automatically.

**Why a single connection-level timeout for both SLAs**: SQLite's `timeout` is connection-scoped, not per-statement. Splitting timeouts per code path would require multiple connections, which fights WAL semantics. The single tight timeout serves both SLAs and is the simplest mechanism.

**Throughput analysis at developer-machine scale**:

- 403 path under no contention: ~10–50ms total (auth + predicate + audit INSERT + COMMIT + serialisation), comfortably under 200ms.
- 200 OK read path: similar, plus a SELECT of the record + summary + encounters + notes. Indexed; <100ms typical.
- 201 Created append path: similar, with the note INSERT in the same transaction.
- 200 OK system-wide access-log read for compliance: SELECT against the indexed audit table.

Under contention (concurrent writers), the write-lock queue length determines additional latency; 150ms accommodates a small queue depth before fail-fast kicks in.

**Alternatives considered**:
- **Default rollback journal mode**: blocks readers behind writers; bad for the read-heavy workload.
- **Looser timeout** (e.g., 1.8s for the 1-second audit SLA only): would blow the 200ms 403 budget on the same code path. Rejected.
- **One connection per request**: per-connection setup overhead (open, PRAGMAs, close) dominates the 150ms budget; rejected.
- **PostgreSQL**: a real RDBMS would trivialise the SLA story but adds a non-stdlib runtime dependency. Rejected on constitution grounds; the perf analysis shows stdlib SQLite meets the targets at the PoC scale.

## Authentication: bearer-token stub for v1, host-product identity in production

**Decision**: Every request authenticates via the HTTP header `Authorization: Bearer <token>`. Tokens are resolved against a seeded `tokens` table to a `User` row. The result is bound to the request as `(user_id, user_display_name, role)`, plus `assigned_record_id` for users with role `patient`. Missing or invalid tokens are rejected with `401 unauthenticated` before any handler logic runs and **before any audit entry is written**. In production, the bearer-token resolver is replaced by integration with the host product's HIPAA-compliant identity provider (e.g., OAuth 2.0 / SAML); the swap point is documented as a single interface boundary in `auth.py`.

**Rationale**: `spec.md` puts the host product's identity system out of scope. A bearer-token stub is the smallest construct that satisfies "the caller is authenticated and we know their role, user identity, and (for patients) assigned record" and reads identically to the conventional production shape.

**Authentication failures are not audited within this feature** (FR-001). The audit log scopes to record-access attempts; authentication-layer events belong in the host product's identity-provider audit trail, not in this feature's audit table. This is the safest division of responsibilities and keeps the audit table semantically clean.

## Authorisation: relationship classifier + per-action allow table

**Decision**: A single function `permissions.relationship(user, record_id, db)` classifies the caller's relationship to a record into one of five values:

```python
class Relationship(StrEnum):
    OUTSIDER              = "outsider"               # all unauthorised cases on /records/{id}* endpoints
    CARE_TEAM_CLINICIAN   = "care_team_clinician"    # clinician with active care-team-membership row for this record
    PATIENT_OWN_RECORD    = "patient_own_record"     # patient user whose assigned_record_id == record_id
    PATIENT_OTHER_RECORD  = "patient_other_record"   # patient user whose assigned_record_id != record_id
    COMPLIANCE_OFFICER    = "compliance_officer"     # compliance_officer role
```

The relationship is computed once per request from the caller's `(user_id, role, assigned_record_id)` and the requested `record_id`. A small allow table in `permissions.py` maps `(relationship, action)` to `bool`:

| Action                    | OUTSIDER | CARE_TEAM_CLINICIAN | PATIENT_OWN_RECORD | PATIENT_OTHER_RECORD | COMPLIANCE_OFFICER |
|---------------------------|----------|---------------------|--------------------|----------------------|--------------------|
| `read_record`             | ❌        | ✅                   | ✅                  | ❌                    | ❌                  |
| `append_note`             | ❌        | ✅                   | ❌                  | ❌                    | ❌                  |
| `read_per_record_audit`   | ❌        | ✅                   | ✅                  | ❌                    | ✅                  |
| `read_system_audit_log`   | ❌        | ❌                   | ❌                  | ❌                    | ✅                  |

The relationship is also used to populate the `authorisation_basis` field on audit entries (e.g., `care_team_member`, `not_care_team_member`, `patient_own`, `patient_other`, `compliance_role`, `outsider`).

**Why a single classifier function**: keeps the authorisation logic in one auditable place; makes the `test_permissions.py` matrix straightforward to enumerate; makes the response-builder paths (clinical vs compliance) cleanly selectable by relationship.

**The care-team-membership predicate** (the only non-trivial check) is a one-row indexed SQL probe:

```sql
SELECT 1 FROM care_team_memberships
 WHERE clinician_id = ? AND record_id = ?
   AND status = 'active'
   AND (end_date IS NULL OR end_date > ?)
 LIMIT 1
```

Sub-millisecond on local SQLite. Runs on every clinician-role record-touching request. Fail-closed: a missing row denies access.

**Alternatives considered**:
- **Cache the membership predicate result** (e.g., per-session). Would speed up repeated lookups but introduces staleness in revocation scenarios — a revoked clinician would still see the record until the cache expired. Rejected for the safety risk.
- **Express the rule as a row-level SQL view**. Would push the check into the query layer but obscures the rule; rejected for clarity.

## Byte-equivalent unauthorised response (FR-008)

**Decision**: A single canonical response helper `responses.forbidden_response()` returns:

```http
HTTP/1.1 403 Forbidden
Content-Type: application/json; charset=utf-8
Content-Length: 47

{"error":"forbidden","message":"Access denied."}
```

Used at every code path that resolves to "you cannot see / do this" on the four endpoints:

- A clinician not in the care team requesting any of the three `{id}`-scoped endpoints.
- A patient on a record that is not their `assigned_record_id`.
- A compliance officer attempting `read_record` or `append_note` (clinical endpoints).
- A non-compliance-officer attempting `GET /access-log`.
- A `{id}` that does not correspond to a real record (across all caller types).

The bytes are pinned: same HTTP status (403), same body (`{"error":"forbidden","message":"Access denied."}`, 47 bytes), same `Content-Type`, same `Content-Length`. A test in `test_byte_equivalence.py` constructs identifier pairs `(real-unauthorised, fabricated)` for every caller archetype and asserts the response tuple `(status, content_type, content_length, body_bytes)` is identical across every pair.

**Why HTTP 403 and not 404**: the user description explicitly states "rejected with HTTP 403 within 200ms" for non-care-team clinicians; reconciling this with the byte-equivalent requirement across "any caller without permission, regardless of whether the record exists" forces the unified unauthorised envelope to be 403. The natural reading of HIPAA's minimum-necessary rule (45 CFR §164.502(b)) also frames every access denial as an authorisation outcome rather than a not-found outcome.

**Centralisation by helper, not by inheritance**: every unauthorised code path goes through `responses.forbidden_response()`. The handler converts a service-layer `None` (the "not-authorised" signal) to this response. Static + runtime tests verify the centralisation.

**Why not a constant-time response (defending against timing side channels)**: out of scope for v1. The spec's byte-equivalence requirement is body-bytes-level; timing-channel hardening can be a future-work addition if the threat model requires it. Documented here so the design can be revisited.

## Audit log: synchronous in-transaction write within a 1-second budget, with IP capture

**Decision**: For every record-access attempt — whether the outcome is `permitted` or `denied` — an audit entry is INSERTed in the same `BEGIN IMMEDIATE … COMMIT` transaction as the access decision (and, for `append_note`, the note INSERT). The connection's `timeout=0.15s` enforces the SLA: a contended `COMMIT` raises `OperationalError` within the timeout, which the handler maps to `503 service_unavailable` with the transaction rolled back. (The 150ms timeout is well below the FR-016 1-second SLA, so the audit-write SLA is satisfied automatically by the same mechanism that satisfies the 200ms 403 latency SLA.)

**Originating IP address capture** (FR-014, SC-011): the audit-entry write captures the originating IP address. Sources:

- **Default**: the HTTP request's remote address (from `BaseHTTPRequestHandler.client_address[0]`).
- **Trusted-proxy carve-out**: if the request arrives from a configured trusted-proxy IP (configured at server startup), the right-most trusted IP from the `X-Forwarded-For` header is used. In the v1 PoC the trusted-proxy list defaults to empty (so `X-Forwarded-For` is ignored unless explicitly enabled at deploy time).

**Why no anonymisation**: HIPAA does not require IP anonymisation in audit logs; the forensic value of the IP (for investigating suspicious access patterns) is the priority. The IP is stored verbatim as a string in the `originating_ip_address` column.

**Why audit even on denied attempts**: FR-013 mandates "every record-access event regardless of outcome". Denied attempts (e.g., a clinician not on a patient's care team attempting access) are exactly the events most worth reviewing for compliance — an audit-only-on-success log would miss the suspicious-access patterns auditors care about.

**Why same-transaction with the note INSERT (on `append_note`)**: to preserve the invariant that no observable state change exists without a matching audit entry (FR-013, SC-002). Either both writes succeed and commit, or both fail and roll back.

**Append-only enforcement** (FR-015): no `UPDATE audit_entries` or `DELETE FROM audit_entries` SQL exists in `store.py`. A static grep probe in `test_invariants.py` verifies this; a runtime probe takes hash snapshots of existing rows before/after arbitrary endpoint activity and asserts no row's content has changed.

**Retention floor** (FR-017): 7 years; enforced by the absence of any DELETE code path against `audit_entries`. Operational retention scheduling beyond 7 years is out of scope.

**Alternatives considered**:
- **Async audit writer (queue + background worker)**. Decouples audit-write latency from the response path; would let the 403 path return in <50ms even under heavy contention. **Rejected** because FR-013/FR-016 require the audit write to be durable before the response is sent — otherwise we could expose state without a matching audit entry on a crash.
- **Logging-based audit** (e.g., stderr / syslog). Loses queryability for `GET /access-log` and `GET /records/{id}/audit`. Rejected.

## Compliance-officer response: a separate response-builder module (FR-019)

**Decision**: A dedicated module `compliance_response.py` is the **sole** code path for compliance-officer responses (both `GET /access-log` and `GET /records/{id}/audit` when called by a compliance officer). The module deliberately does not import or query any clinical-content table or column:

```python
# compliance_response.py — FR-019 content-blindness invariant module
#
# Allowed: stdlib + the AuditEntry dataclass.
# DELIBERATELY NOT IMPORTED: clinical_notes content, patient_summaries content,
#                            encounters content, records.patient_name / date_of_birth.

from .models import AuditEntry

def build_access_log_response(entries: list[AuditEntry]) -> dict:
    """Content-blind response for GET /access-log (system-wide)."""
    return {"events": [_event(e) for e in entries]}

def build_per_record_audit_response_for_compliance(
    record_id: str, entries: list[AuditEntry],
) -> dict:
    """Content-blind response for GET /records/{id}/audit when caller is compliance_officer."""
    return {"record_id": record_id, "events": [_event(e) for e in entries]}

def _event(e: AuditEntry) -> dict:
    return {
        "record_id":                e.record_id,
        "accessor_user_id":         e.accessor_user_id,
        "accessor_user_display_name": e.accessor_user_display_name,
        "accessor_role":            e.accessor_role,
        "timestamp":                e.timestamp,
        "operation":                e.operation,
        "outcome":                  e.outcome,
        "originating_ip_address":   e.originating_ip_address,
        "note_id":                  e.note_id,  # opaque id; reveals no content
    }
```

The forbidden-keys list from FR-019 is enforced by two independent probes:

1. **Static probe** in `test_invariants.py` greps `compliance_response.py` for any access to clinical-content columns (`clinical_notes.body`, `patient_summaries.*`, `encounters.summary`, `records.patient_name` / `records.date_of_birth`). Fails if any such access is present in the module's code.
2. **Runtime probe** in `test_compliance_content_blindness.py` walks every compliance response across every seeded scenario (including records with long note bodies, allergies, key warnings, recent encounters) and recursively asserts that none of `body`, `note_body`, `content`, `note_content`, `allergies`, `key_warnings`, `current_medications`, `recent_encounters`, `encounters`, `summary`, `patient_name`, `name`, `date_of_birth`, or `dob` appear at any depth of the response.

**Why a separate module rather than a flag on a shared builder**: a flag is a runtime check; a separate module is a static structural guarantee. FR-019 is an absence invariant — proving absence by code-path structure is stronger than proving absence by a runtime conditional. The module split also makes the security audit trivial: a reviewer reads `compliance_response.py` (one short file) and confirms by inspection that no clinical content can leak.

**Distinct from the clinician/patient response builder**: the clinical-record response (for `GET /records/{id}` and the clinician/patient view of `GET /records/{id}/audit`) lives in `clinical_record_response.py`. The two modules produce **structurally identical event lists** for the audit endpoint (same audit-entry schema), but live in separate modules so the absence invariant for compliance is verifiable by static inspection of one short file.

## Endpoints and routing

**Decision**: Four endpoints exactly as the spec mandates, with `record_id` in the URL path (FR-020):

- `GET /records/{id}` — read record (clinician on care team OR patient on their own record)
- `POST /records/{id}/notes` — append a clinical note (clinician on care team only)
- `GET /records/{id}/audit` — read per-record audit log (clinician on care team OR patient on their own record OR compliance officer)
- `GET /access-log` — system-wide audit log (compliance officer only)

The `{id}` is an opaque `record_id` — an internal system handle that is not personally identifying. Patient demographics (name, date of birth, social security number) never appear in URL paths; a static probe `test_no_url_pii.py` verifies this by greping the routing table.

**Why `record_id` in URL paths is acceptable**: the `record_id` is generated by this feature's storage layer and never derived from patient demographics. It is not, on its own, personally identifying — it cannot be reversed to a person without access to the records table. URL-path inclusion is therefore acceptable.

**405 vs byte-equivalent 403 for PATCH/DELETE against notes**: there is no PATCH or DELETE route registered for `/records/{id}/notes/{note_id}` (or any note-mutation path). A request with such a method against the notes resource will receive either `405 Method Not Allowed` (if the server's routing distinguishes "path matched, method didn't") or fall through to the byte-equivalent 403 (if the routing treats unmatched paths uniformly). Both communicate "no such operation exists in this feature". The append-only invariant (FR-012) is satisfied regardless.

## Note creation transaction (`POST /records/{id}/notes`)

**Decision**: A `POST /records/{id}/notes` request runs:

1. Resolve authentication. On failure → `401 unauthenticated`; no audit entry.
2. Validate the body (per FR-010, all fields reported together). On failure → `400 validation_error`; no audit entry written (validation failure precedes the access decision).
3. Open `BEGIN IMMEDIATE` transaction.
4. Compute `permissions.relationship(user, record_id, db)`. If `relationship != CARE_TEAM_CLINICIAN`: INSERT one audit entry with `operation=append`, `outcome=denied`, the appropriate `authorisation_basis`; COMMIT; return the byte-equivalent 403.
5. Otherwise: INSERT into `clinical_notes` with snapshotted `author_display_name` and `author_role`; INSERT one audit entry with `operation=append`, `note_id=<the new note's id>`, `outcome=permitted`; COMMIT; return `201 Created` with the new note's id.
6. On `OperationalError` during COMMIT (timeout reached at 150ms): roll back; return `503 service_unavailable` with no note persisted and no audit entry.

The note INSERT and audit INSERT are atomic — they succeed or fail together. A schema CHECK constraint on `audit_entries` (see data-model.md) enforces that `note_id` is non-null exactly when `operation = 'append' AND outcome = 'permitted'`.

## Project layout

**Decision**: All code lives in a new top-level Python package `src/hipaa_clinical_records/`. Tests live under `tests/hipaa_clinical_records/`. The package's module shape:

```text
src/hipaa_clinical_records/
├── __init__.py
├── __main__.py
├── server.py                       # ThreadingHTTPServer wiring + dispatch + CLI
├── handlers.py                     # Per-endpoint request handlers; captures originating IP
├── responses.py                    # forbidden_response() — pinned 403 envelope (FR-008)
├── auth.py                         # Bearer-token resolution; AuthenticatedCaller dataclass
├── permissions.py                  # relationship() classifier + per-action allow table
├── service.py                      # Business logic; always writes one audit entry per attempt
├── clinical_record_response.py     # FR-014/FR-010 fixed-shape record response + clinician/patient audit-list response
├── compliance_response.py          # FR-019 content-blind compliance-officer audit responses (sole code path; no clinical-table access)
├── validation.py                   # Field validation; reports all errors at once
├── store.py                        # SQLite schema, connection, all SQL (WAL mode, timeout=0.15s)
├── models.py                       # Dataclasses + enums
└── errors.py                       # Typed exceptions
```

13 source modules. Each invariant or invariant-pair is contained in one auditable place:

- `responses.py` — the byte-equivalent 403 envelope (FR-008).
- `permissions.py` — the relationship classifier + allow table (FR-004 through FR-007).
- `clinical_record_response.py` — the record-content response shape (the structure under FR-010-related fields).
- `compliance_response.py` — the FR-019 content-blindness invariant.
- `store.py` — the append-only invariants for `clinical_notes` and `audit_entries`, the 150ms write-timeout that enforces both SLAs, and the schema CHECKs that encode structural invariants.

## What is intentionally NOT researched

These are out of scope per the spec and need no design here:

- Authentication implementation (token issuance / refresh / revocation).
- Identity / role assignment; care-team-roster management (host-product features).
- Multi-role users; role inheritance; emergency-access (break-glass) overrides.
- Patient delegate / guardian flows.
- Editing or deleting clinical notes after submission.
- Tamper detection on audit entries beyond append-only-by-code-path-absence.
- National-system integration; HIPAA breach notification workflow (§164.404); subject access requests (§164.524).
- Encryption at rest / in transit (host-deployment concerns).
- Constant-time response (timing-side-channel defence) — out of scope for v1.
- Pagination cursor on `GET /access-log` beyond the `from` / `to` / `limit` filters.
- Real-time SIEM-style alerting on suspicious access patterns.

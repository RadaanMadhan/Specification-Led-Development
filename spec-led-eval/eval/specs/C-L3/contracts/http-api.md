# HTTP API Contract: HIPAA Hospital Clinical Record Access

**Branch**: `013-hipaa-clinical-records` | **Date**: 2026-05-17

The service exposes exactly four endpoints. Any other path returns the byte-equivalent `403 forbidden` response. All requests and responses use `application/json; charset=utf-8`.

## Authentication (all endpoints)

```
Authorization: Bearer <token>
```

Resolution in `server.py` **before** any handler runs (FR-001):

1. Header missing or malformed → `401 unauthenticated` with body `{"error":"unauthenticated","message":"Authentication required."}`. No audit entry.
2. Token unknown or expired → `401 unauthenticated`, same body. No audit entry.
3. Token resolves to a `User`. The handler proceeds with `(user_id, user_display_name, role, assigned_record_id)` in scope, plus `originating_ip_address` captured from the request.

Authentication failures do not produce audit entries for this feature; they belong in the host product's identity-provider audit trail.

## Byte-equivalent forbidden response (FR-008)

A single canonical response is returned at every "you cannot see / do this" code path:

```http
HTTP/1.1 403 Forbidden
Content-Type: application/json; charset=utf-8
Content-Length: 47

{"error":"forbidden","message":"Access denied."}
```

Body bytes, `Content-Type`, and `Content-Length` are identical across:

- A clinician not in the record's care team requesting any of the three `{id}`-scoped endpoints.
- A patient on a record that is not their `assigned_record_id`.
- A compliance officer attempting `GET /records/{id}` or `POST /records/{id}/notes` (clinical-content endpoints).
- A non-compliance-officer attempting `GET /access-log`.
- A `{id}` that does not correspond to a real record (across all caller types).

A single helper `responses.forbidden_response()` returns the canonical bytes; static + runtime tests assert every refused code path uses it.

`Date` and other transport-layer headers are out of scope of the byte-equivalence requirement.

## Common error envelope (other codes)

| HTTP status | error code              | When                                                                                                       |
|-------------|-------------------------|------------------------------------------------------------------------------------------------------------|
| 400         | `validation_error`      | Body malformed; required field missing; out-of-range value (e.g., `body` length, future `encounter_date`); invalid enum value; bad `limit`/`from`/`to` query parameter. `field_errors` array carries per-field detail. |
| 401         | `unauthenticated`       | Missing / invalid bearer token. Returned before any handler logic; no audit entry written.                  |
| 403         | `forbidden`             | Byte-equivalent unauthorised response (see above).                                                          |
| 405         | `method_not_allowed`    | PATCH / DELETE against a notes resource — notes are append-only, no such routes are registered.            |
| 503         | `service_unavailable`   | Audit write would exceed the 1-second SLA (FR-016); operation rolled back; no state change.                |
| 500         | `internal_error`        | Unexpected failure.                                                                                          |

### Validation-error envelope

```json
{
  "error": "validation_error",
  "message": "One or more fields are invalid.",
  "field_errors": [
    { "field": "body", "message": "Body must be 1–8000 characters after trimming." },
    { "field": "note_type", "message": "Must be one of: progress, assessment, plan, observation, discharge_summary." },
    { "field": "encounter_date", "message": "Encounter date must not be in the future." }
  ]
}
```

All offending fields reported at once (FR-010).

## Permission matrix

(Source-of-truth table; see `research.md` for the supporting relationship classifier.)

| Endpoint                            | clinician in CT for `{id}` | clinician not in CT | patient w/ `{id}=assigned_record_id` | patient w/ other `{id}` | compliance_officer |
|-------------------------------------|----------------------------|---------------------|---------------------------------------|--------------------------|--------------------|
| `GET /records/{id}`                 | `200 OK`                   | `403` byte-equivalent within 200ms | `200 OK`                              | `403` byte-equivalent    | `403` byte-equivalent |
| `POST /records/{id}/notes`          | `201 Created`              | `403` byte-equivalent | `403` byte-equivalent                 | `403` byte-equivalent    | `403` byte-equivalent |
| `GET /records/{id}/audit`           | `200 OK`                   | `403` byte-equivalent | `200 OK` (own record only)            | `403` byte-equivalent    | `200 OK`           |
| `GET /access-log`                   | `403` byte-equivalent       | `403` byte-equivalent | `403` byte-equivalent                 | (n/a)                    | `200 OK`           |

---

## `GET /records/{id}` — read a record

### Request

```http
GET /records/<record_id> HTTP/1.1
Authorization: Bearer <token>
```

`{id}` is the opaque `record_id` (FR-020). Patient demographics never appear in URL paths.

### Authorisation

Per the matrix. The 403 path for a clinician-not-in-care-team caller MUST complete within 200ms at p99 (FR-009).

### Behaviour

In one transaction:

1. Authenticate; resolve `(user_id, role, assigned_record_id, ip)`. On failure → `401`; no audit.
2. Compute `permissions.relationship(user, record_id, db)`.
3. INSERT one audit entry with `operation='read'`, the appropriate `outcome` and `authorisation_basis`, the captured `originating_ip_address`.
4. COMMIT. On timeout (>150ms) → `503 service_unavailable` with rollback.
5. If permitted: return the record body (see below). Otherwise: byte-equivalent `403`.

### Responses

**200 OK** — record body, with fixed key order so any reasonable renderer hits the safety-relevant fields first:

```json
{
  "record_id": "<opaque-record-id>",
  "date_of_birth": "1972-04-19",
  "patient_name": "Patient Name",
  "allergies": [
    { "substance": "Penicillin", "severity": "high", "notes": "Anaphylaxis 2019" }
  ],
  "key_warnings": [
    { "category": "fall_risk", "text": "Recent unsteady gait on standing" }
  ],
  "current_medications": [
    { "name": "Atorvastatin", "dose": "20 mg", "frequency": "once daily" }
  ],
  "recent_encounters": [
    { "encounter_date": "2026-05-10", "encounter_type": "GP visit", "summary": "Routine review; stable." }
  ],
  "notes_count": 12,
  "notes": [
    {
      "id": "<note-uuid>",
      "author_user_id": "<clinician-uuid>",
      "author_display_name": "Dr Alice Carter",
      "author_role": "clinician",
      "created_at": "2026-05-12T09:14:33.221Z",
      "note_type": "progress",
      "encounter_date": "2026-05-12",
      "body": "Patient reports improvement in pain. Continuing physiotherapy plan."
    }
  ]
}
```

Field order: `record_id`, `date_of_birth`, `patient_name`, `allergies`, `key_warnings`, `current_medications`, `recent_encounters`, `notes_count`, `notes`. Notes ordered by `(created_at, id)` ascending (oldest first).

**403 `forbidden` (byte-equivalent)** — see envelope above.

**503 `service_unavailable`** — audit write exceeded 150ms.

---

## `POST /records/{id}/notes` — clinician appends a note

### Request

```http
POST /records/<record_id>/notes HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "body": "Patient reports improvement in pain. Continuing physiotherapy plan.",
  "note_type": "progress",
  "encounter_date": "2026-05-17"
}
```

| Field            | Type   | Required | Notes                                                                          |
|------------------|--------|----------|--------------------------------------------------------------------------------|
| `body`           | string | yes      | 1–8000 chars after trimming whitespace; non-empty after trim.                  |
| `note_type`      | string | yes      | One of `progress`, `assessment`, `plan`, `observation`, `discharge_summary`.   |
| `encounter_date` | string | no       | ISO `YYYY-MM-DD`. Defaults to today's date (UTC). Must not be in the future.   |

`record_id` is in the URL, not the body.

### Authorisation

Per the matrix: only clinicians in the record's care team. All other callers receive `403 forbidden` byte-equivalent.

### Behaviour

In one transaction:

1. Authenticate.
2. Validate body. Reports all offending fields. On failure → `400 validation_error`; no audit (validation precedes the access decision).
3. Compute relationship.
4. If `CARE_TEAM_CLINICIAN`: INSERT into `clinical_notes` with snapshotted `author_display_name`, `author_role='clinician'`; INSERT one audit entry with `operation='append'`, `note_id=<new>`, `outcome='permitted'`, `authorisation_basis='care_team_member'`; return `201 Created`.
5. Otherwise: INSERT only the audit entry with `note_id=NULL`, `outcome='denied'`, appropriate `authorisation_basis`; return `403 forbidden` byte-equivalent.
6. COMMIT. On timeout → `503` with rollback (note + audit both rolled back).

### Responses

**201 Created**:

```json
{
  "id": "<new-note-uuid>",
  "record_id": "<record-id>",
  "author_user_id": "<your-user-id>",
  "author_display_name": "Dr Alice Carter",
  "author_role": "clinician",
  "created_at": "2026-05-17T10:14:33.221Z",
  "note_type": "progress",
  "encounter_date": "2026-05-17",
  "body": "Patient reports improvement in pain. Continuing physiotherapy plan."
}
```

**400 `validation_error`** — see envelope.

**403 `forbidden` (byte-equivalent)** — see envelope.

**405 `method_not_allowed`** — for `PATCH /records/{id}/notes/{note_id}` or `DELETE …` (no such routes exist; notes are append-only).

**503 `service_unavailable`** — audit write exceeded budget.

---

## `GET /records/{id}/audit` — read per-record audit log

### Request

```http
GET /records/<record_id>/audit HTTP/1.1
Authorization: Bearer <token>
```

### Authorisation

| Caller                                  | Outcome                                                                       |
|-----------------------------------------|-------------------------------------------------------------------------------|
| Clinician in the record's care team     | `200 OK`                                                                      |
| Clinician not in the care team          | `403 forbidden` byte-equivalent                                               |
| Patient with `assigned_record_id == id` | `200 OK`                                                                      |
| Patient with different `assigned_record_id` | `403 forbidden` byte-equivalent                                            |
| Compliance officer                      | `200 OK` (content-blind shape produced by `compliance_response.py`)            |
| Record id does not exist                | `403 forbidden` byte-equivalent (across all caller types)                     |

### Behaviour

1. Authenticate.
2. Compute relationship.
3. INSERT one audit entry with `operation='list'`, the appropriate outcome and authorisation_basis. (Yes — listing the audit log is itself a recorded access event for FR-013.)
4. SELECT every `audit_entries` row for `record_id` ordered `(timestamp ASC, id ASC)`.
5. Build the response:
   - For clinician or patient caller: via `clinical_record_response.build_per_record_audit_for_clinical(record_id, entries)`.
   - For compliance caller: via `compliance_response.build_per_record_audit_for_compliance(record_id, entries)` — the sole code path that produces compliance responses; structurally does not access any clinical-content table (FR-019).
6. COMMIT. On timeout → `503`.

### Responses

**200 OK** — events in chronological order:

```json
{
  "record_id": "<opaque-record-id>",
  "events": [
    {
      "record_id": "<opaque-record-id>",
      "accessor_user_id": "<clinician-uuid>",
      "accessor_user_display_name": "Dr Alice Carter",
      "accessor_role": "clinician",
      "timestamp": "2026-05-17T10:14:33.221Z",
      "operation": "read",
      "outcome": "permitted",
      "originating_ip_address": "203.0.113.42",
      "note_id": null
    }
  ]
}
```

`note_id` is null for `read` and `list` events; present for `append` events. The event schema is identical regardless of which builder produces it (the split between `clinical_record_response.py` and `compliance_response.py` is for the FR-019 absence invariant; the on-the-wire shape is the same).

**403 `forbidden` (byte-equivalent)** — for the unauthorised cases above.

---

## `GET /access-log` — system-wide audit log (compliance officer only)

### Request

```http
GET /access-log?accessor_user_id=<id>&record_id=<id>&from=<iso>&to=<iso>&limit=1000 HTTP/1.1
Authorization: Bearer <token>
```

| Query parameter      | Type    | Required | Notes                                                                       |
|----------------------|---------|----------|-----------------------------------------------------------------------------|
| `accessor_user_id`   | string  | no       | Filter to entries with this `accessor_user_id`.                             |
| `record_id`          | string  | no       | Filter to entries on this `record_id`.                                      |
| `from`               | string  | no       | ISO 8601 datetime. Inclusive lower bound on `timestamp`.                    |
| `to`                 | string  | no       | ISO 8601 datetime. Exclusive upper bound on `timestamp`.                    |
| `limit`              | integer | no       | Default 1000; max 10000. Out-of-range → `400 validation_error`.             |

All filters combine as a logical AND. Results ordered `timestamp DESC, id DESC` (most-recent first).

### Authorisation

| Caller              | Outcome                                            |
|---------------------|----------------------------------------------------|
| Compliance officer  | `200 OK` with the audit list                       |
| Clinician (any)     | `403 forbidden` byte-equivalent                    |
| Patient (any)       | `403 forbidden` byte-equivalent                    |
| Unauthenticated     | `401 unauthenticated`                              |

### Behaviour

1. Authenticate.
2. If `role != 'compliance_officer'` → byte-equivalent `403`. No audit entry written (the `GET /access-log` endpoint is itself the audit log; listing it for the compliance officer is the only legitimate use; an unauthorised attempt that doesn't reach the legitimate query path is captured by the same byte-equivalent response without further audit).
3. If `role == 'compliance_officer'`: validate filters (`limit` in range, `from`/`to` are valid ISO 8601); INSERT one audit entry with `operation='list'`, `record_id=NULL`, `outcome='permitted'`, `authorisation_basis='compliance_role'`; SELECT filtered audit entries.
4. Build the response via `compliance_response.build_access_log_response(entries)`. The response is content-blind by construction (FR-019).
5. COMMIT (only the audit-INSERT — the SELECT is read-only). On timeout → `503`.

### Responses

**200 OK** — content-blind system-wide audit list:

```json
{
  "events": [
    {
      "record_id": "<opaque-record-id>",
      "accessor_user_id": "<clinician-uuid>",
      "accessor_user_display_name": "Dr Alice Carter",
      "accessor_role": "clinician",
      "timestamp": "2026-05-17T10:14:33.221Z",
      "operation": "read",
      "outcome": "permitted",
      "originating_ip_address": "203.0.113.42",
      "note_id": null
    },
    {
      "record_id": null,
      "accessor_user_id": "<compliance-officer-uuid>",
      "accessor_user_display_name": "Compliance Officer Carla",
      "accessor_role": "compliance_officer",
      "timestamp": "2026-05-17T10:15:00.000Z",
      "operation": "list",
      "outcome": "permitted",
      "originating_ip_address": "10.0.0.5",
      "note_id": null
    }
  ]
}
```

The compliance officer's own `GET /access-log` calls are themselves audited (recursive auditing — required for §164.312(b) audit-of-the-auditor) and appear in subsequent results.

**No clinical content** in any event — the runtime probe `test_compliance_content_blindness.py` walks every response across seeded scenarios and asserts the absence of every forbidden clinical-content key (FR-019).

**400 `validation_error`** — bad `limit`, malformed `from`/`to`.

**403 `forbidden` (byte-equivalent)** — caller is not a compliance officer.

## Invariants the contract is built to expose

| Invariant                                                                                  | Surfaced by                                                                                                                                             |
|--------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Authentication required (FR-001, SC-009)                                                    | `401 unauthenticated` from the boundary before any handler runs                                                                                          |
| Byte-equivalent 403 envelope on every "you can't see / do this" (FR-008, SC-003)            | Single `responses.forbidden_response()` helper; pinned `(status=403, content_type, content_length=47, body)`                                            |
| 200ms p99 latency on the 403 path (FR-009, SC-004)                                          | Tight SQLite `timeout=0.15s`; perf probe in `test_perf_403_latency.py`                                                                                  |
| Care-team gating for clinician access (FR-004, SC-010)                                      | Indexed SQL probe in `permissions.can_access`; fail-closed on missing membership                                                                          |
| Patient self-access matrix (FR-006)                                                          | `permissions.relationship` checks `user.assigned_record_id == record_id` to distinguish `PATIENT_OWN_RECORD` from `PATIENT_OTHER_RECORD`                  |
| Compliance content-blindness (FR-019, SC-006)                                                | `compliance_response.py` module structurally cannot access clinical-content tables; static + runtime probes                                              |
| Notes append-only (FR-012, SC-007)                                                            | No PATCH/DELETE routes; no UPDATE/DELETE SQL on `clinical_notes`; schema CHECK `author_role = 'clinician'`                                                |
| Always-on audit (FR-013, SC-001, SC-002)                                                     | Audit INSERT for every record-access code path; in same transaction as state change                                                                       |
| IP captured on every audit (SC-011)                                                          | `audit_entries.originating_ip_address NOT NULL`; captured in `handlers.py` from `client_address` or trusted-proxy `X-Forwarded-For`                       |
| Audit immutability + 7-year retention (FR-015, FR-017, SC-008)                              | No UPDATE/DELETE SQL on `audit_entries`; static + runtime probes; operational retention scheduling out of scope                                            |
| 1-second audit SLA (FR-016, SC-005)                                                          | Same `timeout=0.15s` that satisfies the 200ms SLA — well within 1s. `OperationalError` → `503 service_unavailable` with rollback                          |

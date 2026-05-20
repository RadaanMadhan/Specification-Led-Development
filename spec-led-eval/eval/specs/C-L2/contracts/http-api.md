# HTTP API Contract: Hospital Clinical Record Access

**Branch**: `012-hospital-clinical-records` | **Date**: 2026-05-17

The service exposes exactly three endpoints. Any other path returns the byte-equivalent `not_found` response. All requests and responses use `application/json; charset=utf-8`.

## Authentication (all endpoints)

```
Authorization: Bearer <token>
```

Resolution in `server.py` **before** any handler runs (FR-001):

1. Header missing or malformed → `401 unauthenticated` with body `{"error":"unauthenticated","message":"Authentication required."}`. No audit entry is written.
2. Token unknown to the `tokens` table or expired → `401 unauthenticated`, same body.
3. Token resolves to a `User`. The handler proceeds with `(user_id, user_display_name, user_role)` in scope.

When authentication succeeds, every clinical access produces an audit entry (FR-012). Authentication failures do not — the authentication-failure log lives elsewhere in the host product's identity-provider stack, not in this feature's patient-level audit table.

## Byte-equivalent not-found response (FR-006)

A single canonical response is returned for every "you cannot see this" case across all three endpoints:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8
Content-Length: 48

{"error":"not_found","message":"No such record."}
```

Returned for:

- The patient identifier in the request body does not correspond to any real patient (any endpoint).
- The caller is a clinical-role user (`doctor`, `nurse`, `pharmacist`, `clinical_admin`) but is **not** on the patient's care team (the record-lookup and note-addition endpoints).
- The caller is a `hospital_administrator` attempting to use the record-lookup or note-addition endpoint (these endpoints are clinical-only; administrators are not in any care team and therefore receive the byte-equivalent unauthorised response).
- The caller is a clinical role attempting to use the audit-search endpoint (administrator-only; the endpoint's existence is not signalled to clinicians).

Body bytes, `Content-Type`, and `Content-Length` are identical across all the above cases. Transport-layer headers (`Date`, etc.) are out of scope of the byte-equivalence requirement.

A single helper `responses.not_found_response()` returns the canonical bytes; static + runtime tests assert every refused code path uses it.

## Common error envelope (other codes)

```json
{ "error": "<code>", "message": "<human-readable description>" }
```

| HTTP status | error code            | When                                                                                          |
|-------------|-----------------------|-----------------------------------------------------------------------------------------------|
| 400         | `validation_error`    | Body malformed; required field missing; body length out of range; invalid `note_type`; future `encounter_date`. `field_errors` array carries per-field detail. |
| 401         | `unauthenticated`     | Missing / invalid bearer token. Returned before any handler logic; no audit entry written.    |
| 404         | `not_found`           | Byte-equivalent unauthorised response (see above).                                            |
| 503         | `service_unavailable` | Audit write would exceed the 2-second SLA (FR-015); the operation rolled back; no state change. |
| 500         | `internal_error`      | Unexpected failure.                                                                            |

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

Reports **all** offending fields at once (FR-009).

---

## `POST /records/lookup` — clinician reads a record

### Request

```http
POST /records/lookup HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{ "patient_id": "<opaque-patient-id>" }
```

| Field        | Type   | Required | Notes                                                                          |
|--------------|--------|----------|--------------------------------------------------------------------------------|
| `patient_id` | string | yes      | Opaque identifier. Body-only — never in URL paths (FR-003).                    |

### Authorisation

The caller MUST hold a clinical role (`doctor`, `nurse`, `pharmacist`, `clinical_admin`) AND be a member of the patient's care team for an active episode of care (FR-004). The `hospital_administrator` role cannot use this endpoint and receives the byte-equivalent 404.

### Behaviour

In one `BEGIN IMMEDIATE … COMMIT` transaction:

1. Authenticate; resolve `(user_id, user_display_name, user_role)`. On failure → `401`; no audit entry.
2. Validate the body; missing or non-string `patient_id` → `400 validation_error`; no audit entry.
3. Compute the access outcome:
   - Patient exists AND clinical role AND care-team membership exists → `outcome = "permitted"`, `authorisation_basis = "care_team_member"`.
   - Patient exists AND (administrator role OR no care-team membership) → `outcome = "denied"`, `authorisation_basis = "not_care_team_member"`.
   - Patient does not exist → `outcome = "not_found_or_denied"`, `authorisation_basis = "patient_not_found"`.
4. INSERT one audit entry with `access_type = "read"`, the snapshotted user fields, the patient_id as presented, the timestamp, the outcome, and the authorisation_basis.
5. COMMIT. On timeout (>1.8s) → `503 service_unavailable`, rollback.
6. If `outcome = "permitted"`: return the patient record (see below). Otherwise: return the byte-equivalent 404.

### Responses

**200 OK** — only for `outcome = "permitted"`:

The JSON response has a fixed key order (FR-007, FR-019, FR-020):

```json
{
  "patient_id": "<opaque-patient-id>",
  "date_of_birth": "1972-04-19",
  "name": "Patient Name",
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
      "author_role": "doctor",
      "created_at": "2026-05-12T09:14:33.221Z",
      "note_type": "progress",
      "encounter_date": "2026-05-12",
      "body": "Patient reports improvement in pain. Continuing physiotherapy plan."
    }
  ]
}
```

Field order test (`test_clinical_safety.py`): the first five keys are exactly `["patient_id", "date_of_birth", "name", "allergies", "key_warnings"]` (FR-019). `notes_count` appears immediately before `notes` (FR-020). Notes are ordered by `(created_at, id)` ascending — oldest first; the host application's UI may reverse the order for display but the contract guarantees a stable forward chronology.

`allergies` and `key_warnings` are always present as arrays in the response shape, even when empty.

**400 `validation_error`** — `patient_id` missing or non-string in the request body.

**404 `not_found` (byte-equivalent)** — see envelope.

**503 `service_unavailable`** — audit write exceeded the 2-second budget.

---

## `POST /records/notes` — clinician adds a clinical note

### Request

```http
POST /records/notes HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "patient_id": "<opaque-patient-id>",
  "body": "Patient reports improvement in pain. Continuing physiotherapy plan.",
  "note_type": "progress",
  "encounter_date": "2026-05-17"
}
```

| Field            | Type   | Required | Notes                                                                                                |
|------------------|--------|----------|------------------------------------------------------------------------------------------------------|
| `patient_id`     | string | yes      | Opaque identifier. Body-only.                                                                        |
| `body`           | string | yes      | 1–8000 characters after trimming surrounding whitespace. Non-empty after trim.                       |
| `note_type`      | string | yes      | One of `progress`, `assessment`, `plan`, `observation`, `discharge_summary`.                         |
| `encounter_date` | string | no       | ISO `YYYY-MM-DD`. Defaults to today's date (UTC) if absent. Must not be in the future (FR-009).      |

### Authorisation

Same as `POST /records/lookup` — clinical role AND care-team membership (FR-004). The `hospital_administrator` role cannot use this endpoint.

### Behaviour

In one `BEGIN IMMEDIATE … COMMIT` transaction:

1. Authenticate; resolve `(user_id, user_display_name, user_role)`.
2. Validate the body. Report **every** offending field in one response (FR-009).
3. Compute the access outcome (same logic as record-lookup).
4. If `outcome = "permitted"`: INSERT into `clinical_notes` with snapshotted `author_display_name` and `author_role`; INSERT one audit entry with `access_type = "add_note"`, `note_id = <new>`, `outcome = "permitted"`, `authorisation_basis = "care_team_member"`.
5. Otherwise (denied or not-found): INSERT only the audit entry with `note_id = NULL`, the appropriate outcome and authorisation_basis. No note created.
6. COMMIT. On timeout → `503` with rollback (neither note nor audit persisted).

### Responses

**201 Created** (only for `outcome = "permitted"`):

```json
{
  "id": "<new-note-uuid>",
  "patient_id": "<opaque-patient-id>",
  "author_user_id": "<your-user-id>",
  "author_display_name": "Dr Alice Carter",
  "author_role": "doctor",
  "created_at": "2026-05-17T10:14:33.221Z",
  "note_type": "progress",
  "encounter_date": "2026-05-17",
  "body": "Patient reports improvement in pain. Continuing physiotherapy plan."
}
```

**400 `validation_error`** — see envelope.

**404 `not_found` (byte-equivalent)** — see envelope (covers patient-not-found, non-care-team clinician, and administrator-attempting-write).

**503 `service_unavailable`** — audit/note write exceeded budget.

**Append-only constraint**: there is no `PATCH /records/notes/{id}` or `DELETE /records/notes/{id}` endpoint. Such requests against this feature return either `405 Method Not Allowed` (if the server matches the path prefix but not the method) or `404 not_found` (if the path is unmatched entirely). Either is acceptable — both communicate "no such operation exists in this feature's surface" (FR-011).

---

## `POST /audit/search` — administrator views access log for a patient

### Request

```http
POST /audit/search HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{ "patient_id": "<opaque-patient-id>" }
```

### Authorisation

The caller MUST hold the `hospital_administrator` role (FR-017). Any other authenticated caller (any clinical role) receives the byte-equivalent 404 — the endpoint's existence is not signalled to non-administrators.

### Behaviour

1. Authenticate; resolve role.
2. If `user_role != "hospital_administrator"` → return the byte-equivalent 404. **No audit entry is written** for this case — the audit log audits clinical-record access attempts, and this endpoint is not a clinical-record access. (Audit-of-the-auditor is out of scope for v1; the administrator-endpoint is logged separately by the operational infrastructure outside this feature.)
3. Validate the body. Missing `patient_id` → `400 validation_error`.
4. INSERT one audit entry with `access_type = "list_audit"`, `outcome = "permitted"`, `authorisation_basis = "administrator_role"`. (Yes — administrator audit-listing is itself a clinical-record-access event in the sense that it touches the audit log for a patient; it is recorded as such.)
5. SELECT all `audit_entries` rows for the given `patient_id`, ordered by `(occurred_at, id)` ascending (chronological, oldest first).
6. If empty: return the byte-equivalent 404 — the administrator cannot distinguish "patient exists but has no recorded accesses" from "patient does not exist". Both yield the byte-equivalent unauthorised response.
7. Otherwise: build the response via `admin_response.build_admin_audit_response()` — the sole code path for administrator responses (see research.md for the FR-018 invariant module).
8. COMMIT (only the audit INSERT — the SELECT is read-only and outside the transaction). On timeout → `503`.

### Responses

**200 OK — content-blind audit list**:

```json
{
  "patient_id": "<opaque-patient-id>",
  "events": [
    {
      "user_id": "<clinician-uuid>",
      "user_display_name": "Dr Alice Carter",
      "user_role": "doctor",
      "occurred_at": "2026-05-17T10:14:33.221Z",
      "access_type": "read",
      "note_id": null,
      "outcome": "permitted",
      "authorisation_basis": "care_team_member"
    },
    {
      "user_id": "<other-clinician-uuid>",
      "user_display_name": "Dr Bob Smith",
      "user_role": "doctor",
      "occurred_at": "2026-05-17T11:02:00.000Z",
      "access_type": "read",
      "note_id": null,
      "outcome": "denied",
      "authorisation_basis": "not_care_team_member"
    },
    {
      "user_id": "<nurse-uuid>",
      "user_display_name": "Nurse Carol Lee",
      "user_role": "nurse",
      "occurred_at": "2026-05-17T12:30:00.000Z",
      "access_type": "add_note",
      "note_id": "<note-uuid>",
      "outcome": "permitted",
      "authorisation_basis": "care_team_member"
    }
  ]
}
```

**The response contains ONLY** the keys `patient_id` and `events`, and within each event ONLY the keys `user_id`, `user_display_name`, `user_role`, `occurred_at`, `access_type`, `note_id`, `outcome`, `authorisation_basis`. No clinical-content key (`body`, `note_body`, `content`, `note_content`, `allergies`, `key_warnings`, `current_medications`, `recent_encounters`, `encounters`, `summary`, `name`, `patient_name`, `date_of_birth`, `dob`) appears at any depth. The runtime probe in `test_admin_content_blindness.py` walks every response across seeded scenarios and asserts this.

`note_id` is `null` for `access_type ∈ {"read", "list_audit"}`. For `access_type = "add_note"` events, `note_id` is the opaque identifier of the note that was added — it reveals **no** content.

**400 `validation_error`** — `patient_id` missing or non-string.

**404 `not_found` (byte-equivalent)** — caller is not `hospital_administrator`, OR `patient_id` has no audit entries (administrator cannot distinguish absent-patient from no-recorded-accesses).

**503 `service_unavailable`** — audit-listing INSERT exceeded budget.

## Invariants the contract is built to expose

| Invariant                                                                                  | Surfaced by                                                                                                                                             |
|--------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Authentication required (FR-001, SC-004)                                                    | `401 unauthenticated` from the boundary before any handler runs                                                                                          |
| No patient_id in URL paths (FR-003, SC-005)                                                  | All three endpoints are `POST` with the identifier in the body; static probe greps the routing table                                                     |
| Care-team-membership gating (FR-004, SC-010)                                                 | Indexed SQL probe in `permissions.can_access` on every clinical-endpoint request; fail-closed on missing membership                                       |
| Byte-equivalent unauthorised response (FR-006, SC-003)                                       | Single `responses.not_found_response()` helper used at every refused code path; pinned `(status, content_type, content_length, body)`                    |
| Fixed response field ordering for clinician reads (FR-007, FR-019, FR-020)                   | `clinical_safety.build_patient_record()` is the sole successful-read response builder; the field order is the dict-literal order                          |
| Notes append-only (FR-011, SC-007)                                                            | No PATCH/DELETE endpoints; no UPDATE/DELETE SQL on `clinical_notes`; schema CHECK on `author_role` excludes administrators                                |
| Always-on audit on clinical endpoints (FR-012, SC-001, SC-002)                                | Audit INSERT for every code path that reaches the service layer, regardless of outcome                                                                   |
| Audit immutability + 7-year retention (FR-014, FR-016, SC-008)                                | No UPDATE/DELETE SQL on `audit_entries`; static + runtime probes; operational retention scheduling out of scope                                            |
| 2-second audit SLA (FR-015, SC-009)                                                          | SQLite connection `timeout=1.8`; `OperationalError` → `503 service_unavailable` with rollback                                                            |
| Administrator content-blindness (FR-005, FR-018, SC-006)                                      | `admin_response.py` is the sole administrator-response code path; static probe greps for forbidden clinical-table accesses; runtime probe walks responses for forbidden keys |

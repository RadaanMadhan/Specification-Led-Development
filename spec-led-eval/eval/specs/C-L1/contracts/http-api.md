# HTTP API Contract: Clinician Access to Patient Medical Records (v1)

**Branch**: `009-clinician-record-access` | **Date**: 2026-05-17

The service exposes exactly two endpoints. Any other path returns the byte-equivalent `not_found` response. All requests and responses use `application/json; charset=utf-8`.

## Authentication (all endpoints)

```
Authorization: Bearer <token>
```

Resolution in `server.py` **before** any handler runs (FR-001):

1. Header missing or malformed → `401 unauthenticated`.
2. Token unknown / expired → `401 unauthenticated`.

```json
{ "error": "unauthenticated", "message": "Authentication required." }
```

When authentication succeeds, the handler runs with `(clinician_id, clinician_display_name, clinician_role)` in scope.

> **Note**: Authentication failures do NOT produce audit entries (FR-008's audit obligation applies once a patient_id has been dereferenced; an unauthenticated request never reaches that point). Authentication-layer audit lives in the host product's identity-provider log.

## Byte-equivalent not-found response

A single canonical not-found response is used for every "you cannot see this" case on both endpoints:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8
Content-Length: 48

{"error":"not_found","message":"No such record."}
```

This response is returned for:

- `patient_id` does not exist (clinician endpoint).
- `patient_id` exists but the calling clinician is not on the care team (clinician endpoint).
- Caller is not the `audit_officer` role attempting `/audit/search`.
- `audit_officer` requesting `/audit/search` for a `patient_id` that has no audit entries (and may or may not exist as a patient).

Body bytes, `Content-Type`, and `Content-Length` are identical across all cases (FR-007, SC-003). `Date`-style transport headers are out of scope of byte-equivalence.

A single helper `responses.not_found_response()` returns the canonical bytes; static + runtime tests in `test_byte_equivalence.py` assert every unauthorised-access code path uses it.

## Common error envelope

| HTTP status | error code              | When                                                                                              |
|-------------|-------------------------|---------------------------------------------------------------------------------------------------|
| 400         | `validation_error`      | Body malformed; required field missing; `patient_id` field absent or non-string.                  |
| 401         | `unauthenticated`       | Missing / invalid bearer token. Returned before any handler logic. No audit entry.                 |
| 404         | `not_found`             | See "Byte-equivalent not-found response" above.                                                    |
| 503         | `service_unavailable`   | Audit write would exceed the 2-second SLA (FR-013). Access was refused; no record content returned; **one audit entry per attempt is still attempted, but if it also fails, the response is 503 and no entry is written** (this is the only case where SC-001's "100% accesses audited" rule is relaxed, and SC-007 explicitly accepts ≤1% of attempts hitting this path). |
| 500         | `internal_error`        | Unexpected failure.                                                                                |

---

## `POST /records/lookup` — clinician looks up a patient by identifier

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
| `patient_id` | string | yes      | Opaque (NHS number / MRN / equivalent). The format is not validated; the system treats it as a string. |

The patient_id is **never** placed in the URL path (FR-004). Web-server access logs configured to capture POST bodies should be configured to redact this field; this feature does not control web-server logging.

### Authorisation

The caller MUST hold a clinical role (`doctor`, `nurse`, `pharmacist`, or `clinical_admin`) **and** be a member of the requested patient's care team for an active episode of care (FR-006). The `audit_officer` role cannot use this endpoint — it accesses records via the audit-search endpoint only.

Any other authenticated caller (clinical role but no care-team membership, or `audit_officer` role) → byte-equivalent `404 not_found`.

### Behaviour

In one transaction:

1. Authenticate. Resolve `(clinician_id, clinician_role)`. If 401, return; no audit.
2. Validate body. If `patient_id` is missing → `400 validation_error` with `field_errors: [{"field":"patient_id","message":"Required."}]`. No audit (no patient_id to log).
3. Look up the patient. Decide outcome:
   - Patient exists AND care-team-membership exists → `outcome = "permitted"`, `authorisation_basis = "care_team_member"`.
   - Patient exists, no care-team-membership → `outcome = "denied"`, `authorisation_basis = "not_care_team_member"`.
   - Patient does not exist → `outcome = "not_found_or_denied"`, `authorisation_basis = "patient_not_found"`.
4. INSERT audit entry with `access_type = "read"`, `outcome`, `authorisation_basis`, `clinician_id`, snapshotted `clinician_display_name` and `clinician_role`, `patient_id` as presented, `occurred_at = now()`.
5. COMMIT.
6. If `outcome == "permitted"`, return the patient summary (see below). Otherwise return the byte-equivalent `not_found_response()`.
7. If the COMMIT exceeds 1.8 s → roll back, return `503 service_unavailable`. No audit entry is written; no record content is returned.

### Responses

**200 OK — patient summary** (only for `outcome = "permitted"`):

The JSON object key order is **fixed** and tested:

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
  ]
}
```

Fields appear in this exact order (FR-014, FR-015):

1. `patient_id`, `date_of_birth`, `name` — patient verification block.
2. `allergies`, `key_warnings` — clinical-safety block.
3. `current_medications` — current-state block.
4. `recent_encounters` — chronological block, most-recent first.

A test in `test_clinical_safety.py` walks `list(response.keys())` and asserts the first five keys are exactly `["patient_id", "date_of_birth", "name", "allergies", "key_warnings"]`. The host application's UI is expected to render these prominently.

`allergies` and `key_warnings` may be empty arrays if the patient has none recorded; they are still present in the response shape.

**404 `not_found` (byte-equivalent)** — patient does not exist, OR caller is not on the care team, OR caller's role is not clinical. Body bytes per "Byte-equivalent not-found response" above.

**400 `validation_error`** — `patient_id` missing or non-string in the request body.

**503 `service_unavailable`** — audit write exceeded the 2-second budget.

---

## `POST /audit/search` — IG officer lists audit entries for a patient

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

The caller MUST hold the `audit_officer` role. Any other authenticated caller (any clinical role, or unknown role) → byte-equivalent `404 not_found` (FR-011, SC-011 — the existence of the IG endpoint does not leak to clinical roles).

### Behaviour

In one transaction:

1. Authenticate. Resolve role.
2. If role ≠ `audit_officer` → return byte-equivalent `not_found_response()`. **No audit entry is written for this case** — the IG endpoint is not in the patient-access audit's scope (FR-008 audits patient-record *access* attempts; this endpoint audits the auditor, which is a separate operational-log concern out of scope for v1).
3. Validate body. If `patient_id` is missing → `400 validation_error`.
4. SELECT every `audit_entries` row with the given `patient_id` ordered by `(occurred_at ASC, id ASC)`.
5. If the result set is empty → return byte-equivalent `not_found_response()` (the IG caller cannot distinguish "patient with no recorded accesses" from "patient that does not exist as a patient", which is acceptable in v1 — both are uninteresting for audit).
6. Return the audit list.

### Responses

**200 OK — audit list**:

```json
{
  "patient_id": "<opaque-patient-id>",
  "events": [
    {
      "clinician_id": "<opaque-clinician-id>",
      "clinician_display_name": "Dr Alice Carter",
      "clinician_role": "doctor",
      "occurred_at": "2026-05-17T10:14:33.221Z",
      "access_type": "read",
      "outcome": "permitted",
      "authorisation_basis": "care_team_member"
    },
    {
      "clinician_id": "<other-clinician-id>",
      "clinician_display_name": "Dr Bob Smith",
      "clinician_role": "doctor",
      "occurred_at": "2026-05-17T12:01:00.000Z",
      "access_type": "read",
      "outcome": "denied",
      "authorisation_basis": "not_care_team_member"
    }
  ]
}
```

Events are in chronological order. `clinician_display_name` and `clinician_role` are snapshots taken at the time of each access (FR-009 — renames in the host product do not retroactively change historical audit entries).

**404 `not_found` (byte-equivalent)** — caller is not `audit_officer`, OR `patient_id` has no audit entries.

**400 `validation_error`** — `patient_id` missing or non-string.

## Invariants the contract is built to expose

| Invariant                                                                                  | Surfaced by                                                                                                                                              |
|--------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| Authentication required; no audit for failed auth (FR-001, SC-004)                          | `401 unauthenticated` from the boundary before any handler runs; no audit entry generated for the auth-failure path                                       |
| Patient identifiers never in URL paths (FR-004, SC-005)                                     | Both endpoints are `POST` with the identifier in the body; static probe `test_no_url_pii.py` greps the routing table                                      |
| Care-team-membership gating (FR-006, SC-010)                                                 | Indexed SQL probe in `permissions.can_access` runs on every request; fail-closed on missing membership                                                    |
| Byte-equivalent denied / not-found (FR-007, SC-003)                                          | Single `responses.not_found_response()` helper used at every unauthorised-access code path; pinned `(status, content_type, content_length, body)`         |
| Always-on audit on the clinical endpoint (FR-008, SC-001, SC-002)                            | Audit INSERT happens for every code path that reaches `service.lookup_patient` regardless of outcome                                                      |
| Audit immutability (FR-010, SC-006)                                                          | No UPDATE/DELETE SQL on `audit_entries`; static + runtime probes                                                                                          |
| IG role can see the audit; the endpoint's existence is hidden from clinical roles (FR-011, SC-011) | `POST /audit/search` returns byte-equivalent 404 for non-IG callers                                                                                   |
| 2-second audit SLA (FR-013, SC-007)                                                          | SQLite `timeout=1.8`; `OperationalError` → `503 service_unavailable`; no audit entry written when the SLA is breached                                     |
| Allergies / warnings / id / DoB at top of every response (FR-014, FR-015, SC-008)            | Fixed JSON key order produced by `clinical_safety.build_patient_summary`; `test_clinical_safety.py` walks response key order and asserts the prefix       |

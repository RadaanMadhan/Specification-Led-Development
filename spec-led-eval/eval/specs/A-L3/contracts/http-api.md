# HTTP API Contract: FCA-Regulated Loan Application

**Branch**: `005-fca-loan-applications` | **Date**: 2026-05-17

The service exposes exactly the four endpoints from the spec. Any other path returns the **byte-equivalent not-found response** (see below). All requests and responses use `application/json; charset=utf-8`. Application identifiers in URLs are opaque UUID-shaped strings.

## Authentication (all endpoints) — OAuth 2.0 bearer

Every request MUST include:

```
Authorization: Bearer <token>
```

Resolution order, applied in `server.py` **before** any handler runs (FR-001, SC-010):

1. Header missing or malformed → `401 unauthenticated` (no business logic, no audit entry).
2. Token introspection (`TokenIntrospector.introspect(token)`) returns `None` (unknown / expired) → `401 unauthenticated`.
3. Token resolves to an `AuthenticatedCaller` carrying `user_id` and `roles: frozenset[Role]`. The handler proceeds with `(user, roles)` in scope.

```json
{ "error": "unauthenticated", "message": "Authentication required." }
```

(Same body for both "missing" and "invalid" — we do not distinguish at the wire, matching the pattern of not leaking information about server state at the auth boundary.)

## Byte-equivalent not-found response (FR-020, FR-021, FR-022)

A single canonical not-found response is used for **every** unauthorised-read case on `GET /applications/{id}` and `GET /applications/{id}/audit`:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8
Content-Length: 53

{"error":"not_found","message":"No such application."}
```

This response is returned for:

- `{id}` does not exist.
- `{id}` exists but the caller is an `applicant` who is not the application's applicant.
- `{id}` exists but the caller is an `officer` who is not the application's assigned officer (and is not an auditor).
- `GET /applications/{id}/audit` where the caller is not an `auditor`.

The bytes of this response are identical across all four cases. Headers not under application control (`Date`, transport-level headers) are out of scope for the byte-equivalence requirement.

The not-found response is produced by a single helper `responses.not_found_response()` (see research.md). A handful of in-app self-tests assert that every unauthorised-read code path goes through this helper.

## Common error envelope (non-byte-equivalent cases)

For errors where information disclosure is not a concern (the caller is acting authenticated and the failure mode itself is not sensitive — validation, conflict, server error), the envelope is:

```json
{ "error": "<code>", "message": "<human-readable description>" }
```

| HTTP status | error code                  | When                                                                                                                |
|-------------|-----------------------------|---------------------------------------------------------------------------------------------------------------------|
| 400         | `validation_error`          | Body malformed; required field missing; amount/purpose out of allowed values; empty/oversize reason. `field_errors` array carries per-field detail (see FR-006 / FR-014). |
| 401         | `unauthenticated`           | Missing / invalid OAuth bearer token. Returned before any handler logic. (FR-001, SC-010)                            |
| 403         | `permission_denied`         | Authenticated but role rules forbid this **write** action. (Reads use the byte-equivalent not-found response above.) |
| 403         | `not_assigned_officer`      | Officer attempted to `PATCH` an application not assigned to them (FR-012).                                          |
| 403         | `self_decision_forbidden`   | Officer attempted to `PATCH` an application where they are the applicant (FR-013).                                  |
| 404         | `not_found`                 | See "Byte-equivalent not-found response" above for the unauthorised-read case. For non-`GET` endpoints (`PATCH /applications/{id}/status` on a fabricated id) the *same* byte-equivalent response is used to avoid leaking existence to writers. |
| 409         | `has_in_flight_application` | Applicant attempted to submit while one is in flight (FR-008).                                                       |
| 409         | `invalid_transition`        | Officer `PATCH`ed a target status not allowed from the current status (FR-009).                                      |
| 409         | `already_decided`           | Officer `PATCH`ed an application that is already `approved` or `rejected` (FR-015).                                 |
| 503         | `audit_unavailable`         | Audit write would exceed the 2-second SLA (FR-017); the state transition was rolled back and no audit entry was written. |
| 500         | `internal_error`            | Unexpected failure. Body still carries the envelope.                                                                |

### Field-error array (validation errors)

```json
{
  "error": "validation_error",
  "message": "One or more fields are invalid.",
  "field_errors": [
    { "field": "amount_minor", "message": "Must be between 100000 and 2500000 (£1,000–£25,000)." },
    { "field": "purpose", "message": "Must be one of home_improvement, debt_consolidation, vehicle, education, medical, wedding, holiday, business, other." }
  ]
}
```

Per FR-006, FR-014: validation reports **every** offending field at once, not fail-fast.

## Permission matrix

| Action                                      | `{applicant}`            | `{officer}`                                                              | `{auditor}`         | `{applicant,officer}`     | `{applicant,auditor}` |
|---------------------------------------------|--------------------------|--------------------------------------------------------------------------|---------------------|---------------------------|-----------------------|
| `POST /applications`                        | ✅                        | ❌ → 403 `permission_denied`                                              | ❌ → 403             | ✅ (qua applicant)        | ✅ (qua applicant)    |
| `GET /applications/{id}` — caller is applicant | ✅ if owner; not-found otherwise | ❌ unless also assigned officer; in either case the response is not-found if neither | ❌ → not-found       | as applicant + officer    | as applicant + auditor (auditor wins) |
| `GET /applications/{id}` — caller is auditor  | n/a                     | n/a                                                                       | ✅ for any id        | n/a                       | ✅ for any id (auditor)|
| `PATCH /applications/{id}/status`           | ❌ → 403 `permission_denied` | ✅ if assigned officer AND not the applicant; otherwise 403 (specific subcode below) | ❌ → 403             | as officer (FR-013 still bites) | ❌ → 403 (auditor cannot write) |
| `GET /applications/{id}/audit`              | ❌ → not-found            | ❌ → not-found                                                            | ✅ for any id        | ❌ → not-found            | ✅ (auditor)          |

Read paths refused at the role layer use the **byte-equivalent not-found** response (FR-020/FR-021/FR-023). Write paths refused at the role layer use `403 permission_denied` — writers are not leak-sensitive in the same way as readers (a writer trying to mutate someone else's resource is already misbehaving and the existence leak does not advance any practical attack beyond what they could learn elsewhere).

---

## `POST /applications` — submit a loan application (applicant)

### Request

```http
POST /applications HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "amount_minor": 750000,
  "purpose": "home_improvement"
}
```

| Field          | Type   | Required | Notes                                                                          |
|----------------|--------|----------|--------------------------------------------------------------------------------|
| `amount_minor` | int    | yes      | Pence. 100000 ≤ value ≤ 2500000 (£1,000–£25,000).                              |
| `purpose`      | string | yes      | One of: `home_improvement`, `debt_consolidation`, `vehicle`, `education`, `medical`, `wedding`, `holiday`, `business`, `other`. |

### Authorisation

`roles` MUST contain `applicant`. Other role sets → `403 permission_denied`.

### Behaviour

In one atomic DB transaction:

1. Validate the body. On failure → `400 validation_error` (no application created, no audit entry).
2. Check the applicant has no in-flight application. If they do → `409 has_in_flight_application` (no audit entry).
3. Compute the eligible officer pool: `users where 'officer' in roles AND id != caller.user_id`, sorted by `id`.
4. If pool is empty: insert application with `assigned_officer_id = NULL`; insert initial audit entry with `actor_id="system"`, `actor_role="system"`, `reason="Submitted; no eligible officer available — assignment deferred"`.
5. Else: pick `officers[next_position % len(officers)]`; bump and persist `next_position`; insert application with `assigned_officer_id = chosen.id`; insert initial audit entry with `actor_id=caller.user_id`, `actor_role="applicant"`, `reason="Application submitted"`.
6. `COMMIT`. If the COMMIT exceeds 1.8 s (FR-017) → `503 audit_unavailable`, transaction rolled back, no application created, no audit entry.

### Responses

**201 Created** — application accepted; status is `pending`; one initial audit entry persisted within 2 s.

```json
{
  "id": "f6b3c0e1-…",
  "applicant_id": "applicant-uuid",
  "amount_minor": 750000,
  "purpose": "home_improvement",
  "status": "pending",
  "assigned_officer_id": "officer-uuid",
  "submitted_at": "2026-05-17T10:14:33.221Z"
}
```

For an `{applicant}`-only caller, `assigned_officer_id` is **omitted** (FR-021 — officer identity not exposed to applicants). For an `{applicant,officer}` caller (a bank-staff user submitting as a customer), `assigned_officer_id` is still omitted on this response — the applicant view dominates the applicant's own application response. (Auditors don't `POST`.)

**400 `validation_error`** — see envelope.

**409 `has_in_flight_application`**:

```json
{
  "error": "has_in_flight_application",
  "message": "You already have an application under review.",
  "existing_application_id": "f6b3c0e1-…",
  "existing_status": "pending"
}
```

The `existing_application_id` and `existing_status` refer **only** to the requesting applicant's own application; never to anyone else's (FR-022).

**503 `audit_unavailable`** — see envelope.

---

## `GET /applications/{id}` — view an application

### Request

```http
GET /applications/f6b3c0e1-… HTTP/1.1
Authorization: Bearer <token>
```

### Authorisation and response shape

| Caller's effective access path                                                | Response          | Notes |
|-------------------------------------------------------------------------------|-------------------|-------|
| `applicant` + caller is the application's applicant                            | `200 OK`          | Officer-identifier fields scrubbed (FR-021).                                  |
| `auditor`                                                                     | `200 OK`          | Full record including `assigned_officer_id` and (if decided) decision fields. |
| `officer` + caller is the application's assigned officer                       | `200 OK`          | Full record including own identity as `assigned_officer_id`.                  |
| Any other authenticated caller (including different applicant, different officer) | **byte-equivalent not-found** | FR-020/021. |
| Unauthenticated                                                                | `401 unauthenticated` | Returned before any handler logic.                                          |

### 200 OK body — auditor or assigned officer

```json
{
  "id": "f6b3c0e1-…",
  "applicant_id": "applicant-uuid",
  "amount_minor": 750000,
  "purpose": "home_improvement",
  "status": "approved",
  "assigned_officer_id": "officer-uuid",
  "submitted_at": "2026-05-17T10:14:33.221Z",
  "decision_status": "approved",
  "decided_at": "2026-05-19T11:02:00.000Z",
  "decision_reason": "Income covers requested amount comfortably."
}
```

### 200 OK body — applicant viewing own application

```json
{
  "id": "f6b3c0e1-…",
  "amount_minor": 750000,
  "purpose": "home_improvement",
  "status": "approved",
  "submitted_at": "2026-05-17T10:14:33.221Z",
  "decision_status": "approved",
  "decided_at": "2026-05-19T11:02:00.000Z",
  "decision_reason": "Income covers requested amount comfortably."
}
```

`applicant_id` is omitted (the applicant knows who they are); `assigned_officer_id` is omitted (FR-021).

---

## `PATCH /applications/{id}/status` — transition status (assigned officer)

### Request

```http
PATCH /applications/f6b3c0e1-…/status HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "status": "approved",
  "reason": "Income covers requested amount comfortably."
}
```

| Field    | Type   | Required | Notes                                                                              |
|----------|--------|----------|------------------------------------------------------------------------------------|
| `status` | string | yes      | Target status. One of `under_review`, `approved`, `rejected`. (Cannot target `pending` — that is the initial state only.) |
| `reason` | string | yes      | Non-empty, ≤1000 chars (FR-014).                                                   |

### Authorisation

`roles` MUST contain `officer`. Other role sets → `403 permission_denied`. Even among officers, the caller MUST be the application's assigned officer AND NOT the application's applicant (FR-012, FR-013).

### Behaviour

The handler dispatches to `service.transition_application(id, target_status, reason, caller)`:

1. Validate `target_status` and `reason`. On failure → `400 validation_error`.
2. Map `target_status` to its source status: `under_review` ⇐ `pending`; `approved`/`rejected` ⇐ `under_review`.
3. Run the conditional `UPDATE loan_applications SET status=? WHERE id=? AND status=<source> AND assigned_officer_id=? AND applicant_id!=?`.
4. On rowcount=1: insert audit entry in the same transaction with `previous_status=<source>`, `new_status=<target>`, `actor_role='officer'`, computed `prev_hash` and `entry_hash` for the chain. Commit. Return 200 with the full application body (auditor/officer shape).
5. On rowcount=0: SELECT the application to discriminate:
   - row not found → byte-equivalent **not-found** response.
   - `applicant_id == caller.user_id` → `403 self_decision_forbidden`.
   - `assigned_officer_id != caller.user_id` → `403 not_assigned_officer`.
   - `status` not the expected source for `target_status`, and `status IN ('pending','under_review')` → `409 invalid_transition`.
   - `status IN ('approved','rejected')` → `409 already_decided`.
6. On COMMIT exceeding 1.8 s → `503 audit_unavailable`, transaction rolled back, application state and audit log unchanged.

### Responses

**200 OK** — transition successful. Body is the full application in officer/auditor shape (see `GET 200 OK`).

**400 `validation_error`** — bad `status` value, missing or empty `reason`, or `target_status == "pending"`.

**403 `permission_denied`** — caller's role set does not include `officer`.

**403 `not_assigned_officer`**:

```json
{
  "error": "not_assigned_officer",
  "message": "Only the assigned officer may change this application's status.",
  "assigned_officer_id": "officer-uuid"
}
```

**403 `self_decision_forbidden`**:

```json
{
  "error": "self_decision_forbidden",
  "message": "An officer cannot decide their own application."
}
```

**404 not-found (byte-equivalent)** — non-existent `{id}`. Same response as for an unauthorised read; we use the byte-equivalent shape on writes too to avoid leaking existence.

**409 `invalid_transition`**:

```json
{
  "error": "invalid_transition",
  "message": "This transition is not allowed from the current status.",
  "current_status": "pending",
  "requested_status": "approved"
}
```

**409 `already_decided`**:

```json
{
  "error": "already_decided",
  "message": "This application has already been decided.",
  "current_status": "approved",
  "decided_at": "2026-05-19T11:02:00.000Z"
}
```

**503 `audit_unavailable`** — see envelope.

---

## `GET /applications/{id}/audit` — view audit trail (auditor)

### Request

```http
GET /applications/f6b3c0e1-…/audit HTTP/1.1
Authorization: Bearer <token>
```

### Authorisation

`roles` MUST contain `auditor`. Any other role set (including `officer`, `applicant`, `applicant+officer`) → **byte-equivalent not-found** (FR-023, so the audit endpoint does not leak the existence of applications to non-auditors).

### Responses

**200 OK** — audit entries in chronological order, with chain verification:

```json
{
  "application_id": "f6b3c0e1-…",
  "tamper_status": "intact",
  "events": [
    {
      "actor_id": "applicant-uuid",
      "actor_role": "applicant",
      "occurred_at": "2026-05-17T10:14:33.221Z",
      "previous_status": null,
      "new_status": "pending",
      "reason": "Application submitted",
      "prev_hash": "0000000000000000000000000000000000000000000000000000000000000000",
      "entry_hash": "ab12…cd34"
    },
    {
      "actor_id": "officer-uuid",
      "actor_role": "officer",
      "occurred_at": "2026-05-18T08:30:00.000Z",
      "previous_status": "pending",
      "new_status": "under_review",
      "reason": "Picked up for review",
      "prev_hash": "ab12…cd34",
      "entry_hash": "ef56…78ab"
    },
    {
      "actor_id": "officer-uuid",
      "actor_role": "officer",
      "occurred_at": "2026-05-19T11:02:00.000Z",
      "previous_status": "under_review",
      "new_status": "approved",
      "reason": "Income covers requested amount comfortably.",
      "prev_hash": "ef56…78ab",
      "entry_hash": "9012…3456"
    }
  ]
}
```

`tamper_status` is `"intact"` when the chain verifies and `"tampered"` when any entry's stored `entry_hash` does not match the recomputed value from the canonical encoding (FR-018). On `"tampered"`, the body is still returned (so the auditor can see the suspect entries); operational alerting is the auditor's job.

**404 not-found (byte-equivalent)** — non-existent `{id}`, OR caller is not an auditor.

## Invariants the contract is built to expose

| Invariant                                                                                | Surfaced by                                                                                                                                            |
|------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
| OAuth bearer required; 401 before business logic (FR-001, SC-010)                         | `server.py` boundary check; no handler runs on an unauthenticated request                                                                              |
| Allowed amount range, fixed purpose list (FR-007)                                        | `400 validation_error` from `POST /applications` with `field_errors`                                                                                   |
| One in-flight per applicant (FR-008)                                                     | `409 has_in_flight_application` from `POST /applications`                                                                                              |
| Auto-assignment excludes applicant (FR-010, FR-011)                                      | `assigned_officer_id != applicant_id` invariant in the 201 response and across the data model; system-actor initial audit entry on "no eligible officer" |
| Only assigned officer can `PATCH` (FR-012, SC-005)                                       | `403 not_assigned_officer` from the discriminator after rowcount=0 on the conditional UPDATE                                                            |
| No self-approval (FR-013, SC-006)                                                        | `403 self_decision_forbidden` from the discriminator; permission predicate `applicant_id != caller.user_id` in `permissions.py`; SQL filter `applicant_id != ?` in `store.py`              |
| Audit within 2 s (FR-017, SC-002)                                                        | `503 audit_unavailable` when the COMMIT would exceed the connection timeout; state and audit unchanged                                                  |
| Audit immutable, tamper-detectable (FR-018, SC-009)                                      | Chained-hash `prev_hash` / `entry_hash` columns in every audit entry; `tamper_status` field in `GET /applications/{id}/audit` 200 OK                    |
| Byte-equivalent unauthorised response (FR-020, FR-021, FR-022, SC-004)                   | Single `responses.not_found_response()` helper returns identical `(status, body, content-length)` for every unauthorised read; static probe ensures all four unauthorised-read code paths use it |
| Auditor cannot write (FR-005, FR-023, SC-007)                                            | Permission table rejects every write action for the `{auditor}`-only role set                                                                          |

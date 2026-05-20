# HTTP API Contract: Loan Application with Role-Based Workflow and Audit Trail

**Branch**: `004-loan-application-rbac` | **Date**: 2026-05-17

The service exposes exactly the six endpoints below. Any other path returns `404 not_found`. All requests and responses use `application/json; charset=utf-8`. All reference values in URLs are case-sensitive.

## Authentication (all endpoints)

Every request MUST include:

```
Authorization: Bearer <token>
```

Resolution order, applied **before** any handler logic:

1. Header missing or malformed → `401 unauthenticated` with body `{"error": "unauthenticated", "message": "Authorization header missing or malformed."}`.
2. Token unknown → `401 unauthenticated` with body `{"error": "unauthenticated", "message": "Token is not recognised."}`.
3. Token resolves to a `User` with exactly one `Role` ∈ {`customer`, `loan_officer`, `compliance_reviewer`}. The handler proceeds with `(user, role)` in scope.

## Common error envelope

```json
{ "error": "<code>", "message": "<human-readable description>" }
```

| HTTP status | error code                   | When                                                                                                                                |
|-------------|------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| 400         | `validation_error`           | Body malformed; required field missing; amount/purpose out of allowed range; empty decision reason. `field_errors` array carries field-level detail. |
| 401         | `unauthenticated`            | Missing / invalid `Authorization`. Returned before any handler logic.                                                                |
| 403         | `permission_denied`          | Authenticated, but role rules forbid this action. Returned by `permissions.is_allowed` *before* business logic runs.                |
| 403         | `not_assigned_officer`       | Loan officer attempted to decide an application that is not currently assigned to them (FR-013). Distinguished from the generic `permission_denied` because the role is allowed in principle. |
| 404         | `not_found`                  | No application exists at the given reference, **or** caller is a customer asking about an application they don't own (FR-020 — no existence leak). |
| 409         | `has_in_flight_application`  | Customer attempted to submit while they already have one in `Submitted` or `Under Review` (FR-008).                                  |
| 409         | `already_claimed`            | Loan officer attempted to claim an application that is no longer at `Submitted` (FR-012). Body names the current assigned officer (if any) and the current status. |
| 409         | `already_decided`            | Decision attempt on an application no longer at `Under Review` (FR-016).                                                            |
| 500         | `internal_error`             | Unexpected failure. Body still carries the envelope.                                                                                |

### Field-error array (validation errors)

```json
{
  "error": "validation_error",
  "message": "One or more fields are invalid.",
  "field_errors": [
    { "field": "requested_amount_minor", "message": "Must be between 100000 and 2500000 (£1,000–£25,000)." },
    { "field": "purpose", "message": "Must be a non-empty string of at most 500 characters." }
  ]
}
```

Per FR-006: validation reports **every** offending field at once, not fail-fast.

## Permission matrix

| Action                                              | `customer`              | `loan_officer`                                          | `compliance_reviewer` |
|-----------------------------------------------------|-------------------------|---------------------------------------------------------|-----------------------|
| `POST /applications`                                | ✅                       | ❌ → 403 `permission_denied`                             | ❌ → 403               |
| `GET /applications`                                 | ✅ (own only)            | ✅ (unassigned queue by default; status filter allowed) | ✅ (all; filters allowed) |
| `GET /applications/{reference}`                     | ✅ (own only; 404 otherwise) | ✅ (any)                                            | ✅ (any)               |
| `POST /applications/{reference}/claim`              | ❌ → 403                 | ✅                                                       | ❌ → 403               |
| `POST /applications/{reference}/decision`           | ❌ → 403                 | ✅ if `assigned_officer_id == caller.id`, else 403 `not_assigned_officer` | ❌ → 403 |
| `GET /applications/{reference}/audit`               | ❌ → 403                 | ✅                                                       | ✅                     |

## Response scrubbing (FR-021)

Customer responses **never** include officer-identifier keys. The scrub is applied at serialisation time by `handlers.scrub_for_role(payload, role)`:

- For `role == 'customer'`: remove `assigned_officer_id`, `assigned_officer_name`, `decided_by_user_id`, `decided_by_username`, and any `actor_user_id` / `actor_username` field on events where the actor is not the customer themselves.
- For `role == 'loan_officer'` or `'compliance_reviewer'`: no scrubbing.

---

## `POST /applications` — submit a loan application (customer)

### Request

```http
POST /applications HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "requested_amount_minor": 750000,
  "purpose": "Kitchen renovation"
}
```

| Field                    | Type   | Required | Notes                                                                          |
|--------------------------|--------|----------|--------------------------------------------------------------------------------|
| `requested_amount_minor` | int    | yes      | Pence. 100000 ≤ value ≤ 2500000 (£1,000–£25,000).                              |
| `purpose`                | string | yes      | Non-empty, ≤500 characters.                                                    |

### Authorisation

Customer only. Other roles → `403 permission_denied`.

### Responses

**201 Created** — status is `Submitted`; one `(none) → Submitted` audit entry written.

```json
{
  "reference": "LA-2026-000042",
  "status": "Submitted",
  "submitted_at": "2026-05-17T10:14:33.221Z",
  "requested_amount_minor": 750000,
  "purpose": "Kitchen renovation",
  "expected_review_within_business_days": 2
}
```

**400 `validation_error`** — see envelope.

**409 `has_in_flight_application`** — customer already has one in `Submitted` or `Under Review`:

```json
{
  "error": "has_in_flight_application",
  "message": "You already have an application under review.",
  "existing_reference": "LA-2026-000041",
  "existing_status": "Under Review"
}
```

---

## `GET /applications` — list applications

### Request

```http
GET /applications?status=Submitted HTTP/1.1
Authorization: Bearer <token>
```

| Query param | Type   | Required | Notes                                                                                                |
|-------------|--------|----------|------------------------------------------------------------------------------------------------------|
| `status`    | string | no       | Filter on one of `Submitted`, `Under Review`, `Approved`, `Rejected`. Allowed for all roles, but applied within the role's visibility scope. |

### Per-role scoping

| Role                  | What is returned                                                                                                              | Default order                                  |
|-----------------------|-------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------|
| `customer`            | Applications where `customer_id == caller.id`. `status` filter applied within own applications.                              | `submitted_at DESC` (most recent first)        |
| `loan_officer`        | If `status` omitted: applications at `status='Submitted'` (the unassigned queue, FR-010). If `status` given: that status set. | `submitted_at ASC` (oldest first, FR-010)      |
| `compliance_reviewer` | If `status` omitted: every application. If `status` given: that status set.                                                  | `submitted_at DESC` (most recent first)        |

### Responses

**200 OK** — list response:

```json
{
  "applications": [
    {
      "reference": "LA-2026-000041",
      "customer_id": "customer-uuid",
      "customer_name": "Alice Customer",
      "requested_amount_minor": 600000,
      "purpose": "Wedding",
      "status": "Under Review",
      "assigned_officer_id": "officer-uuid",
      "assigned_officer_name": "Officer Brenda",
      "submitted_at": "2026-05-15T09:00:00Z",
      "decided_at": null,
      "decision_type": null
    }
  ]
}
```

For `customer` responses, `assigned_officer_id`, `assigned_officer_name`, and any officer-identifier fields are scrubbed (FR-021).

---

## `GET /applications/{reference}` — view a single application

### Authorisation

| Role                  | Behaviour                                                                                                            |
|-----------------------|----------------------------------------------------------------------------------------------------------------------|
| `customer`            | If the application is theirs → 200. Otherwise → `404 not_found` (no existence leak; FR-020).                          |
| `loan_officer`        | Any existing reference → 200.                                                                                         |
| `compliance_reviewer` | Any existing reference → 200.                                                                                         |

### Responses

**200 OK** — full application body:

```json
{
  "reference": "LA-2026-000042",
  "status": "Approved",
  "submitted_at": "2026-05-17T10:14:33.221Z",
  "requested_amount_minor": 750000,
  "purpose": "Kitchen renovation",
  "customer_id": "customer-uuid",
  "customer_name": "Alice Customer",
  "assigned_officer_id": "officer-uuid",
  "assigned_officer_name": "Officer Brenda",
  "decided_at": "2026-05-19T11:02:00Z",
  "decision_type": "Approved",
  "decision_reason": "Income covers requested term comfortably.",
  "decided_by_user_id": "officer-uuid",
  "decided_by_username": "officer_brenda"
}
```

For applications still pre-decision, `decided_at`, `decision_type`, `decision_reason`, `decided_by_user_id`, `decided_by_username` are all `null`; `assigned_officer_*` is `null` while status is `Submitted`. For `customer` responses, officer-identifier fields are scrubbed (FR-021).

**404 `not_found`** — non-existent reference, or customer asking about an application that isn't theirs.

---

## `POST /applications/{reference}/claim` — claim an application (loan officer)

### Request

```http
POST /applications/LA-2026-000042/claim HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

Body is empty (the application is identified by URL; the claimer by `Authorization`).

### Authorisation

Loan officer only. Other roles → `403 permission_denied`.

### Responses

**200 OK** — claim succeeded; status is now `Under Review`; one `Submitted → Under Review` audit entry written:

```json
{
  "reference": "LA-2026-000042",
  "status": "Under Review",
  "assigned_officer_id": "officer-uuid",
  "assigned_officer_name": "Officer Brenda",
  "claimed_at": "2026-05-18T08:30:00Z"
}
```

**409 `already_claimed`** — application is no longer at `Submitted` (FR-012). Body names the current state so the losing claimer knows whom to talk to:

```json
{
  "error": "already_claimed",
  "message": "This application has already been claimed.",
  "current_status": "Under Review",
  "assigned_officer_id": "officer-uuid",
  "assigned_officer_name": "Officer Brenda"
}
```

If `current_status` is `Approved` or `Rejected`, `assigned_officer_*` still refers to the officer who decided it.

**404 `not_found`** — non-existent reference.

---

## `POST /applications/{reference}/decision` — record a decision (assigned loan officer)

### Request

```http
POST /applications/LA-2026-000042/decision HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "decision_type": "Approved",
  "reason": "Income covers requested term comfortably."
}
```

| Field           | Type   | Required | Notes                                              |
|-----------------|--------|----------|----------------------------------------------------|
| `decision_type` | string | yes      | One of `Approved`, `Rejected`.                     |
| `reason`        | string | yes      | Non-empty, ≤1000 chars (FR-014).                   |

### Authorisation

Loan officer only, **and** must be the assigned officer for this application (FR-013). Two distinguishable failure modes:

- Caller is not a loan officer → `403 permission_denied` (handled by `permissions.is_allowed`, before business logic).
- Caller is a loan officer but not the assigned officer for *this* application → `403 not_assigned_officer` (handled by the conditional UPDATE returning rowcount=0, then a follow-up SELECT to discriminate from `already_decided`).

### Responses

**200 OK** — decision recorded. Body is the full application (same shape as `GET /applications/{reference}` 200 with decision fields populated).

**400 `validation_error`** — bad `decision_type` or empty `reason`.

**403 `not_assigned_officer`** — caller is a loan officer but `application.assigned_officer_id != caller.id` and `application.status == 'Under Review'`:

```json
{
  "error": "not_assigned_officer",
  "message": "Only the assigned loan officer can decide this application.",
  "assigned_officer_id": "officer-uuid",
  "assigned_officer_name": "Officer Brenda"
}
```

**404 `not_found`** — non-existent reference.

**409 `already_decided`** — application's status is `Approved` or `Rejected`:

```json
{
  "error": "already_decided",
  "message": "This application has already been decided.",
  "current_status": "Approved",
  "decided_at": "2026-05-19T11:02:00Z"
}
```

---

## `GET /applications/{reference}/audit` — view audit trail

### Authorisation

| Role                  | Allowed? |
|-----------------------|----------|
| `customer`            | ❌ → `403 permission_denied`. |
| `loan_officer`        | ✅        |
| `compliance_reviewer` | ✅        |

### Responses

**200 OK** — events in chronological order (FR-018):

```json
{
  "reference": "LA-2026-000042",
  "events": [
    {
      "previous_status": null,
      "new_status": "Submitted",
      "actor_user_id": "customer-uuid",
      "actor_username": "alice",
      "occurred_at": "2026-05-17T10:14:33.221Z"
    },
    {
      "previous_status": "Submitted",
      "new_status": "Under Review",
      "actor_user_id": "officer-uuid",
      "actor_username": "officer_brenda",
      "occurred_at": "2026-05-18T08:30:00Z"
    },
    {
      "previous_status": "Under Review",
      "new_status": "Approved",
      "actor_user_id": "officer-uuid",
      "actor_username": "officer_brenda",
      "occurred_at": "2026-05-19T11:02:00Z"
    }
  ]
}
```

**404 `not_found`** — non-existent reference.

## Invariants the contract is built to expose

| Invariant                                                                                       | Surfaced by                                                                                                                          |
|-------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| Customer cannot see another customer's application (FR-020, SC-004)                              | `GET /applications` filters by `customer_id`; `GET /applications/{ref}` returns `404 not_found`, not `403`, on non-owner access (no existence leak) |
| Customer cannot perform a non-customer action (FR-002, SC-004)                                   | `403 permission_denied` from the permission table consulted in every handler                                                          |
| Only the assigned officer can decide (FR-013, SC-005)                                            | `403 not_assigned_officer` from the conditional UPDATE failing AND status still `Under Review`                                       |
| Exactly one officer can claim an application (FR-012, SC-006)                                    | `409 already_claimed` from the conditional UPDATE filtering on `status='Submitted'`                                                  |
| Compliance reviewer cannot modify anything (FR-004 / FR-023, SC-008)                             | `permissions.is_allowed` rejects every write action for the `compliance_reviewer` role with `403 permission_denied`                  |
| Every status change has an audit entry; no audit entry exists without a status change (FR-017 / FR-019, SC-007) | Audit-entry insert lives in the same SQL transaction as the status-change UPDATE; no other write paths into `application_events`     |
| Officer identity never leaks to customer (FR-021)                                                | `scrub_for_role` strips officer-identifier keys before the customer's response is serialised                                          |

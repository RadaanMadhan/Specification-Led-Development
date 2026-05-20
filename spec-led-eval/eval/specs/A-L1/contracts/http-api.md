# HTTP API Contract: Loan Application

**Branch**: `003-loan-application` | **Date**: 2026-05-17

The service exposes exactly the five endpoints below. Any other path returns `404 not_found`. All requests and responses use `application/json; charset=utf-8`. All UUID and reference values in URLs are case-sensitive.

## Authentication (all endpoints)

Every request MUST include:

```
Authorization: Bearer <token>
```

Resolution order, applied **before** any handler logic:

1. Header missing or malformed → `401 Unauthorized` with body `{"error": "unauthenticated", "message": "Authorization header missing or malformed."}`.
2. Token unknown to the seeded `tokens` table → `401 Unauthorized` with body `{"error": "unauthenticated", "message": "Token is not recognised."}`.
3. Token resolves to a `User`, who has exactly one `Role` (`customer` or `bank_staff`). The handler proceeds with `(user, role)` in scope.

## Common error envelope

Errors use a single shape:

```json
{ "error": "<code>", "message": "<human-readable description>" }
```

`<code>` is a stable string identifier; `<message>` is for humans and is not parsed.

| HTTP status | error code                  | When                                                                                                  |
|-------------|-----------------------------|-------------------------------------------------------------------------------------------------------|
| 400         | `validation_error`          | Body malformed; required field missing; amount/term out of allowed values; numeric field non-numeric; empty decision reason. `field_errors` array (see below) carries field-level detail. |
| 401         | `unauthenticated`           | Missing / invalid `Authorization`. Returned before any handler logic.                                 |
| 403         | `permission_denied`         | Authenticated, but role / ownership rules forbid this action.                                          |
| 404         | `not_found`                 | No application exists at the given reference, **or** caller is a customer asking about an application they don't own (see FR-013 — same response shape; we do not leak existence). |
| 409         | `has_pending_application`   | Customer attempted to submit while they already have one in `Pending Review` (FR-005).                |
| 409         | `already_decided`           | Staff attempted to decide an application that is no longer in `Pending Review` (FR-011, FR-012).      |
| 500         | `internal_error`            | Unexpected failure. Body still carries the envelope.                                                  |

`message` MUST NOT echo back unsanitised request input.

### Field-error array (validation errors only)

For `400 validation_error`, the envelope is extended with a `field_errors` array reporting every offending field at once (not fail-fast — FR-002):

```json
{
  "error": "validation_error",
  "message": "One or more fields are invalid.",
  "field_errors": [
    { "field": "requested_amount_minor", "message": "Must be between 100000 and 2500000 (£1,000–£25,000)." },
    { "field": "term_months", "message": "Must be one of 12, 24, 36, 48, 60." }
  ]
}
```

## Permission matrix

| Action                              | `customer`                              | `bank_staff` |
|-------------------------------------|-----------------------------------------|--------------|
| `POST /applications`                | ✅                                       | ❌ → 403      |
| `GET /applications`                 | ✅ (sees own only)                       | ✅ (sees pending queue by default; status filter allowed) |
| `GET /applications/{reference}`     | ✅ (only if `customer_id == caller.id`; otherwise → 404, not 403, to avoid leaking existence per FR-013) | ✅ (any) |
| `POST /applications/{reference}/decision` | ❌ → 403                          | ✅            |
| `GET /applications/{reference}/audit`     | ❌ → 403                          | ✅            |

---

## `POST /applications` — submit a loan application

### Request

```http
POST /applications HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "requested_amount_minor": 500000,
  "term_months": 36,
  "purpose": "Kitchen renovation",
  "employment_status": "employed",
  "employer_name": "Acme Bakery Ltd",
  "gross_annual_income_minor": 4200000
}
```

| Field                       | Type    | Required | Notes                                                                       |
|-----------------------------|---------|----------|-----------------------------------------------------------------------------|
| `requested_amount_minor`    | int     | yes      | Pence. 100000 ≤ value ≤ 2500000 (£1,000–£25,000).                           |
| `term_months`               | int     | yes      | One of 12, 24, 36, 48, 60.                                                  |
| `purpose`                   | string  | yes      | Non-empty, ≤500 chars.                                                      |
| `employment_status`         | string  | yes      | One of `employed`, `self_employed`, `unemployed`, `retired`, `student`.     |
| `employer_name`             | string  | required iff `employment_status == "employed"` | Non-empty when required; absent or `null` otherwise. |
| `gross_annual_income_minor` | int     | yes      | Pence. ≥ 0.                                                                 |

`contact_preference_snapshot` is **not** in the request body; it is taken from the authenticated customer's `users.contact_preference` at submission time.

### Authorisation

| Role         | Allowed? |
|--------------|----------|
| `customer`   | ✅        |
| `bank_staff` | ❌ → `403 permission_denied`. |

### Responses

**201 Created** — application accepted; status is `Pending Review`; one `submitted` event written.

```json
{
  "reference": "LA-2026-000042",
  "status": "Pending Review",
  "submitted_at": "2026-05-17T10:14:33.221Z",
  "requested_amount_minor": 500000,
  "term_months": 36,
  "purpose": "Kitchen renovation",
  "employment_status": "employed",
  "employer_name": "Acme Bakery Ltd",
  "gross_annual_income_minor": 4200000,
  "contact_preference": "in_app",
  "expected_review_within_business_days": 2
}
```

**400 `validation_error`** — see envelope above.

**409 `has_pending_application`** — customer already has one in `Pending Review`:

```json
{
  "error": "has_pending_application",
  "message": "You already have an application under review.",
  "existing_reference": "LA-2026-000041",
  "existing_status": "Pending Review"
}
```

**403 `permission_denied`** — staff attempted submission.

---

## `GET /applications` — list applications

### Request

```http
GET /applications?status=Pending%20Review HTTP/1.1
Authorization: Bearer <token>
```

| Query param | Type   | Required | Notes                                                                       |
|-------------|--------|----------|-----------------------------------------------------------------------------|
| `status`    | string | no       | Filter to one of `Pending Review`, `Approved`, `Rejected`. Staff-only filter; customers always see only their own applications regardless of `status`. |

### Authorisation and scoping

| Role         | What is returned                                                                                       |
|--------------|--------------------------------------------------------------------------------------------------------|
| `customer`   | All applications where `customer_id == caller.id`. Ordered by `submitted_at DESC`. `status` query param accepted but applied within own applications only. |
| `bank_staff` | If `status` omitted: applications in `Pending Review`, ordered by `submitted_at ASC` (oldest first, FR-007). If `status` given: applications in that status, oldest first. |

### Responses

**200 OK**:

```json
{
  "applications": [
    {
      "reference": "LA-2026-000041",
      "customer_id": "user-uuid",
      "customer_name": "Alice Customer",
      "requested_amount_minor": 750000,
      "term_months": 24,
      "status": "Pending Review",
      "submitted_at": "2026-05-15T09:00:00Z",
      "decided_at": null,
      "decision_type": null,
      "decision_reason": null
    }
  ]
}
```

Note: customer responses omit other customers' applications entirely (they are filtered out before serialisation, never sent in a redacted form).

---

## `GET /applications/{reference}` — view a single application

### Request

```http
GET /applications/LA-2026-000042 HTTP/1.1
Authorization: Bearer <token>
```

### Authorisation

| Role         | Behaviour                                                                                              |
|--------------|--------------------------------------------------------------------------------------------------------|
| `customer`   | If the application is theirs → 200. If it exists but belongs to another customer → `404 not_found` (we do not distinguish "not yours" from "doesn't exist" to avoid leaking existence; FR-013, SC-004). |
| `bank_staff` | Any existing reference → 200. Non-existent → `404 not_found`.                                          |

### Responses

**200 OK** — the application body in the same shape as the 201 from POST, plus decision fields (null while pending):

```json
{
  "reference": "LA-2026-000042",
  "status": "Approved",
  "submitted_at": "2026-05-17T10:14:33.221Z",
  "requested_amount_minor": 500000,
  "term_months": 36,
  "purpose": "Kitchen renovation",
  "employment_status": "employed",
  "employer_name": "Acme Bakery Ltd",
  "gross_annual_income_minor": 4200000,
  "contact_preference": "in_app",
  "customer_id": "user-uuid",
  "customer_name": "Alice Customer",
  "decided_at": "2026-05-19T11:02:00Z",
  "decision_type": "Approved",
  "decision_reason": "Income comfortably covers requested term.",
  "decided_by_user_id": "staff-uuid"
}
```

For applications still in `Pending Review`, `decided_at`, `decision_type`, `decision_reason`, and `decided_by_user_id` are all `null`. For customer responses, `decided_by_user_id` is omitted (staff identity is not exposed to customers).

**404 `not_found`** — non-existent reference *or* customer asking about an application that isn't theirs.

---

## `POST /applications/{reference}/decision` — record a decision

### Request

```http
POST /applications/LA-2026-000042/decision HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "decision_type": "Approved",
  "reason": "Income comfortably covers requested term."
}
```

| Field           | Type   | Required | Notes                                            |
|-----------------|--------|----------|--------------------------------------------------|
| `decision_type` | string | yes      | One of `Approved`, `Rejected`.                   |
| `reason`        | string | yes      | Non-empty, ≤1000 chars (FR-009).                 |

### Authorisation

| Role         | Allowed? |
|--------------|----------|
| `customer`   | ❌ → `403 permission_denied`. |
| `bank_staff` | ✅        |

### Responses

**200 OK** — decision recorded. Body is the full updated application (same shape as `GET /applications/{reference}` 200 with decision fields populated).

**400 `validation_error`** — bad `decision_type` or empty `reason`.

**404 `not_found`** — non-existent reference.

**409 `already_decided`** — application's current status is not `Pending Review` (concurrent decision or already-decided). Body:

```json
{
  "error": "already_decided",
  "message": "This application has already been decided.",
  "current_status": "Approved",
  "decided_at": "2026-05-19T11:02:00Z"
}
```

This response is also what a second concurrent decision loses with (FR-012, SC-005).

**403 `permission_denied`** — customer attempted decision.

---

## `GET /applications/{reference}/audit` — staff-only audit view

### Request

```http
GET /applications/LA-2026-000042/audit HTTP/1.1
Authorization: Bearer <token>
```

### Authorisation

| Role         | Allowed? |
|--------------|----------|
| `customer`   | ❌ → `403 permission_denied`. |
| `bank_staff` | ✅        |

### Responses

**200 OK**:

```json
{
  "reference": "LA-2026-000042",
  "events": [
    {
      "event_type": "submitted",
      "actor_user_id": "user-uuid",
      "actor_username": "alice",
      "occurred_at": "2026-05-17T10:14:33.221Z"
    },
    {
      "event_type": "approved",
      "actor_user_id": "staff-uuid",
      "actor_username": "staff_brenda",
      "occurred_at": "2026-05-19T11:02:00Z"
    }
  ]
}
```

Events are ordered `occurred_at ASC`.

**404 `not_found`** — non-existent reference.

## Invariants the contract is built to expose

| Invariant                                                                                    | Surfaced by                                                                                       |
|----------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| One in-flight application per customer (FR-005, SC-001 reliant)                              | `409 has_pending_application` on `POST /applications`                                             |
| Decisions never conflict (FR-010, FR-012, SC-005)                                            | `409 already_decided` on `POST /applications/{reference}/decision`                                |
| Customer never sees another customer's application (FR-013, SC-004)                          | `GET /applications` filters by `customer_id`; `GET /applications/{reference}` returns 404, not 403, on non-owner access (no existence leak) |
| Customer never makes a decision (FR-015, SC-004)                                             | `403 permission_denied` from a single explicit table consulted in every handler                   |
| Audit trail is append-only (FR-016)                                                          | No endpoint writes to `application_events` except as a side effect of submit/decide              |

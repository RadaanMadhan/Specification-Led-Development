# Data Model: Loan Application

**Branch**: `003-loan-application` | **Date**: 2026-05-17

All entities are persisted in SQLite (`sqlite3` stdlib). All UUIDs are UUID4 strings. All timestamps are ISO-8601 UTC strings (`datetime.now(UTC).isoformat()`). All monetary amounts are integer minor units (pence). All enums are persisted as `TEXT` with a `CHECK` constraint restricting the value set.

## Enums

### Role

```python
class Role(StrEnum):
    CUSTOMER = "customer"
    BANK_STAFF = "bank_staff"
```

A `User` has exactly one `Role`.

### ApplicationStatus

```python
class ApplicationStatus(StrEnum):
    PENDING_REVIEW = "Pending Review"
    APPROVED = "Approved"
    REJECTED = "Rejected"
```

Stored as `TEXT CHECK IN ('Pending Review','Approved','Rejected') NOT NULL`. Allowed transitions are exactly `Pending Review → Approved` and `Pending Review → Rejected`; no other transitions are reachable through any public code path (no UPDATE statement in `store.py` targets `status` outside the conditional decision path).

### EmploymentStatus

```python
class EmploymentStatus(StrEnum):
    EMPLOYED = "employed"
    SELF_EMPLOYED = "self_employed"
    UNEMPLOYED = "unemployed"
    RETIRED = "retired"
    STUDENT = "student"
```

`employer_name` is required iff `EmploymentStatus == EMPLOYED`; enforced by `validation.py` at submission time (FR-002).

### ContactPreference

```python
class ContactPreference(StrEnum):
    IN_APP = "in_app"
    EMAIL = "email"
```

### EventType

```python
class EventType(StrEnum):
    SUBMITTED = "submitted"
    APPROVED = "approved"
    REJECTED = "rejected"
```

Used in the `application_events` audit log (FR-016).

### DecisionType

```python
class DecisionType(StrEnum):
    APPROVED = "Approved"
    REJECTED = "Rejected"
```

Decision rows record the staff decision; mirrors the post-decision `ApplicationStatus` values.

## Entities

### User

A person who can authenticate against the service. Both customers and bank staff are represented by the same table, distinguished by `role`.

| Field    | Type | Storage                                              | Notes |
|----------|------|------------------------------------------------------|-------|
| id       | str  | TEXT PK                                              | UUID4. |
| username | str  | TEXT UNIQUE NOT NULL                                 | Human-readable label; used in audit log readability. |
| display_name | str | TEXT NOT NULL                                     | Customer name shown to staff in the queue (FR-007). |
| email | str | TEXT NOT NULL                                          | Used by the email notification stub. |
| role     | Role | TEXT CHECK IN ('customer','bank_staff') NOT NULL    | Exactly one role per user. Customers also carry `contact_preference`; for staff this column is ignored. |
| contact_preference | ContactPreference | TEXT CHECK IN ('in_app','email') NOT NULL DEFAULT 'in_app' | Customer-only field; ignored for staff. |

**Notes**:
- No password / credential field. Authentication is stub (see `auth.py`); a separate `tokens` table maps bearer tokens to `users.id`.
- Customer's `contact_preference` is fixed at seed time; the spec does not require an "edit my preferences" flow.

### Token (auth stub)

Maps a bearer token to a `User`. Seeded at startup; not exposed by any endpoint.

| Field   | Type | Storage                  | Notes |
|---------|------|--------------------------|-------|
| token   | str  | TEXT PK                  | Opaque string presented in `Authorization: Bearer <token>`. |
| user_id | str  | TEXT NOT NULL FK→users.id | Resolves the token to an authenticated user. |

### LoanApplication

A single request for a personal loan.

| Field              | Type   | Storage                                              | Notes |
|--------------------|--------|------------------------------------------------------|-------|
| id                 | int    | INTEGER PRIMARY KEY AUTOINCREMENT                    | Monotonic sequence. Drives `reference`. Never exposed in the API. |
| reference          | str    | TEXT UNIQUE NOT NULL                                 | Human-readable, `LA-YYYY-NNNNNN`. The API's primary key for an application. |
| customer_id        | str    | TEXT NOT NULL FK→users.id                            | The submitter. |
| requested_amount_minor | int | INTEGER NOT NULL CHECK(requested_amount_minor BETWEEN 100000 AND 2500000) | Pence. 100000 = £1,000; 2500000 = £25,000. CHECK is structural backstop for FR-003. |
| term_months        | int    | INTEGER NOT NULL CHECK(term_months IN (12,24,36,48,60)) | FR-003. |
| purpose            | str    | TEXT NOT NULL                                        | Free-text. Length cap (e.g., 500 chars) enforced in validation. |
| employment_status  | EmploymentStatus | TEXT CHECK IN (…) NOT NULL                 | See enum above. |
| employer_name      | str \| None | TEXT NULL                                       | Required iff `employment_status='employed'`; enforced in validation. |
| gross_annual_income_minor | int | INTEGER NOT NULL CHECK(gross_annual_income_minor >= 0) | Pence. |
| contact_preference_snapshot | ContactPreference | TEXT CHECK IN ('in_app','email') NOT NULL | Snapshot of the customer's preference at submission time; the notification stub reads this column, not the live `users.contact_preference`, so changing the user record never retroactively changes the channel of a past application. |
| status             | ApplicationStatus | TEXT CHECK IN ('Pending Review','Approved','Rejected') NOT NULL | Initial value at insert: `'Pending Review'`. |
| submitted_at       | str    | TEXT NOT NULL                                        | ISO-8601 UTC. |

**Indexes / constraints (beyond column-level CHECKs)**:

- `CREATE UNIQUE INDEX idx_one_pending_per_customer ON loan_applications(customer_id) WHERE status = 'Pending Review';` — **structural enforcement of FR-005**. A second insert (or a hypothetical revert-to-pending UPDATE) for the same customer fails with `IntegrityError`, which `service.py` maps to `409 has_pending_application`.
- `CREATE INDEX idx_pending_by_submitted ON loan_applications(submitted_at) WHERE status = 'Pending Review';` — supports the oldest-first staff queue ordering (FR-007).

**Validation (at submission time, in `validation.py`)**:

- All fields present.
- `requested_amount_minor` between 100000 and 2500000 inclusive.
- `term_months` in {12, 24, 36, 48, 60}.
- `purpose` non-empty, ≤500 chars.
- `employment_status` one of the enum values.
- `employer_name` non-empty iff `employment_status == 'employed'`; absent or empty otherwise.
- `gross_annual_income_minor` integer ≥ 0.
- `contact_preference` one of the enum values.

`validation.py` reports **all** violations in one response (not fail-fast), to satisfy FR-002's field-level guarantee usefully.

### Decision

The staff decision recorded against a loan application. At most one row per application (enforced by application status, see below).

| Field           | Type | Storage                              | Notes |
|-----------------|------|--------------------------------------|-------|
| application_id  | int  | INTEGER PK FK→loan_applications.id   | One-to-one with `LoanApplication`. PK by itself enforces "at most one decision per application" structurally. |
| decision_type   | DecisionType | TEXT CHECK IN ('Approved','Rejected') NOT NULL | |
| reason          | str  | TEXT NOT NULL CHECK(length(reason) > 0) | Non-empty required by FR-009. Length cap (e.g., 1000 chars) enforced in validation. |
| decided_by_user_id | str | TEXT NOT NULL FK→users.id          | Staff who decided. |
| decided_at      | str  | TEXT NOT NULL                        | ISO-8601 UTC. |

**Notes**:

- The decision is recorded in the same DB transaction as the application status update and the audit event. The status update is a conditional `UPDATE … WHERE status='Pending Review'` that returns rowcount=1 only if the caller won the race; on rowcount=0, the transaction rolls back and the handler returns `409 already_decided` (FR-012, SC-005).
- No UPDATE/DELETE statement in `store.py` targets `decisions`; once written, a decision is immutable (FR-011).

### ApplicationEvent (audit log)

Append-only record of every status-changing event on an application (FR-016).

| Field          | Type | Storage                              | Notes |
|----------------|------|--------------------------------------|-------|
| id             | int  | INTEGER PRIMARY KEY AUTOINCREMENT    | |
| application_id | int  | INTEGER NOT NULL FK→loan_applications.id | |
| event_type     | EventType | TEXT CHECK IN ('submitted','approved','rejected') NOT NULL | |
| actor_user_id  | str  | TEXT NOT NULL FK→users.id            | Customer for `submitted`; staff for `approved`/`rejected`. |
| occurred_at    | str  | TEXT NOT NULL                        | ISO-8601 UTC. |

**Indexes / constraints**:

- `CREATE INDEX idx_events_by_application ON application_events(application_id, occurred_at);` — supports the staff per-application audit view (FR-016).
- No UPDATE/DELETE code path targets this table in `store.py` (append-only at code layer). `test_invariants.py` includes a probe that grep-checks `store.py` for forbidden statements and a runtime probe that submits, decides, then attempts every public endpoint and asserts the row count of `application_events` only grew.

### NotificationLog (for testability of FR-014)

Records every notification emission. The default `NotificationSink` writes the row *and* prints a structured line to stdout; tests can swap in a recording sink, but the log table exists either way so that operationally a staff member can confirm a notification was triggered.

| Field          | Type | Storage                              | Notes |
|----------------|------|--------------------------------------|-------|
| id             | int  | INTEGER PRIMARY KEY AUTOINCREMENT    | |
| application_id | int  | INTEGER NOT NULL FK→loan_applications.id | |
| channel        | ContactPreference | TEXT CHECK IN ('in_app','email') NOT NULL | Which channel was used. |
| recipient      | str  | TEXT NOT NULL                        | Email address (for `email`) or user id (for `in_app`). |
| message_status | ApplicationStatus | TEXT NOT NULL                | The status the notification announces. |
| sent_at        | str  | TEXT NOT NULL                        | ISO-8601 UTC. |

## Entity-relationship diagram

```text
users (1) ────< tokens (auth stub)
   │
   │ (1 customer)               (1 staff member)
   │
   ├──< loan_applications ─── (1) ─── decisions
   │             │
   │             └──< application_events     (append-only audit)
   │             └──< notification_log       (FR-014 emissions)
```

## SQL schema (illustrative)

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    display_name TEXT NOT NULL,
    email TEXT NOT NULL,
    role TEXT CHECK (role IN ('customer','bank_staff')) NOT NULL,
    contact_preference TEXT CHECK (contact_preference IN ('in_app','email')) NOT NULL DEFAULT 'in_app'
);

CREATE TABLE tokens (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id)
);

CREATE TABLE loan_applications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    reference TEXT UNIQUE NOT NULL,
    customer_id TEXT NOT NULL REFERENCES users(id),
    requested_amount_minor INTEGER NOT NULL
        CHECK (requested_amount_minor BETWEEN 100000 AND 2500000),
    term_months INTEGER NOT NULL CHECK (term_months IN (12,24,36,48,60)),
    purpose TEXT NOT NULL,
    employment_status TEXT NOT NULL
        CHECK (employment_status IN ('employed','self_employed','unemployed','retired','student')),
    employer_name TEXT,
    gross_annual_income_minor INTEGER NOT NULL CHECK (gross_annual_income_minor >= 0),
    contact_preference_snapshot TEXT NOT NULL
        CHECK (contact_preference_snapshot IN ('in_app','email')),
    status TEXT NOT NULL
        CHECK (status IN ('Pending Review','Approved','Rejected')),
    submitted_at TEXT NOT NULL
);

CREATE UNIQUE INDEX idx_one_pending_per_customer
    ON loan_applications(customer_id) WHERE status = 'Pending Review';

CREATE INDEX idx_pending_by_submitted
    ON loan_applications(submitted_at) WHERE status = 'Pending Review';

CREATE TABLE decisions (
    application_id INTEGER PRIMARY KEY REFERENCES loan_applications(id),
    decision_type TEXT NOT NULL CHECK (decision_type IN ('Approved','Rejected')),
    reason TEXT NOT NULL CHECK (length(reason) > 0),
    decided_by_user_id TEXT NOT NULL REFERENCES users(id),
    decided_at TEXT NOT NULL
);

CREATE TABLE application_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    application_id INTEGER NOT NULL REFERENCES loan_applications(id),
    event_type TEXT NOT NULL CHECK (event_type IN ('submitted','approved','rejected')),
    actor_user_id TEXT NOT NULL REFERENCES users(id),
    occurred_at TEXT NOT NULL
);

CREATE INDEX idx_events_by_application
    ON application_events(application_id, occurred_at);

CREATE TABLE notification_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    application_id INTEGER NOT NULL REFERENCES loan_applications(id),
    channel TEXT NOT NULL CHECK (channel IN ('in_app','email')),
    recipient TEXT NOT NULL,
    message_status TEXT NOT NULL,
    sent_at TEXT NOT NULL
);
```

## How invariants map to storage

| Invariant (from spec)                                                          | Where enforced                                                                                          |
|--------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| FR-003 amount range and term set                                               | Validation + column CHECKs on `requested_amount_minor` and `term_months`                                |
| FR-004 unique reference number                                                 | `loan_applications.reference UNIQUE NOT NULL` + AUTOINCREMENT-driven formatting in `service.py`         |
| FR-005 one pending application per customer (SC-001 reliant)                   | `idx_one_pending_per_customer` partial unique index                                                     |
| FR-009 reason required on decision                                             | Validation + `decisions.reason CHECK(length(reason) > 0)`                                               |
| FR-010 + FR-012 atomic decision, no second decision (SC-005)                   | One transaction containing conditional UPDATE + decision INSERT + event INSERT; conditional UPDATE filtering on `status='Pending Review'` guarantees rowcount=1 means winner, rowcount=0 means already-decided |
| FR-011 immutability of decided applications                                    | No UPDATE/DELETE path in `store.py` targets `decisions` or `loan_applications.status` outside the one conditional UPDATE                                                |
| FR-013 customer cannot see another customer's application (SC-004)             | `permissions.py` table + service query filters `WHERE customer_id = ?` for customer role               |
| FR-016 audit trail of status changes                                           | `application_events` append-only table; `test_invariants.py` proves no public path mutates it           |
| FR-017 retention ≥ 6 years                                                     | No DELETE code path; operational retention scheduling is out of scope                                   |

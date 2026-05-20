# Data Model: Loan Application with Role-Based Workflow and Audit Trail

**Branch**: `004-loan-application-rbac` | **Date**: 2026-05-17

All entities are persisted in SQLite (`sqlite3` stdlib). All UUIDs are UUID4 strings. All timestamps are ISO-8601 UTC (`datetime.now(UTC).isoformat()`). All monetary amounts are integer minor units (pence). All enums are persisted as `TEXT` with a `CHECK` constraint restricting the value set.

## Enums

### Role

```python
class Role(StrEnum):
    CUSTOMER = "customer"
    LOAN_OFFICER = "loan_officer"
    COMPLIANCE_REVIEWER = "compliance_reviewer"
```

A `User` has exactly one `Role` (spec Assumptions: "A user has exactly one role").

### ApplicationStatus

```python
class ApplicationStatus(StrEnum):
    SUBMITTED = "Submitted"
    UNDER_REVIEW = "Under Review"
    APPROVED = "Approved"
    REJECTED = "Rejected"
```

Stored as `TEXT CHECK IN ('Submitted','Under Review','Approved','Rejected') NOT NULL`. Allowed transitions:

```text
(none)  ──submit──▶  Submitted  ──claim──▶  Under Review  ──decide──▶  Approved
                                                                  └──▶  Rejected
```

No other transitions are reachable through any public code path (only three SQL UPDATE statements in `store.py` mutate `loan_applications.status`, each filtering on the source status; no DELETE).

### DecisionType

```python
class DecisionType(StrEnum):
    APPROVED = "Approved"
    REJECTED = "Rejected"
```

## Entities

### User

A person who can authenticate against the service. Customers, loan officers, and compliance reviewers are all represented by the same table, distinguished by `role`.

| Field         | Type | Storage                                                                       | Notes |
|---------------|------|-------------------------------------------------------------------------------|-------|
| id            | str  | TEXT PK                                                                       | UUID4. |
| username      | str  | TEXT UNIQUE NOT NULL                                                          | Human-readable label; used in audit-log readability. |
| display_name  | str  | TEXT NOT NULL                                                                 | Shown in queue listings (FR-010) and in audit responses to compliance / officers. Never shown to customers when it refers to an officer (FR-021). |
| role          | Role | TEXT CHECK IN ('customer','loan_officer','compliance_reviewer') NOT NULL      | Exactly one role per user. |

No password / credential field. Authentication is stub (see `auth.py`); a separate `tokens` table maps bearer tokens to `users.id`.

### Token (auth stub)

| Field   | Type | Storage                  | Notes |
|---------|------|--------------------------|-------|
| token   | str  | TEXT PK                  | Opaque string presented in `Authorization: Bearer <token>`. |
| user_id | str  | TEXT NOT NULL FK→users.id | Resolves the token to an authenticated user. |

### LoanApplication

A single customer request for a loan.

| Field                  | Type   | Storage                                                                       | Notes |
|------------------------|--------|-------------------------------------------------------------------------------|-------|
| id                     | int    | INTEGER PRIMARY KEY AUTOINCREMENT                                             | Monotonic sequence; drives `reference`. Never exposed in the API. |
| reference              | str    | TEXT UNIQUE NOT NULL                                                          | Human-readable, `LA-YYYY-NNNNNN`. The API's primary key for an application. |
| customer_id            | str    | TEXT NOT NULL FK→users.id                                                     | Must reference a user whose role is `customer` (enforced at insert time in `service.py`). |
| requested_amount_minor | int    | INTEGER NOT NULL CHECK(requested_amount_minor BETWEEN 100000 AND 2500000)     | Pence. 100000 = £1,000; 2500000 = £25,000. Structural backstop for FR-007. |
| purpose                | str    | TEXT NOT NULL CHECK(length(purpose) BETWEEN 1 AND 500)                        | Non-empty, ≤500 chars. Structural backstop for FR-006/FR-007. |
| status                 | ApplicationStatus | TEXT CHECK IN ('Submitted','Under Review','Approved','Rejected') NOT NULL | Initial value at insert: `'Submitted'`. |
| assigned_officer_id    | str \| None | TEXT NULL FK→users.id                                                    | Null while `status='Submitted'`; set non-null when transitioning to `'Under Review'`; preserved through `'Approved'`/`'Rejected'`. The officer referenced must have `role='loan_officer'` (enforced at claim time in `service.py`). |
| submitted_at           | str    | TEXT NOT NULL                                                                 | ISO-8601 UTC. |

**Indexes / structural constraints**:

- `CREATE UNIQUE INDEX idx_one_in_flight_per_customer ON loan_applications(customer_id) WHERE status IN ('Submitted','Under Review');` — **structural enforcement of FR-008**. A customer cannot have two simultaneous in-flight applications; a second insert (or a hypothetical revert-to-pending UPDATE) fails with `IntegrityError`, which `service.py` maps to `409 has_in_flight_application`.
- `CREATE INDEX idx_unassigned_by_submitted ON loan_applications(submitted_at) WHERE status = 'Submitted';` — supports the oldest-first unassigned queue ordering (FR-010).
- `CHECK ((status = 'Submitted') = (assigned_officer_id IS NULL))` — couples `assigned_officer_id` to the status state machine: `Submitted` ⇔ unassigned; `Under Review`/`Approved`/`Rejected` ⇔ assigned. The application-layer transitions ensure this never has to fire, but the CHECK is a defence-in-depth backstop.

**Validation (at submission time, in `validation.py`)**:

- `requested_amount_minor` present, integer, between 100000 and 2500000 inclusive.
- `purpose` present, non-empty, ≤500 characters.

`validation.py` reports **all** violations in one response (not fail-fast), to satisfy FR-006's field-level guarantee usefully.

### Decision

The officer decision recorded against an application. At most one row per application (enforced by PK + status state machine).

| Field           | Type | Storage                                                                                                                  | Notes |
|-----------------|------|--------------------------------------------------------------------------------------------------------------------------|-------|
| application_id  | int  | INTEGER PK FK→loan_applications.id                                                                                       | One-to-one with `LoanApplication`. PK by itself enforces "at most one decision per application" structurally. |
| decision_type   | DecisionType | TEXT CHECK IN ('Approved','Rejected') NOT NULL                                                                   | |
| reason          | str  | TEXT NOT NULL CHECK(length(reason) BETWEEN 1 AND 1000)                                                                   | Non-empty required by FR-014; length cap enforced in validation + structurally. |
| decided_by_user_id | str | TEXT NOT NULL FK→users.id                                                                                              | The deciding officer. `service.py` asserts that this matches `loan_applications.assigned_officer_id` for the application at decide time; the conditional UPDATE makes the assertion structural. |
| decided_at      | str  | TEXT NOT NULL                                                                                                            | ISO-8601 UTC. |

**Notes**:

- The decision row is inserted in the same DB transaction as the application status update and the audit-entry insert. The status update is the conditional `UPDATE … WHERE status='Under Review' AND assigned_officer_id=?` whose rowcount discriminates "winner" (1) from "lost the race or not assigned" (0).
- No UPDATE/DELETE statement in `store.py` targets `decisions`; once written, a decision is immutable (FR-016).

### ApplicationEvent (audit trail)

Append-only record of every status transition on an application. One row per *applied* transition (FR-019).

| Field            | Type | Storage                                                                                            | Notes |
|------------------|------|----------------------------------------------------------------------------------------------------|-------|
| id               | int  | INTEGER PRIMARY KEY AUTOINCREMENT                                                                  | |
| application_id   | int  | INTEGER NOT NULL FK→loan_applications.id                                                           | |
| previous_status  | ApplicationStatus \| None | TEXT CHECK IN ('Submitted','Under Review','Approved','Rejected') NULL          | `NULL` only for the initial `(none) → Submitted` event. |
| new_status       | ApplicationStatus | TEXT CHECK IN ('Submitted','Under Review','Approved','Rejected') NOT NULL                 | |
| actor_user_id    | str  | TEXT NOT NULL FK→users.id                                                                          | Customer for the initial submission; loan officer for claim and decision. |
| occurred_at      | str  | TEXT NOT NULL                                                                                      | ISO-8601 UTC. |

**Structural constraints**:

- `CHECK ((previous_status IS NULL) = (new_status = 'Submitted'))` — the `previous_status = NULL` case is exactly and only the initial submission event.
- `CHECK (previous_status IS NULL OR previous_status <> new_status)` — an audit entry never records a no-op transition.
- `CREATE INDEX idx_events_by_application ON application_events(application_id, occurred_at);` — supports the chronological audit view (FR-018).

**Append-only invariant (FR-018)**: no UPDATE/DELETE code path in `store.py` targets this table. `test_invariants.py` includes (a) a static probe that grep-checks `store.py` for forbidden statements against `application_events` and (b) a runtime probe that runs every endpoint as every role and asserts that the row count of `application_events` is monotonically non-decreasing and that no existing row's content changes.

## Entity-relationship diagram

```text
users (1) ───< tokens                                       (auth stub)
   │
   │ (1 customer)         (1 officer, optional)        (compliance has no FK to applications — read-only role)
   │
   ├──< loan_applications ─── (0..1) ─── decisions
   │             │
   │             └──< application_events                    (append-only audit; ≥1 row per application)
   │
   └── (1 actor) ───────────────────────────< application_events
```

## State machine and audit-entry production

Each successful transition produces exactly one new row in `application_events`, inserted in the same DB transaction as the status update:

| Transition                       | Trigger                                          | actor_user_id           | previous_status | new_status     |
|----------------------------------|--------------------------------------------------|-------------------------|-----------------|----------------|
| `(none)` → `Submitted`           | `POST /applications` (customer)                  | the submitting customer | `NULL`          | `Submitted`    |
| `Submitted` → `Under Review`     | `POST /applications/{ref}/claim` (loan_officer)  | the claiming officer    | `Submitted`     | `Under Review` |
| `Under Review` → `Approved`      | `POST /applications/{ref}/decision` (assigned)   | the assigned officer    | `Under Review`  | `Approved`     |
| `Under Review` → `Rejected`      | `POST /applications/{ref}/decision` (assigned)   | the assigned officer    | `Under Review`  | `Rejected`     |

Any other transition (e.g., `Approved` → `Rejected`, or `Submitted` → `Approved` skipping claim) is unreachable: there is no SQL path that produces it, because each conditional `UPDATE` filters on the source status (and, for decide, on the assigned officer).

## SQL schema (illustrative)

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    display_name TEXT NOT NULL,
    role TEXT CHECK (role IN ('customer','loan_officer','compliance_reviewer')) NOT NULL
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
    purpose TEXT NOT NULL
        CHECK (length(purpose) BETWEEN 1 AND 500),
    status TEXT NOT NULL
        CHECK (status IN ('Submitted','Under Review','Approved','Rejected')),
    assigned_officer_id TEXT REFERENCES users(id),
    submitted_at TEXT NOT NULL,
    CHECK ((status = 'Submitted') = (assigned_officer_id IS NULL))
);

CREATE UNIQUE INDEX idx_one_in_flight_per_customer
    ON loan_applications(customer_id)
    WHERE status IN ('Submitted','Under Review');

CREATE INDEX idx_unassigned_by_submitted
    ON loan_applications(submitted_at) WHERE status = 'Submitted';

CREATE TABLE decisions (
    application_id INTEGER PRIMARY KEY REFERENCES loan_applications(id),
    decision_type TEXT NOT NULL CHECK (decision_type IN ('Approved','Rejected')),
    reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 1000),
    decided_by_user_id TEXT NOT NULL REFERENCES users(id),
    decided_at TEXT NOT NULL
);

CREATE TABLE application_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    application_id INTEGER NOT NULL REFERENCES loan_applications(id),
    previous_status TEXT
        CHECK (previous_status IN ('Submitted','Under Review','Approved','Rejected')),
    new_status TEXT NOT NULL
        CHECK (new_status IN ('Submitted','Under Review','Approved','Rejected')),
    actor_user_id TEXT NOT NULL REFERENCES users(id),
    occurred_at TEXT NOT NULL,
    CHECK ((previous_status IS NULL) = (new_status = 'Submitted')),
    CHECK (previous_status IS NULL OR previous_status <> new_status)
);

CREATE INDEX idx_events_by_application
    ON application_events(application_id, occurred_at);
```

## How invariants map to storage

| Invariant (from spec)                                                          | Where enforced                                                                                                            |
|--------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| FR-002 / FR-003 / FR-004 / FR-023 role-gated actions (SC-004, SC-008)           | `permissions.is_allowed(role, action, context)` table consulted in every handler before service-layer call                |
| FR-007 amount range, purpose length                                            | Validation + column CHECKs on `requested_amount_minor` and `purpose`                                                      |
| FR-008 one in-flight per customer                                              | `idx_one_in_flight_per_customer` partial unique index over `status IN ('Submitted','Under Review')`                       |
| FR-011 / FR-012 claim race resolution (SC-006)                                 | Conditional `UPDATE … WHERE status='Submitted'` (sole legal transition into `Under Review`); rowcount=1 ⇒ winner          |
| FR-013 only-assigned-officer-decides (SC-005)                                  | Conditional `UPDATE … WHERE status='Under Review' AND assigned_officer_id=?` (sole legal transition into `Approved`/`Rejected`); rowcount=1 ⇒ caller is the assigned officer AND status is still under review                                                |
| FR-014 reason required                                                         | Validation + `decisions.reason CHECK(length(reason) BETWEEN 1 AND 1000)`                                                  |
| FR-015 atomic decision + status + audit                                        | All three writes in one `BEGIN IMMEDIATE … COMMIT`                                                                        |
| FR-016 immutability of decided applications                                    | No SQL path in `store.py` targets `loan_applications.status` outside the three conditional UPDATEs, and none of the three accept `Approved`/`Rejected` as a source status; no UPDATE/DELETE on `decisions`                                                          |
| FR-017 / FR-018 / FR-019 audit trail (SC-007)                                  | One INSERT into `application_events` per successful conditional UPDATE, in the same transaction; no UPDATE/DELETE code path on `application_events`; `test_invariants.py` static + runtime probes                                                                  |
| FR-020 customer cannot see other customers (SC-004)                            | `permissions.py` + `service.list_for_customer(customer_id)` filters by `customer_id`; `service.get(reference, caller)` returns `not_found` (not `permission_denied`) when the caller is a customer who doesn't own the application                                  |
| FR-021 officer identity hidden from customer                                   | `handlers.scrub_for_role(payload, role)` strips officer-identifier keys for customer responses; `test_handlers.py` walks every customer-role response and asserts officer keys absent                                                                              |
| FR-022 retention ≥ 6 years                                                     | No DELETE code path against `loan_applications`, `decisions`, or `application_events`; operational retention scheduling is out of scope                                                                                                                            |

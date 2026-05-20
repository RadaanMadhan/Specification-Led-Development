# Data Model: FCA-Regulated Loan Application

**Branch**: `005-fca-loan-applications` | **Date**: 2026-05-17

All entities are persisted in SQLite (`sqlite3` stdlib). All identifiers are UUID4 strings. All timestamps are UTC ISO 8601 with millisecond precision and explicit `Z` suffix (e.g., `2026-05-17T10:14:33.221Z`). All amounts are integer minor units (pence). All enums are persisted as `TEXT` with a `CHECK` constraint restricting the value set.

## Enums

### Role

```python
class Role(StrEnum):
    APPLICANT = "applicant"
    OFFICER = "officer"
    AUDITOR = "auditor"
    SYSTEM = "system"   # actor_role for system-initiated audit entries (e.g., "no eligible officer")
```

Role multiplicity (FR-002): a user can hold `{applicant}` alone, `{officer}` alone, `{auditor}` alone, `{applicant, officer}`, or `{applicant, auditor}`. The combination `{officer, auditor}` is forbidden and rejected at user creation. `system` is never assigned to a user; it appears only in `audit_entries.actor_role` for system-actor entries.

### ApplicationStatus

```python
class ApplicationStatus(StrEnum):
    PENDING = "pending"
    UNDER_REVIEW = "under_review"
    APPROVED = "approved"
    REJECTED = "rejected"
```

Stored as `TEXT CHECK IN ('pending','under_review','approved','rejected') NOT NULL`. Allowed transitions (FR-009):

```text
(none) ──submit──▶ pending ──officer PATCH──▶ under_review ──officer PATCH──▶ approved
                                                                          └─▶ rejected
```

No other transitions are reachable through any public code path.

### Purpose

```python
class Purpose(StrEnum):
    HOME_IMPROVEMENT = "home_improvement"
    DEBT_CONSOLIDATION = "debt_consolidation"
    VEHICLE = "vehicle"
    EDUCATION = "education"
    MEDICAL = "medical"
    WEDDING = "wedding"
    HOLIDAY = "holiday"
    BUSINESS = "business"
    OTHER = "other"
```

The fixed list from FR-007. Stored as `TEXT CHECK IN (…) NOT NULL`.

## Entities

### User

| Field         | Type | Storage                                                                       | Notes |
|---------------|------|-------------------------------------------------------------------------------|-------|
| id            | str  | TEXT PK                                                                       | UUID4. |
| username      | str  | TEXT UNIQUE NOT NULL                                                          | Human-readable label, used in audit-entry rendering for auditors. |
| display_name  | str  | TEXT NOT NULL                                                                 | Shown to officers + auditors; never to applicants when the user is an officer (FR-021). (For 005, customers do not see officer identity at all — see contract.) |
| roles         | str  | TEXT NOT NULL                                                                 | Comma-separated stable serialisation of the user's role set, e.g., `applicant`, `officer`, `applicant,officer`, `auditor`. `CHECK` constraint enforces: value matches one of the legal role-set serialisations and never contains both `officer` and `auditor`. Parsed into a `frozenset[Role]` on load. |

No password / credential field. Authentication is via OAuth 2.0 bearer (FR-001); the `TokenIntrospector` resolves a token to a `User`.

### Token (auth stub for v1)

| Field           | Type | Storage                  | Notes |
|-----------------|------|--------------------------|-------|
| token           | str  | TEXT PK                  | Opaque string presented in `Authorization: Bearer <token>`. |
| user_id         | str  | TEXT NOT NULL FK→users.id | Resolves the token to a user (and via the user, to a role set). |
| expires_at      | str  | TEXT NOT NULL             | UTC ISO 8601. Tokens past `expires_at` introspect as invalid (return `None`). |

In production, this table is replaced by the OAuth 2.0 introspection endpoint, which the `OAuth2Introspector` calls per RFC 7662 and which returns an equivalent shape.

### LoanApplication

A single applicant request for a loan.

| Field                  | Type   | Storage                                                                       | Notes |
|------------------------|--------|-------------------------------------------------------------------------------|-------|
| id                     | str    | TEXT PK                                                                       | UUID4 (opaque identifier; no human-readable reference in v1 — Assumptions). |
| applicant_id           | str    | TEXT NOT NULL FK→users.id                                                     | Must reference a user whose role set includes `applicant`. |
| amount_minor           | int    | INTEGER NOT NULL CHECK(amount_minor BETWEEN 100000 AND 2500000)               | Pence. 100000 = £1,000; 2500000 = £25,000. Structural backstop for FR-007. |
| purpose                | Purpose| TEXT CHECK IN (… nine values …) NOT NULL                                      | Structural backstop for FR-007. |
| status                 | ApplicationStatus | TEXT CHECK IN ('pending','under_review','approved','rejected') NOT NULL | Initial value at insert: `'pending'`. |
| assigned_officer_id    | str \| None | TEXT NULL FK→users.id                                                    | Set during the same transaction as the insert (FR-010), if an eligible officer exists. `NULL` only in the "no eligible officer" edge case (FR-011). Must reference a user whose role set includes `officer` (enforced at insert time in `service.py`). |
| submitted_at           | str    | TEXT NOT NULL                                                                 | UTC ISO 8601 with millisecond precision and `Z` suffix. |

**Indexes / structural constraints**:

- `CREATE UNIQUE INDEX idx_one_in_flight_per_applicant ON loan_applications(applicant_id) WHERE status IN ('pending','under_review');` — structural enforcement of FR-008.
- `CHECK (assigned_officer_id IS NULL OR assigned_officer_id != applicant_id)` — defence-in-depth for FR-011: even if the assignment service somehow tried to self-assign, the schema rejects it.

**Validation (at submission time, in `validation.py`)**:

- `amount_minor` present, integer, between 100000 and 2500000 inclusive.
- `purpose` present, one of the nine enum values.

`validation.py` reports **all** violations in one response (not fail-fast).

### OfficerRotation

A one-row table holding the round-robin cursor for officer assignment (FR-010).

| Field          | Type | Storage                  | Notes |
|----------------|------|--------------------------|-------|
| id             | int  | INTEGER PK CHECK(id = 1) | Exactly one row; the CHECK enforces it. |
| next_position  | int  | INTEGER NOT NULL CHECK(next_position >= 0) | Cursor into the deterministically-sorted officer pool; updated within the same transaction as each new application insert. |

The seed row `(id=1, next_position=0)` is created at schema initialisation.

### AuditEntry

Immutable, append-only record of one state transition on one application. Tamper-detectable via chained-hash (FR-018).

| Field            | Type | Storage                                                                                            | Notes |
|------------------|------|----------------------------------------------------------------------------------------------------|-------|
| id               | int  | INTEGER PRIMARY KEY AUTOINCREMENT                                                                  | Monotonic insert sequence; useful only for chronological ordering within an application. |
| application_id   | str  | TEXT NOT NULL FK→loan_applications.id                                                              | The application this entry concerns. |
| actor_id         | str  | TEXT NOT NULL                                                                                       | The user causing the transition, or the literal string `"system"` for system-actor entries. Not FK-constrained because of the `"system"` sentinel. |
| actor_role       | Role | TEXT CHECK IN ('applicant','officer','auditor','system') NOT NULL                                  | One of the four. |
| occurred_at      | str  | TEXT NOT NULL                                                                                       | UTC ISO 8601 with millisecond precision and `Z` suffix. |
| previous_status  | ApplicationStatus \| None | TEXT CHECK IN ('pending','under_review','approved','rejected') NULL                    | `NULL` only for the initial `(none) → pending` event. |
| new_status       | ApplicationStatus | TEXT CHECK IN ('pending','under_review','approved','rejected') NOT NULL                   | |
| reason           | str  | TEXT NOT NULL CHECK(length(reason) BETWEEN 1 AND 1000)                                              | FR-014, FR-016. |
| prev_hash        | str  | TEXT NOT NULL                                                                                       | Hex SHA-256 of the previous audit entry for this application (or 64 zeros for the first entry). |
| entry_hash       | str  | TEXT NOT NULL                                                                                       | Hex SHA-256 of `prev_hash || application_id || actor_id || actor_role || occurred_at || (previous_status or "") || new_status || reason`, each field length-prefixed by a 4-byte big-endian unsigned int. See research.md for canonical encoding. |

**Structural constraints**:

- `CHECK ((previous_status IS NULL) = (new_status = 'pending'))` — the `previous_status = NULL` case is exactly and only the initial submission event.
- `CHECK (previous_status IS NULL OR previous_status <> new_status)` — no no-op transitions.
- `CREATE INDEX idx_audit_by_application ON audit_entries(application_id, occurred_at, id);` — supports `GET /applications/{id}/audit` (FR-018: ordered chronologically).

**Append-only invariant (FR-018)**: no UPDATE/DELETE code path in `store.py` targets `audit_entries`. `test_invariants.py` includes:

- A **static probe** that grep-checks `store.py` for any SQL string mentioning `UPDATE audit_entries` or `DELETE FROM audit_entries`; the test fails if either is found.
- A **runtime probe** that runs every endpoint as every role and asserts (a) the row count of `audit_entries` is monotonically non-decreasing and (b) no existing row's `entry_hash` changes between snapshots.
- A **tamper probe** that simulates a manual DB tampering (a direct `UPDATE audit_entries SET reason='x' WHERE id=…` from the test harness, bypassing the service), reads the audit endpoint, and asserts `tamper_status == "tampered"`.

**6-year retention (FR-019)**: No public DELETE code path against this table. Operational retention scheduling beyond 6 years is out of scope.

## Entity-relationship diagram

```text
users (1) ─< tokens                                          (auth, v1 stub; OAuth 2.0 introspection in prod)
   │
   │ (1 applicant)        (1 officer, optional after FR-011)
   │
   ├──< loan_applications
   │             │
   │             └──< audit_entries                          (append-only, chained-hash)
   │
   └─ (1 actor) ──────────────────────< audit_entries

officer_rotation (1 row)  ── cursor for round-robin assignment
```

## State machine and audit-entry production

Each successful transition produces exactly one new row in `audit_entries`, inserted in the same DB transaction as the status change (FR-017):

| Transition                       | Trigger                                                                | actor_id                       | actor_role  | previous_status | new_status     |
|----------------------------------|------------------------------------------------------------------------|--------------------------------|-------------|-----------------|----------------|
| `(none)` → `pending`             | `POST /applications`                                                   | the submitting applicant       | `applicant` | `NULL`          | `pending`      |
| `(none)` → `pending` (no officer) | `POST /applications` when officer pool is empty after exclusion       | `"system"`                     | `system`    | `NULL`          | `pending`      |
| `pending` → `under_review`       | `PATCH /applications/{id}/status` `{"status":"under_review",…}`        | the assigned officer           | `officer`   | `pending`       | `under_review` |
| `under_review` → `approved`      | `PATCH /applications/{id}/status` `{"status":"approved",…}`            | the assigned officer           | `officer`   | `under_review`  | `approved`     |
| `under_review` → `rejected`      | `PATCH /applications/{id}/status` `{"status":"rejected",…}`            | the assigned officer           | `officer`   | `under_review`  | `rejected`     |

Any other transition is unreachable: each `UPDATE` in `store.py` filters on the source status, the assigned-officer match, and the not-applicant-of-this-application predicate (FR-013 defence-in-depth).

## Chained-hash structure for the audit log

Let `H(x) = SHA-256(x)` (hex). For the i-th audit entry in chronological order for a given `application_id`:

```text
prev_hash_i  = entry_hash_{i-1}          if i > 0
             = "0000…0000" (64 zeros)    if i == 0

entry_hash_i = H( len_prefixed(prev_hash_i) ||
                  len_prefixed(application_id) ||
                  len_prefixed(actor_id) ||
                  len_prefixed(actor_role) ||
                  len_prefixed(occurred_at) ||
                  len_prefixed(previous_status or "") ||
                  len_prefixed(new_status) ||
                  len_prefixed(reason) )
```

`len_prefixed(s)` prepends a 4-byte big-endian unsigned integer giving the UTF-8 byte length of `s`, then appends those bytes. This unambiguous encoding prevents collisions of the form `"alice" + "bob"` vs `"alicebob" + ""`.

`audit.verify_chain(entries)` walks entries in chronological order, recomputes each `entry_hash`, and asserts equality with the stored value. Any mismatch produces `tamper_status = "tampered"` on the audit-read response. See research.md for what this defends against and what it does not.

## SQL schema (illustrative)

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    display_name TEXT NOT NULL,
    roles TEXT NOT NULL
        CHECK (
            roles IN (
                'applicant', 'officer', 'auditor',
                'applicant,officer', 'applicant,auditor'
            )
        )
);

CREATE TABLE tokens (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    expires_at TEXT NOT NULL
);

CREATE TABLE loan_applications (
    id TEXT PRIMARY KEY,
    applicant_id TEXT NOT NULL REFERENCES users(id),
    amount_minor INTEGER NOT NULL
        CHECK (amount_minor BETWEEN 100000 AND 2500000),
    purpose TEXT NOT NULL
        CHECK (purpose IN ('home_improvement','debt_consolidation','vehicle','education',
                           'medical','wedding','holiday','business','other')),
    status TEXT NOT NULL
        CHECK (status IN ('pending','under_review','approved','rejected')),
    assigned_officer_id TEXT REFERENCES users(id),
    submitted_at TEXT NOT NULL,
    CHECK (assigned_officer_id IS NULL OR assigned_officer_id != applicant_id)
);

CREATE UNIQUE INDEX idx_one_in_flight_per_applicant
    ON loan_applications(applicant_id) WHERE status IN ('pending','under_review');

CREATE TABLE officer_rotation (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    next_position INTEGER NOT NULL CHECK (next_position >= 0)
);
INSERT INTO officer_rotation (id, next_position) VALUES (1, 0);

CREATE TABLE audit_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    application_id TEXT NOT NULL REFERENCES loan_applications(id),
    actor_id TEXT NOT NULL,
    actor_role TEXT NOT NULL
        CHECK (actor_role IN ('applicant','officer','auditor','system')),
    occurred_at TEXT NOT NULL,
    previous_status TEXT
        CHECK (previous_status IN ('pending','under_review','approved','rejected')),
    new_status TEXT NOT NULL
        CHECK (new_status IN ('pending','under_review','approved','rejected')),
    reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 1000),
    prev_hash TEXT NOT NULL,
    entry_hash TEXT NOT NULL,
    CHECK ((previous_status IS NULL) = (new_status = 'pending')),
    CHECK (previous_status IS NULL OR previous_status <> new_status)
);

CREATE INDEX idx_audit_by_application
    ON audit_entries(application_id, occurred_at, id);
```

## How invariants map to storage

| Invariant (from spec)                                                                   | Where enforced                                                                                                                                |
|-----------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------|
| FR-001 / SC-010 OAuth 401 before business logic                                          | `server.py` boundary call to `TokenIntrospector` before dispatch; no handler runs on an unauthenticated request                                |
| FR-002 role multiplicity                                                                | `users.roles` column CHECK constraint forbids the `officer + auditor` combination                                                              |
| FR-007 amount range and purpose list                                                    | Validation + column CHECKs on `amount_minor` and `purpose`                                                                                     |
| FR-008 one in-flight per applicant                                                      | `idx_one_in_flight_per_applicant` partial unique index                                                                                         |
| FR-009 / FR-015 status transitions (no other transitions reachable)                     | Three conditional `UPDATE` statements in `store.py`, each filtering on the source status                                                       |
| FR-010 / FR-011 round-robin assignment, exclude applicant                               | Atomic `BEGIN IMMEDIATE … COMMIT` sequence: SELECT eligible officers excluding the applicant, read+update rotation cursor, INSERT application, INSERT audit |
| FR-011 schema-level no self-assignment                                                  | `CHECK (assigned_officer_id IS NULL OR assigned_officer_id != applicant_id)`                                                                   |
| FR-012 only assigned officer can PATCH (SC-005)                                          | Conditional UPDATE filter `assigned_officer_id = ?` against caller                                                                             |
| FR-013 no self-approval (SC-006)                                                         | Conditional UPDATE filter `applicant_id != ?` against caller + permission-table predicate `application.applicant_id != caller.user_id` for `patch_status_as_assigned_officer` (defence-in-depth)                                                          |
| FR-014 reason required                                                                   | Validation + column CHECK `length(reason) BETWEEN 1 AND 1000`                                                                                  |
| FR-016 audit columns (SC-003)                                                            | `audit_entries` schema enumerates every required column with NOT NULL or NULL-only-for-initial-submission CHECK                                |
| FR-017 audit within 2 s + 503 on breach (SC-002)                                         | Audit INSERT in same transaction as state UPDATE; SQLite connection `timeout=1.8`; `OperationalError` caught and mapped to `503 audit_unavailable`; transaction rolled back automatically                                                                       |
| FR-018 immutability + tamper-detectable (SC-009)                                         | No UPDATE/DELETE code path on `audit_entries`; chained-hash `prev_hash` / `entry_hash`; `audit.verify_chain` runs on every audit read; `test_invariants.py` static + runtime + tamper probes                                                                    |
| FR-019 6-year retention                                                                  | No DELETE code path on `audit_entries`; operational scheduling out of scope                                                                    |
| FR-020 / FR-021 / FR-022 byte-equivalent unauthorised response (SC-004)                  | `responses.not_found_response()` returns a single fixed `(status, headers-without-Date, body_bytes)` tuple used by every unauthorised-read path |
| FR-023 audit endpoint auditor-only                                                      | Permission table: only `{auditor}` callers reach the handler; everyone else gets the byte-equivalent not-found response                       |
| FR-024 applicant cannot modify post-submission                                          | No endpoint allows applicant to mutate any application field; only `POST /applications` (creates new) and `PATCH …/status` (officer-only) exist |

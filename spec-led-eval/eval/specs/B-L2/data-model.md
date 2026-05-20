# Data Model: SaaS Team Task Management with Audit Trail

**Branch**: `007-team-tasks` | **Date**: 2026-05-17

All entities are persisted in SQLite (`sqlite3` stdlib). All identifiers are UUID4 strings. All timestamps are UTC ISO 8601 (`datetime.now(UTC).isoformat()`). Due dates are date-only ISO strings (`YYYY-MM-DD`).

## Enums

### Role

```python
class Role(StrEnum):
    MEMBER = "member"
    ADMIN = "admin"
```

A team membership row has exactly one role. A user may hold different roles in different teams (Q1 = B / FR-007).

### TaskStatus

```python
class TaskStatus(StrEnum):
    TODO = "todo"
    IN_PROGRESS = "in_progress"
    DONE = "done"
```

Free transitions in any direction (FR-013); no state-machine constraint at the schema layer.

## Entities

### User

| Field        | Type | Storage                  | Notes |
|--------------|------|--------------------------|-------|
| id           | str  | TEXT PK                  | UUID4. |
| username     | str  | TEXT UNIQUE NOT NULL     | Human-readable login. |
| display_name | str  | TEXT NOT NULL            | Shown in UI. Renames are allowed at the host product's identity layer; audit entries capture this as a snapshot at the time of each change (FR-015). |

No `role` column on `users` — role is per-team membership (FR-007).

### Token (auth stub)

| Field   | Type | Storage                  | Notes |
|---------|------|--------------------------|-------|
| token   | str  | TEXT PK                  | Opaque string presented in `Authorization: Bearer <token>`. |
| user_id | str  | TEXT NOT NULL FK→users.id | Resolves the token to a user. |

### Team

| Field | Type | Storage              | Notes |
|-------|------|----------------------|-------|
| id    | str  | TEXT PK              | UUID4. Supplied by clients in the `X-Team-Id` header (FR-003). |
| name  | str  | TEXT NOT NULL        | Human-readable team name (shown in error messages? — no; we deliberately avoid echoing team names in 404 responses for the byte-equivalence invariant). |

### TeamMembership

Many-to-many between `users` and `teams`, carrying the user's role in that team.

| Field   | Type | Storage                                                    | Notes |
|---------|------|------------------------------------------------------------|-------|
| user_id | str  | TEXT NOT NULL FK→users.id                                  | Part of composite PK. |
| team_id | str  | TEXT NOT NULL FK→teams.id                                  | Part of composite PK. |
| role    | Role | TEXT CHECK IN ('member','admin') NOT NULL                  | Per-team role (FR-007). |

**Constraints**:

- Composite PK `(user_id, team_id)` — a user can have at most one membership row per team (no duplicate memberships, no per-team multi-role).

### Task

| Field         | Type        | Storage                                                                              | Notes |
|---------------|-------------|--------------------------------------------------------------------------------------|-------|
| id            | str         | TEXT PK                                                                              | UUID4. Opaque identifier (Assumptions). |
| team_id       | str         | TEXT NOT NULL FK→teams.id                                                            | The owning team (FR-005). Immutable after insert (enforced by absence of any UPDATE path that touches this column in `store.py`). |
| title         | str         | TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 200)                                 | Whitespace-trimmed at insert/edit (FR-012). |
| description   | str         | TEXT NOT NULL DEFAULT '' CHECK(length(description) BETWEEN 0 AND 4000)               | Empty string for "no description"; never NULL. |
| due_date      | str \| None | TEXT NULL                                                                            | ISO date `YYYY-MM-DD` or NULL. Past dates allowed (FR-012). |
| assignee_id   | str \| None | TEXT NULL FK→users.id                                                                | Must be a current member of `team_id` at the time of assignment; enforced by validation (FR-012). NULL = unassigned. |
| status        | TaskStatus  | TEXT NOT NULL CHECK(status IN ('todo','in_progress','done'))                         | Initial value `'todo'` on insert (FR-013). |
| owner_id      | str         | TEXT NOT NULL FK→users.id                                                            | The creator (FR-006). Immutable after insert (FR-006: any PATCH attempt that targets this column is rejected with `400 validation_error`). |
| created_at    | str         | TEXT NOT NULL                                                                        | UTC ISO 8601 (FR-009 / FR-017 equivalent). |
| updated_at    | str         | TEXT NOT NULL                                                                        | UTC ISO 8601. Refreshed to `now()` on every successful edit. |

**Indexes**:

- `CREATE INDEX idx_tasks_team_updated ON tasks(team_id, updated_at DESC);` — supports the per-team list ordered by most-recent-update (FR-019).
- `CREATE INDEX idx_tasks_team_status ON tasks(team_id, status);` — supports the status filter (FR-020).
- `CREATE INDEX idx_tasks_team_assignee ON tasks(team_id, assignee_id);` — supports the "mine" / specific-assignee filter.

Every read query MUST include `team_id = ?` in its WHERE clause; this is the structural enforcement of cross-team isolation (FR-014).

**Validation (at `POST /tasks` and `PATCH /tasks/{id}`)** in `validation.py`:

- `title`: trimmed; length [1, 200].
- `description`: length [0, 4000].
- `due_date`: valid ISO `YYYY-MM-DD`, or null.
- `assignee_id`: equals some `users.id` that has a `team_memberships` row for the **current** `team_id`, or null.
- `status` (PATCH only): one of the three statuses. Ignored on POST (always `todo`).
- `owner_id` (PATCH only): **rejected** with a field-level error — owner is immutable (FR-006).

Validation reports **all** offending fields at once.

### AuditEntry

Append-only per-edit-event record (FR-015).

| Field                | Type | Storage                                                                                            | Notes |
|----------------------|------|----------------------------------------------------------------------------------------------------|-------|
| id                   | int  | INTEGER PRIMARY KEY AUTOINCREMENT                                                                  | Monotonic; supports chronological ordering. |
| task_id              | str  | TEXT NOT NULL                                                                                       | The task this entry concerns. **Not FK-constrained** because the task row may be deleted; FR-016 requires audit entries to outlive their task. |
| team_id              | str  | TEXT NOT NULL FK→teams.id                                                                          | The team the task belonged to. Denormalised here so cross-team isolation on the audit endpoint is a single `WHERE team_id = ?` clause without joining the (possibly deleted) `tasks` row. |
| actor_user_id        | str  | TEXT NOT NULL FK→users.id                                                                          | The user who caused the change. |
| actor_display_name   | str  | TEXT NOT NULL                                                                                       | The actor's display name at the time of the change (snapshot, FR-015). |
| actor_role           | Role | TEXT NOT NULL CHECK(actor_role IN ('member','admin'))                                              | The actor's role at the time of the change (snapshot, FR-015). |
| occurred_at          | str  | TEXT NOT NULL                                                                                       | UTC ISO 8601. |
| change_description   | str  | TEXT NOT NULL CHECK(length(change_description) BETWEEN 1 AND 500)                                  | One of three shapes: `"created"`, `"changed <field>[, <field>]*"`, `"deleted"`. Length cap is a defensive backstop; the legal values are far shorter. |

**Structural constraints / indexes**:

- `CREATE INDEX idx_audit_by_task ON audit_entries(task_id, occurred_at, id);` — chronological ordering per task (FR-017).
- `CREATE INDEX idx_audit_by_team ON audit_entries(team_id);` — supports cross-team isolation on the audit endpoint (FR-014, FR-017).

**Append-only at two layers**:

- **Code layer**: no UPDATE/DELETE SQL statement in `store.py` targets `audit_entries`. A static probe in `test_invariants.py` greps `store.py` for `UPDATE audit_entries` / `DELETE FROM audit_entries` and fails if either is found.
- **Runtime layer**: a probe in `test_invariants.py` runs every endpoint as every role and asserts no existing audit row's content changes between snapshots, and that the row count never decreases.

**12-month retention (FR-018)**: satisfied by the absence of any DELETE code path against `audit_entries`. Tamper detection beyond append-only is out of scope (see feature 005 for the chained-hash pattern).

## Entity-relationship diagram

```text
users (1) ─< tokens                                     (auth stub)
   │
   │ (many-to-many via team_memberships)
   │
teams (1) ─< team_memberships >─ users
   │
   │ (1 team owns many tasks)
   │
   └──< tasks
            │
            │ (1 task has many audit entries; entries outlive the task)
            │
            └──< audit_entries
```

## How a request resolves the team and role

```text
   ┌─────────────────────────────────────────────────┐
   │ HTTP request                                    │
   │ Authorization: Bearer <token>                   │
   │ X-Team-Id: <team_id>                            │
   └─────────────────────────────────────────────────┘
                      │
                      ▼
   ┌─────────────────────────────────────────────────┐
   │ server.py boundary                              │
   │ 1. Resolve token → user_id    (else 401)        │
   │ 2. Check X-Team-Id present    (else 400)        │
   │ 3. Look up (user_id, team_id) in team_memberships│
   │    └─ row exists → role = members.role          │
   │    └─ no row     → 404 (byte-equivalent)        │
   └─────────────────────────────────────────────────┘
                      │
                      ▼
   ┌─────────────────────────────────────────────────┐
   │ handler runs with (user_id, team_id, role)      │
   └─────────────────────────────────────────────────┘
```

## SQL schema (illustrative)

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    display_name TEXT NOT NULL
);

CREATE TABLE tokens (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id)
);

CREATE TABLE teams (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL
);

CREATE TABLE team_memberships (
    user_id TEXT NOT NULL REFERENCES users(id),
    team_id TEXT NOT NULL REFERENCES teams(id),
    role TEXT NOT NULL CHECK (role IN ('member','admin')),
    PRIMARY KEY (user_id, team_id)
);

CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    team_id TEXT NOT NULL REFERENCES teams(id),
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    description TEXT NOT NULL DEFAULT ''
        CHECK (length(description) BETWEEN 0 AND 4000),
    due_date TEXT,
    assignee_id TEXT REFERENCES users(id),
    status TEXT NOT NULL CHECK (status IN ('todo','in_progress','done')),
    owner_id TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX idx_tasks_team_updated ON tasks(team_id, updated_at DESC);
CREATE INDEX idx_tasks_team_status ON tasks(team_id, status);
CREATE INDEX idx_tasks_team_assignee ON tasks(team_id, assignee_id);

CREATE TABLE audit_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL,
    team_id TEXT NOT NULL REFERENCES teams(id),
    actor_user_id TEXT NOT NULL REFERENCES users(id),
    actor_display_name TEXT NOT NULL,
    actor_role TEXT NOT NULL CHECK (actor_role IN ('member','admin')),
    occurred_at TEXT NOT NULL,
    change_description TEXT NOT NULL
        CHECK (length(change_description) BETWEEN 1 AND 500)
);

CREATE INDEX idx_audit_by_task ON audit_entries(task_id, occurred_at, id);
CREATE INDEX idx_audit_by_team ON audit_entries(team_id);
```

## How invariants map to storage

| Invariant (from spec)                                                       | Where enforced                                                                                                                                  |
|-----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| FR-001 authentication                                                       | `server.py` boundary: bearer-token resolution via `tokens` table.                                                                              |
| FR-003 / FR-004 team context resolution                                     | `server.py` boundary: `X-Team-Id` parsed; `(user_id, team_id)` looked up in `team_memberships`; missing → 400; non-member → 404 (byte-equivalent). |
| FR-005 task team immutability                                               | No SQL path in `store.py` ever UPDATEs `tasks.team_id`.                                                                                         |
| FR-006 owner immutability                                                   | Validation rejects any PATCH body that includes `owner_id`; no SQL path in `store.py` UPDATEs `tasks.owner_id`.                                  |
| FR-007 per-team role                                                        | `team_memberships.role` column with composite PK on `(user_id, team_id)`.                                                                       |
| FR-008 / FR-009 / FR-010 owner-or-admin edit/delete                          | Permission table: `task.owner_id == caller.user_id OR caller.role == 'admin'` predicate on `edit_task` and `delete_task`.                       |
| FR-011 / FR-014 cross-team isolation (SC-004)                                | Every read query includes `WHERE team_id = ?` (the caller's `X-Team-Id` team). `team_id` mismatch → service returns `None` → handler converts to `not_found_response()` (byte-equivalent body). |
| FR-012 amount range and purpose list                                        | n/a — different invariant; covered by the title/description/due_date validation rules.                                                          |
| FR-013 status set + free transitions                                        | Column CHECK constraint on `status`; no state-machine UPDATE filter.                                                                            |
| FR-015 per-edit-event audit shape (SC-007)                                  | `audit_entries` schema enumerates each required column with NOT NULL or CHECK; the change-description shape is enforced by `service.py` (string assembly) and a runtime test that walks every endpoint and asserts one of the three legal shapes.                |
| FR-015 actor display name + role snapshot                                   | `audit_entries.actor_display_name` and `audit_entries.actor_role` are captured at INSERT time; never UPDATEd.                                   |
| FR-016 audit append-only (SC-008)                                           | No UPDATE/DELETE code path on `audit_entries`; deletion of a task removes the `tasks` row but `audit_entries` rows persist (no ON DELETE CASCADE; the FK constraint is absent on `audit_entries.task_id` for exactly this reason).                                |
| FR-017 audit readable by any team-T member                                  | Permission table: `view_audit` requires `member` role and `task.team_id == caller.team_id` predicate; non-member of T → byte-equivalent 404.    |
| FR-018 ≥12-month retention                                                  | No DELETE code path against `audit_entries`. Operational retention policy is out of scope.                                                      |
| FR-019 / FR-020 list with filters (most-recently-updated-first)             | Single SQL WHERE-clause built from query params + `ORDER BY updated_at DESC`; index `idx_tasks_team_updated`.                                    |
| SC-005 only owner-or-admin can edit/delete                                  | Permission-table predicate + an automated probe in `test_permissions.py` that walks (member-non-owner, member-owner, admin-non-owner) × (edit, delete) and asserts the correct allow/deny matrix.                                                                 |
| SC-006 zero unauthenticated requests reach business logic                   | Auth + team-context boundary in `server.py` before dispatch; `test_auth.py` probe.                                                              |

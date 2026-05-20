# Data Model: Team Task Management

**Branch**: `006-task-management` | **Date**: 2026-05-17

All entities are persisted in SQLite (`sqlite3` stdlib). All identifiers are UUID4 strings. All timestamps are UTC ISO 8601 (`datetime.now(UTC).isoformat()`). Due dates are date-only ISO strings (`YYYY-MM-DD`).

## Enums

### TaskStatus

```python
class TaskStatus(StrEnum):
    TODO = "todo"
    IN_PROGRESS = "in_progress"
    DONE = "done"
```

Stored as `TEXT CHECK IN ('todo','in_progress','done') NOT NULL`. Any of the three may transition to any of the others (no source-status filter, no state machine constraint beyond the closed-task PATCH rule which lives at the edit layer, not the schema layer).

## Entities

### Member (User)

A person who can sign in to the workspace. The single implicit workspace (Q2 = A) means every row in `users` is a member; there is no `Team` entity.

| Field        | Type | Storage                  | Notes |
|--------------|------|--------------------------|-------|
| id           | str  | TEXT PK                  | UUID4. |
| username     | str  | TEXT UNIQUE NOT NULL     | Human-readable login. |
| display_name | str  | TEXT NOT NULL            | Shown in the UI as "Assigned to: <display_name>" and "Created by: <display_name>". |

No `role` column (Q3 = A — flat peers). No password / credential field — auth is the bearer-token stub against the `tokens` table.

### Token (auth stub)

| Field   | Type | Storage                  | Notes |
|---------|------|--------------------------|-------|
| token   | str  | TEXT PK                  | Opaque string presented in `Authorization: Bearer <token>`. |
| user_id | str  | TEXT NOT NULL FK→users.id | Resolves the token to a user. |

### Task

A single unit of work.

| Field         | Type        | Storage                                                                              | Notes |
|---------------|-------------|--------------------------------------------------------------------------------------|-------|
| id            | str         | TEXT PK                                                                              | UUID4. |
| title         | str         | TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 200)                                 | Trimmed at insert/edit; structural backstop for FR-005. |
| description   | str         | TEXT NOT NULL DEFAULT '' CHECK(length(description) BETWEEN 0 AND 4000)               | Empty string for "no description"; never NULL, so callers don't have to special-case it. |
| due_date      | str \| None | TEXT NULL                                                                            | ISO date `YYYY-MM-DD` or NULL. Past dates allowed (FR-007). |
| assignee_id   | str \| None | TEXT NULL FK→users.id                                                                | Current member at the time of assignment (FR-008); NULL if unassigned. |
| status        | TaskStatus  | TEXT NOT NULL CHECK(status IN ('todo','in_progress','done'))                          | Initial value `'todo'` on insert. |
| created_by    | str         | TEXT NOT NULL FK→users.id                                                            | The creator (FR-009); never changes after insert. |
| created_at    | str         | TEXT NOT NULL                                                                        | UTC ISO 8601 (FR-009, FR-017). |
| updated_at    | str         | TEXT NOT NULL                                                                        | UTC ISO 8601. Refreshed to `now()` on every successful edit (FR-017). |

**Indexes**:

- `CREATE INDEX idx_tasks_by_updated ON tasks(updated_at DESC);` — supports the default list ordering (FR-014).
- `CREATE INDEX idx_tasks_by_assignee ON tasks(assignee_id);` — supports the "mine" / specific-user filter (FR-015).
- `CREATE INDEX idx_tasks_by_status ON tasks(status);` — supports the status filter (FR-015).

**Validation (at `POST /tasks` and `PATCH /tasks/{id}`)** in `validation.py`:

- `title` (when present): trim whitespace; resulting length in [1, 200].
- `description` (when present): length in [0, 4000].
- `due_date` (when present): valid ISO date `YYYY-MM-DD`, or `null` (which clears it).
- `assignee_id` (when present): a string equal to an existing `users.id`, or `null` (which unassigns).
- `status` (when present, PATCH only): one of `todo`, `in_progress`, `done`. Ignored on POST (always `todo`).

Validation reports **all** offending fields at once (not fail-fast), consistent with the rest of the repo.

### TaskDeletion (operational log)

Append-only record of every deletion (FR-018). Has no API endpoint; inspected by operators via direct DB access.

| Field                | Type | Storage                              | Notes |
|----------------------|------|--------------------------------------|-------|
| id                   | int  | INTEGER PRIMARY KEY AUTOINCREMENT    | |
| task_id              | str  | TEXT NOT NULL                        | The deleted task's UUID. Not FK-constrained because the task row has been removed by the time this is written. |
| task_title_at_delete | str  | TEXT NOT NULL                        | The task's title at the moment of deletion (FR-018). |
| deleted_by_user_id   | str  | TEXT NOT NULL FK→users.id            | The deleter's identity. |
| deleted_at           | str  | TEXT NOT NULL                        | UTC ISO 8601. |

No UPDATE/DELETE code path targets this table. There is no in-app endpoint to read it.

## Entity-relationship diagram

```text
users (1) ─< tokens                                  (auth stub)
   │
   │ (creator)        (assignee, optional)
   │
   ├──< tasks                                       (single workspace; every user is a member)
   │
   └─< task_deletions                                (operational log; no API exposure)
```

There is no `Team` / `Workspace` entity, no `Role` enum, no `permissions` table.

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

CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    description TEXT NOT NULL DEFAULT ''
        CHECK (length(description) BETWEEN 0 AND 4000),
    due_date TEXT,
    assignee_id TEXT REFERENCES users(id),
    status TEXT NOT NULL CHECK (status IN ('todo','in_progress','done')),
    created_by TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX idx_tasks_by_updated ON tasks(updated_at DESC);
CREATE INDEX idx_tasks_by_assignee ON tasks(assignee_id);
CREATE INDEX idx_tasks_by_status ON tasks(status);

CREATE TABLE task_deletions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL,
    task_title_at_delete TEXT NOT NULL,
    deleted_by_user_id TEXT NOT NULL REFERENCES users(id),
    deleted_at TEXT NOT NULL
);
```

## How invariants map to storage

| Invariant (from spec)                                                              | Where enforced                                                                                                                                  |
|------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| FR-001 authentication                                                              | `server.py` boundary check; no handler runs on an unauthenticated request. Stub introspector against `tokens`.                                  |
| FR-003 single implicit workspace                                                   | Absence of a `teams` table; every authenticated user is a member by virtue of having a `users` row.                                              |
| FR-004 flat permissions                                                            | Absence of `permissions.py`; only check is "is the caller authenticated".                                                                       |
| FR-005 title 1–200, whitespace-trimmed                                              | Validation + column CHECK `length(title) BETWEEN 1 AND 200`.                                                                                    |
| FR-006 description 0–4000                                                          | Validation + column CHECK on `length(description)`.                                                                                             |
| FR-007 due date date-only, past allowed                                            | Validation parses ISO date format; no past-date rejection.                                                                                      |
| FR-008 assignee is current member                                                  | Validation verifies `assignee_id` exists in `users`; FK constraint catches the race where a user is deleted between validation and insert.       |
| FR-010 status set + free transitions                                               | Column CHECK constraint on `status`; no state-machine UPDATE filter (any status can transition to any other).                                    |
| FR-011 closed-task edit rule                                                       | Service layer: PATCH on a `done` task requires the body to set `status` to `todo` or `in_progress` in the same request, else `409 task_closed`. |
| FR-012 permanent deletion                                                          | `DELETE FROM tasks WHERE id = ?` (hard delete) + INSERT into `task_deletions` in the same transaction.                                          |
| FR-013 v1 manage scope is exactly FR-005…FR-012                                    | Endpoint surface enumerated in `contracts/http-api.md`; no comment/attachment/tag/subtask endpoints exist.                                       |
| FR-014 list orders most-recently-updated first                                     | `ORDER BY updated_at DESC` in `service.list_tasks`; index `idx_tasks_by_updated`.                                                              |
| FR-015 filter by status / assignee / title substring (AND)                         | Single SQL WHERE-clause built from the query parameters.                                                                                        |
| FR-017 created_at + updated_at semantics                                           | INSERT sets both to `now()`; every UPDATE sets `updated_at` to `now()`; `created_at` is never UPDATEd.                                          |
| FR-018 operational deletion log                                                    | `task_deletions` table; INSERT happens in the same transaction as the `DELETE FROM tasks`.                                                      |
| SC-005 zero unauthenticated requests succeed                                       | Auth boundary in `server.py`; tests in `test_auth.py` and `test_invariants.py`.                                                                 |
| SC-006 100% of tasks have valid timestamps + status                                | Column NOT NULL / CHECK constraints; integration tests sample stored rows.                                                                      |

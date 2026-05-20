# Data Model: Multi-Tenant Task Management with Per-Task Sharing and Audit

**Branch**: `008-task-sharing` | **Date**: 2026-05-17

All entities are persisted in SQLite (`sqlite3` stdlib) in WAL mode. All identifiers are UUID4 strings. All timestamps are UTC ISO 8601 with millisecond precision and `Z` suffix. Due dates are date-only ISO strings (`YYYY-MM-DD`).

## Enums

### Role

```python
class Role(StrEnum):
    MEMBER = "member"
    TEAM_ADMIN = "team_admin"
```

Read from the OAuth introspection claim, never from the request payload (FR-002, FR-002a, SC-006).

### TaskStatus

```python
class TaskStatus(StrEnum):
    TODO = "todo"
    IN_PROGRESS = "in_progress"
    DONE = "done"
```

Free transitions in any direction (FR-008).

### AuditOperation

```python
class AuditOperation(StrEnum):
    CREATED = "created"
    EDITED = "edited"
    DELETED = "deleted"
    SHARED = "shared"
    UNSHARED = "unshared"
```

One value per logical event (FR-015). A single `PATCH` request producing field changes and share changes emits multiple audit entries with different `operation` values.

### Relationship (computed, not persisted)

```python
class Relationship(StrEnum):
    OUTSIDER = "outsider"            # cross-team → 404 byte-equivalent
    IN_TEAM_NONE = "in_team_none"    # in same team but not owner / sharee / admin → 404 byte-equivalent
    SHAREE = "sharee"
    TEAM_ADMIN = "team_admin"
    OWNER = "owner"
```

Computed by `permissions.relationship(caller, task)` and fed into the action-allow check. See research.md for the full action × relationship matrix.

## Entities

### User

Read from OAuth claims; not modified by this feature.

| Field        | Type | Storage                  | Notes |
|--------------|------|--------------------------|-------|
| id           | str  | TEXT PK                  | UUID4. |
| display_name | str  | TEXT NOT NULL            | For audit-entry rendering. |
| team_id      | str  | TEXT NOT NULL FK→teams.id | The user's single team (FR-002 — one team per user in v1). |
| role         | Role | TEXT CHECK IN ('member','team_admin') NOT NULL | Per-user role within their team. |

In v1 the table is seeded; in production it would be a read-only mirror of the host product's identity system or be eliminated entirely (with all user data sourced from token introspection on each request). For the PoC, the seeded `users` table is convenient for joining on `display_name` in audit-entry rendering.

### Token (auth stub for v1)

| Field      | Type | Storage                              | Notes |
|------------|------|--------------------------------------|-------|
| token      | str  | TEXT PK                              | Opaque bearer token. |
| user_id    | str  | TEXT NOT NULL FK→users.id             | Resolves to a user, and via the user to a team and role. |
| expires_at | str  | TEXT NOT NULL                        | UTC ISO 8601. |

The `StubIntrospector` returns `None` for unknown tokens, expired tokens, or tokens whose `user.team_id` / `user.role` are absent. In production this table is replaced by an RFC 7662 introspection endpoint behind the same `TokenIntrospector` Protocol.

### Team

| Field | Type | Storage              | Notes |
|-------|------|----------------------|-------|
| id    | str  | TEXT PK              | UUID4. |
| name  | str  | TEXT NOT NULL        | Not exposed in 404 responses (byte-equivalence). |

### Task

| Field         | Type        | Storage                                                                              | Notes |
|---------------|-------------|--------------------------------------------------------------------------------------|-------|
| id            | str         | TEXT PK                                                                              | UUID4. |
| team_id       | str         | TEXT NOT NULL FK→teams.id                                                            | Immutable (FR-009). Every read query includes `team_id = ?`. |
| owner_id      | str         | TEXT NOT NULL FK→users.id                                                            | Immutable (FR-009). The creator. |
| title         | str         | TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 200)                                 | Whitespace-trimmed at insert/edit. |
| description   | str         | TEXT NOT NULL DEFAULT '' CHECK(length(description) BETWEEN 0 AND 4000)               | Never NULL. |
| due_date      | str \| None | TEXT NULL                                                                            | ISO date or NULL. |
| status        | TaskStatus  | TEXT NOT NULL CHECK(status IN ('todo','in_progress','done'))                         | Initial `'todo'`. |
| created_at    | str         | TEXT NOT NULL                                                                        | UTC ISO 8601. |
| updated_at    | str         | TEXT NOT NULL                                                                        | UTC ISO 8601. Refreshed on every successful PATCH. |

`shared_with` is **not** a column on `tasks`. It is normalised into the `task_shares` junction table (see below).

**Indexes**:

- `CREATE INDEX idx_tasks_team_id ON tasks(team_id);` — supports cross-team isolation queries.
- `CREATE INDEX idx_tasks_owner ON tasks(team_id, owner_id);` — supports "tasks I own" probes.

### TaskShare

The (task, sharee) junction.

| Field            | Type | Storage                                                                | Notes |
|------------------|------|------------------------------------------------------------------------|-------|
| task_id          | str  | TEXT NOT NULL FK→tasks.id ON DELETE CASCADE                            | Part of composite PK. Cascade so that DELETE of a task removes its share rows in one statement. |
| sharee_user_id   | str  | TEXT NOT NULL FK→users.id                                              | Part of composite PK. |
| created_at       | str  | TEXT NOT NULL                                                          | UTC ISO 8601. When the share was created. |

**Composite PK**: `(task_id, sharee_user_id)` — a user cannot be shared the same task twice (idempotent share).

**Indexes**:

- `CREATE INDEX idx_shares_by_sharee ON task_shares(sharee_user_id);` — supports "is this user a sharee on task X?" with the join via `task_id`.

**FK behaviour**: `ON DELETE CASCADE` on `task_id` so a task DELETE in one statement removes all share rows. The `audit_entries` table is **not** FK-constrained to `tasks` (so audit entries outlive the task per FR-017).

### AuditEntry

Append-only per-event record (FR-015, FR-017).

| Field                | Type           | Storage                                                                                  | Notes |
|----------------------|----------------|------------------------------------------------------------------------------------------|-------|
| id                   | int            | INTEGER PRIMARY KEY AUTOINCREMENT                                                        | Monotonic; chronological ordering. |
| task_id              | str            | TEXT NOT NULL                                                                            | **Not FK-constrained** — audit entries outlive the task (FR-017). |
| team_id              | str            | TEXT NOT NULL FK→teams.id                                                                | Denormalised from the task at write time, so cross-team isolation on the audit endpoint is a single `WHERE team_id = ?` clause without joining the (possibly deleted) `tasks` row. |
| actor_user_id        | str            | TEXT NOT NULL FK→users.id                                                                | The acting user. |
| actor_role           | Role           | TEXT NOT NULL CHECK(actor_role IN ('member','team_admin'))                               | Snapshotted from the `AuthenticatedCaller` at the time of the change (FR-016). |
| occurred_at          | str            | TEXT NOT NULL                                                                            | UTC ISO 8601 with millisecond precision and `Z` suffix. |
| operation            | AuditOperation | TEXT NOT NULL CHECK(operation IN ('created','edited','deleted','shared','unshared'))     | Exactly one event type per row. |
| diff_summary         | str            | TEXT NOT NULL CHECK(length(diff_summary) <= 200)                                         | Field-name-list per FR-016 / Q2 = A. Length cap is a defensive backstop. |

**Indexes**:

- `CREATE INDEX idx_audit_by_task ON audit_entries(task_id, id);` — chronological retrieval of a task's audit trail (FR-019).
- `CREATE INDEX idx_audit_by_team ON audit_entries(team_id);` — supports cross-team isolation on the audit endpoint.

**Append-only**: no UPDATE/DELETE SQL targets `audit_entries` in `store.py`. Static probe in `test_invariants.py`. Runtime probe samples row hashes across consecutive snapshots.

## Entity-relationship diagram

```text
teams (1) ─< users
              │
              ├──< tokens         (auth stub)
              │
              │ (1 owner)            (sharee, many)
              │
              ├──< tasks ─── (1 many) ─── task_shares
              │      │                         │
              │      │                         └── (sharee_user_id) FK→ users
              │      │
              │      │ (1 task, many audit rows; audit rows outlive task)
              │      │
              │      └──< audit_entries
              │
              └─ (actor_user_id) ──< audit_entries
```

## The PATCH → audit-entries decomposition (the core of FR-015 / FR-016)

A single `PATCH /tasks/{id}` request can produce **zero** to **many** audit entries:

```text
PATCH body                                              # audit entries
──────────────────────────────────────────────────────  ──────────────
{}                                                       0  (200 OK, no-op)
{title: <same>}                                          0  (no diff)
{title: <new>}                                           1  edited [title]
{title: <new>, status: <new>}                            1  edited [title, status]
{shared_with: [...existing + new1, new2]}                2  shared sharee=new1; shared sharee=new2
{shared_with: [...existing - removed1]}                  1  unshared sharee=removed1
{title: <new>, shared_with: [...existing + new1]}        2  edited [title]; shared sharee=new1
{shared_with: [], <all-old-sharees-removed>}             N  unshared per former sharee
```

The decomposition rule (in `service.update_task`):

1. Validate the body.
2. Load the current task + current share set.
3. Compute the field-diff (excluding `shared_with`): if non-empty → emit one `edited` event with the field-name list as `diff_summary`.
4. Compute the share-set diff: for each newly-added user_id → one `shared` event; for each removed user_id → one `unshared` event.
5. If the union is empty → return 200 OK with the unchanged task; write **no** audit entries.
6. Otherwise, in a single `BEGIN IMMEDIATE … COMMIT`:
   - UPDATE the task row (set the changed fields + `updated_at`).
   - INSERT into `task_shares` for each added sharee; DELETE from `task_shares` for each removed sharee.
   - INSERT one audit row per logical event.
   - COMMIT.
7. If the COMMIT exceeds the 800 ms timeout → roll back, return `503 audit_unavailable` (FR-018).

## SQL schema (illustrative)

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 134217728;

CREATE TABLE teams (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL
);

CREATE TABLE users (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    team_id TEXT NOT NULL REFERENCES teams(id),
    role TEXT NOT NULL CHECK (role IN ('member','team_admin'))
);

CREATE TABLE tokens (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    expires_at TEXT NOT NULL
);

CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    team_id TEXT NOT NULL REFERENCES teams(id),
    owner_id TEXT NOT NULL REFERENCES users(id),
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    description TEXT NOT NULL DEFAULT ''
        CHECK (length(description) BETWEEN 0 AND 4000),
    due_date TEXT,
    status TEXT NOT NULL CHECK (status IN ('todo','in_progress','done')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX idx_tasks_team_id ON tasks(team_id);
CREATE INDEX idx_tasks_owner ON tasks(team_id, owner_id);

CREATE TABLE task_shares (
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    sharee_user_id TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL,
    PRIMARY KEY (task_id, sharee_user_id)
);

CREATE INDEX idx_shares_by_sharee ON task_shares(sharee_user_id);

CREATE TABLE audit_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL,
    team_id TEXT NOT NULL REFERENCES teams(id),
    actor_user_id TEXT NOT NULL REFERENCES users(id),
    actor_role TEXT NOT NULL CHECK (actor_role IN ('member','team_admin')),
    occurred_at TEXT NOT NULL,
    operation TEXT NOT NULL
        CHECK (operation IN ('created','edited','deleted','shared','unshared')),
    diff_summary TEXT NOT NULL CHECK (length(diff_summary) <= 200)
);

CREATE INDEX idx_audit_by_task ON audit_entries(task_id, id);
CREATE INDEX idx_audit_by_team ON audit_entries(team_id);
```

## How invariants map to storage

| Invariant (from spec)                                                       | Where enforced                                                                                                                                |
|-----------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| FR-001 / SC-005 OAuth-401-before-business-logic                              | `server.py` boundary: `TokenIntrospector.introspect` runs before dispatch.                                                                    |
| FR-002 / FR-002a / SC-006 team_id and role from token only                   | `AuthenticatedCaller` is built from introspection result; handlers never read `team_id`/`role` from the body. Static probe checks for absence of body-keyed reads. |
| FR-006 / FR-014 / SC-003 cross-team isolation byte-equivalent                | Every read query includes `WHERE team_id = ?`. `responses.not_found_response()` returns identical bytes for every "you can't see this" case.   |
| FR-009 task team_id and owner_id immutable                                  | No SQL path UPDATEs these columns.                                                                                                            |
| FR-010 / FR-011 owner-only share control + sharee permission set            | `permissions.is_allowed` predicate; `change_shared_with` allowed only when `relationship == OWNER`.                                            |
| FR-012 cross-team sharing forbidden                                         | `service.update_shared_with` validates each new sharee `user_id` is in the same team as the task owner; otherwise `400 validation_error`.     |
| FR-013 share/unshare audit entries                                          | The PATCH → audit-entries decomposition rule (see above).                                                                                     |
| FR-015 / FR-016 per-event audit semantics + field-name-list diff_summary    | `service.update_task` builds the field-name-list diff_summary and the per-event audit rows.                                                   |
| FR-017 audit immutable + outlives task (SC-007, SC-009)                      | No UPDATE/DELETE SQL on `audit_entries`. No FK to `tasks` on `audit_entries.task_id`. Static + runtime probes in `test_invariants.py`.        |
| FR-018 / SC-008 1-second audit SLA                                           | All audit INSERTs in the same transaction as the task mutation; SQLite connection `timeout=0.8`; `OperationalError` → `503 audit_unavailable`. |
| FR-019 audit readable by owner / sharee / admin                              | `permissions.is_allowed('view_audit', task)` uses the same `relationship` computation as `view_task`.                                          |
| FR-020 ≥12-month retention                                                  | No DELETE code path against `audit_entries`. Operational retention scheduling is out of scope.                                                |
| FR-021 / SC-010 200 req/s @ p99 ≤ 300 ms                                     | WAL mode + PRAGMA tuning + indexed read paths. Documented in research.md with throughput analysis.                                              |
| SC-011 only owner can change shared_with                                    | `permissions.is_allowed('change_shared_with', task)` returns `False` for any relationship other than `OWNER`. Tested across the matrix.        |

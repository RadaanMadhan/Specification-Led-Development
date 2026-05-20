# Quickstart: Multi-Tenant Task Management with Per-Task Sharing and Audit

**Branch**: `008-task-sharing` | **Date**: 2026-05-17

## Prerequisites

- Python 3.11 or later
- macOS or Linux
- No third-party packages are required at runtime (Constitution Principle I).

## Install (development)

From the repository root:

```bash
pip install -e .[dev]
```

`[dev]` only pulls in `pytest` and `ruff` for testing and linting; the runtime is stdlib-only.

## Run the server

```bash
python -m task_sharing.server --seed --port 8086 --db-path ./task_sharing.db
```

Flags:

| Flag        | Default              | Meaning                                                                                                                                                  |
|-------------|----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--port`    | `8086`               | TCP port to bind on `127.0.0.1`. Differs from 002–007 so all packages can run side by side locally.                                                       |
| `--db-path` | `./task_sharing.db`  | SQLite file. Use `:memory:` for an ephemeral run. WAL mode is enabled at startup regardless of the path.                                                  |
| `--seed`    | off                  | If set, seed two teams, six users (mix of members and team admins, including a cross-team probe outsider), bearer tokens, and a handful of tasks with various ownership and sharing configurations. |
| `--json`    | off                  | When combined with `--seed`, emit the seeded fixture as JSON on stdout instead of the human-readable table.                                              |
| `--help`    | —                    | Human-readable usage on stdout.                                                                                                                           |

The server applies the following SQLite PRAGMAs at startup: `journal_mode = WAL`, `synchronous = NORMAL`, `temp_store = MEMORY`, `mmap_size = 128 MiB`. The connection timeout is `0.8` seconds so contended writes fail fast within the FR-018 1-second budget.

Errors print to stderr.

## Seeded fixture

`--seed` produces a deterministic fixture (same UUIDs, same tokens every run):

**Teams**:

| Team id   | Name                |
|-----------|---------------------|
| `team-T`  | Acme Engineering    |
| `team-U`  | Acme Marketing      |

**Users**:

| Username     | Token            | Display name      | Team    | Role         |
|--------------|------------------|-------------------|---------|--------------|
| `alice`      | `tkn-alice`      | Alice Member      | `team-T`| `member`     |
| `brenda`     | `tkn-brenda`     | Brenda Admin      | `team-T`| `team_admin` |
| `carol`      | `tkn-carol`      | Carol Member      | `team-T`| `member`     |
| `dan`        | `tkn-dan`        | Dan Member        | `team-U`| `member`     |
| `evan`       | `tkn-evan`       | Evan Admin        | `team-U`| `team_admin` |
| `frances`    | `tkn-frances`    | Frances Member    | `team-T`| `member`     |

Note that all bearer tokens carry the `team_id` and `role` claims for their user (per FR-002a). Forging a different `team_id` in the request body would be ignored (and is asserted to be ignored by `test_oauth.py`).

**Tasks**:

| Task id       | Team    | Owner   | Title                       | Shared with        | Status         |
|---------------|---------|---------|-----------------------------|--------------------|----------------|
| `task-T-001`  | team-T  | `alice` | `Write release notes`       | `carol`            | `in_progress`  |
| `task-T-002`  | team-T  | `alice` | `Triage support backlog`    | (none)             | `todo`         |
| `task-T-003`  | team-T  | `frances` | `Recruit junior engineer` | (none)             | `todo`         |
| `task-U-001`  | team-U  | `dan`   | `Plan Q3 launch campaign`   | (none)             | `todo`         |

## Smoke test — end-to-end happy path

These commands assume the seeded server is running on `:8086`.

### 1. Alice creates a private task (US1)

```bash
curl -sS -X POST http://127.0.0.1:8086/tasks \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "title": "Refresh README", "description": "2026 update.", "due_date": "2026-05-31" }'
```

Expected: `201 Created`, fresh `id`, `team_id: "team-T"`, `owner_id: <alice-uuid>`, `shared_with: []`, `status: "todo"`. Audit endpoint shows one entry with `operation: "created"`, `diff_summary: "title, description, due_date"`.

### 2. Carol (in same team, no rel) tries to view task-T-002 (FR-004, byte-equivalent 404)

```bash
curl -sS -i http://127.0.0.1:8086/tasks/task-T-002 \
  -H 'Authorization: Bearer tkn-carol'
```

Expected: `404 Not Found`, body `{"error":"not_found","message":"No such task."}`, `Content-Length: 53`. Byte-identical to a fabricated id.

### 3. Carol (sharee on task-T-001) views it successfully (US3)

```bash
curl -sS http://127.0.0.1:8086/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-carol'
```

Expected: `200 OK`, full task body including `shared_with: ["<carol-uuid>"]`.

### 4. Carol edits task-T-001's status (Q3 = B, FR-011)

```bash
curl -sS -X PATCH http://127.0.0.1:8086/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-carol' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "done" }'
```

Expected: `200 OK`, `status: "done"`, `updated_at` refreshed. New audit entry with `operation: "edited"`, `diff_summary: "status"`, `actor_user_id: <carol-uuid>`, `actor_role: "member"`.

### 5. Carol tries to delete task-T-001 (Q3 = B, FR-011 — byte-equivalent 404)

```bash
curl -sS -i -X DELETE http://127.0.0.1:8086/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-carol'
```

Expected: `404 Not Found` byte-equivalent. Task unchanged. **No audit entry written.**

### 6. Carol tries to change shared_with (FR-010, Q1 = A — 400 validation_error)

```bash
curl -sS -i -X PATCH http://127.0.0.1:8086/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-carol' \
  -H 'Content-Type: application/json' \
  -d '{ "shared_with": ["<frances-uuid>"] }'
```

Expected: `400 validation_error`, `field_errors` lists `shared_with` with message "Only the task owner can change the share list." Task unchanged. No audit entry.

### 7. Alice combines a field edit and a share addition in one PATCH (FR-015 multi-event)

```bash
curl -sS -X PATCH http://127.0.0.1:8086/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "title": "Write release notes v2", "shared_with": ["<carol-uuid>", "<frances-uuid>"] }'
```

Expected: `200 OK`. The audit endpoint now shows **two new entries**:
- `operation: "edited"`, `diff_summary: "title"` (the field change).
- `operation: "shared"`, `diff_summary: "sharee=<frances-uuid>"` (the new sharee).

Carol was already a sharee, so no extra share event for her. Both entries share the same `occurred_at` (they're in the same transaction).

### 8. Brenda (team admin) edits task-T-003 (FR-005)

```bash
curl -sS -X PATCH http://127.0.0.1:8086/tasks/task-T-003 \
  -H 'Authorization: Bearer tkn-brenda' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "in_progress", "description": "Picking up for review." }'
```

Expected: `200 OK`. Audit entry with `actor_role: "team_admin"`, `operation: "edited"`, `diff_summary: "description, status"` (canonical order).

### 9. Brenda tries to change task-T-003's shared_with (FR-005 carve-out, Q1 = A)

```bash
curl -sS -i -X PATCH http://127.0.0.1:8086/tasks/task-T-003 \
  -H 'Authorization: Bearer tkn-brenda' \
  -H 'Content-Type: application/json' \
  -d '{ "shared_with": ["<alice-uuid>"] }'
```

Expected: `400 validation_error`, `field_errors.shared_with: "Only the task owner can change the share list."` Brenda is an admin in the team, but admins cannot share on behalf of owners.

### 10. Cross-team isolation (US5, FR-014, SC-003)

```bash
# Alice (team-T) tries to access task-U-001 (team-U)
curl -sS -i http://127.0.0.1:8086/tasks/task-U-001 \
  -H 'Authorization: Bearer tkn-alice'

# Alice tries a fabricated id
curl -sS -i http://127.0.0.1:8086/tasks/fabricated-id-9999 \
  -H 'Authorization: Bearer tkn-alice'
```

Both must return identical bytes: same status `404`, same `Content-Length`, same body. Run `diff <(curl1) <(curl2)` to confirm empty output.

### 11. Cross-team admin gets byte-equivalent 404 (FR-006)

```bash
curl -sS -i http://127.0.0.1:8086/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-evan'
```

Expected: `404 Not Found` byte-equivalent. Even though Evan is an admin (of `team-U`), they cannot reach a `team-T` task.

### 12. Alice tries to share with a user in a different team (FR-012)

```bash
curl -sS -i -X PATCH http://127.0.0.1:8086/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "shared_with": ["<dan-uuid>"] }'
```

(Dan is in team-U; Alice is in team-T.)

Expected: `400 validation_error`, `field_errors.shared_with` includes "Sharee '<dan-uuid>' is not a member of this team."

### 13. Alice deletes task-T-002 (FR-012)

```bash
curl -sS -i -X DELETE http://127.0.0.1:8086/tasks/task-T-002 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: `204 No Content`. Task gone from `GET /tasks/task-T-002` (404 byte-equivalent). Audit entry written: `operation: "deleted"`, `diff_summary: ""`.

### 14. The audit endpoint still serves the deleted task's history (FR-017, US7)

```bash
curl -sS http://127.0.0.1:8086/tasks/task-T-002/audit \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: `200 OK`, full chronological event list ending with the `deleted` entry.

### 15. Carol tries to view the audit of task-T-002 (was never shared with her)

```bash
curl -sS -i http://127.0.0.1:8086/tasks/task-T-002/audit \
  -H 'Authorization: Bearer tkn-carol'
```

Expected: `404 Not Found` byte-equivalent. Carol was never in the read-set of task-T-002.

### 16. Trying to forge `team_id` in the request body (SC-006)

```bash
curl -sS -X POST http://127.0.0.1:8086/tasks \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "title": "Sneak", "team_id": "team-U" }'
```

Expected: `400 validation_error`, `field_errors.team_id: "team_id is immutable and cannot be set in the request body."` Even though Alice tried to claim her task belongs to team-U, the body field is ignored and rejected.

### 17. Audit-write SLA breach (FR-018, SC-008)

(Run a separate process that holds the SQLite write lock for 1.5 s; fire a PATCH.) Expected: `503 audit_unavailable`. Task state unchanged. No audit entry written. Tested in `test_audit_sla.py`.

## Smoke test — auth boundary

| What to do                                                                  | Expected response                  | Why it matters         |
|-----------------------------------------------------------------------------|------------------------------------|------------------------|
| Any request with `Authorization: Bearer not-a-real-token`                   | `401 unauthenticated`              | FR-001, SC-005.        |
| Any request with no `Authorization` header                                  | `401 unauthenticated`              | FR-001.                |
| `Authorization: Bearer <expired-token>`                                     | `401 unauthenticated`              | FR-001 (introspector returns None for expired). |
| `GET /tasks/non-existent-task` with valid auth                              | `404 not_found` (byte-equivalent)  | Standard not-found.    |
| `DELETE /tasks/non-existent-task` with valid auth                           | `404 not_found` (byte-equivalent)  | Standard not-found.    |

## Run the tests

```bash
pytest tests/task_sharing -q
```

Test groupings:

| File                                              | What it covers                                                                                                                              |
|---------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `tests/task_sharing/test_oauth.py`                | OAuth bearer + token introspection; ensures `team_id` and `role` come from token claims, not the body (SC-006 forged-payload probe).         |
| `tests/task_sharing/test_permissions.py`          | Exhaustive (relationship × action) matrix across all five relationship classes and six actions.                                              |
| `tests/task_sharing/test_validation.py`           | Per-field validation; per-field error reporting; rejection of immutable fields (`owner_id`, `team_id`); non-owner `shared_with` rejection.   |
| `tests/task_sharing/test_sharing.py`              | Per-task share lifecycle: add/remove sharees, sharee can edit/audit/can't-delete/can't-reshare, cross-team sharing rejection.                |
| `tests/task_sharing/test_audit.py`                | Per-event audit semantics: a single PATCH can yield multiple audit entries; field-name-list `diff_summary`; immutability; deletion preserves audit. |
| `tests/task_sharing/test_audit_sla.py`            | Holds SQLite write lock for 1.5 s; fires PATCH; asserts `503 audit_unavailable` + state unchanged + no audit entry written.                   |
| `tests/task_sharing/test_byte_equivalence.py`     | Constructs (own-team-task, cross-team-task, fabricated-id, sharee-on-DELETE) quadruples; asserts identical `(status, content_type, content_length, body)` across every unauthorised-access endpoint. |
| `tests/task_sharing/test_service.py`              | Business logic — create, list, view, edit, delete, share — against in-memory DB.                                                            |
| `tests/task_sharing/test_store.py`                | Schema, CHECK constraints, FK behaviour (incl. ON DELETE CASCADE for `task_shares`), append-only on `audit_entries` (static SQL probe).      |
| `tests/task_sharing/test_handlers.py`             | HTTP-level: status codes, response shapes, error envelopes; canonical not-found bytes; `Content-Length` consistency.                         |
| `tests/task_sharing/test_performance.py`          | Smoke load test under the 60/20/10/5/5 mix; asserts p99 ≤ 300 ms at 200 req/s on the developer machine. Skipped on CI where wall-clock measurement is unreliable. |
| `tests/task_sharing/test_invariants.py`           | SC-003…SC-011 catch-all probes including runtime audit-immutability scan, byte-equivalence sampling, and forged-payload probes.              |

## Style and lint

```bash
ruff check src/task_sharing tests/task_sharing
```

Type hints on all public functions; `str | None` syntax (Constitution III); Protocol for `TokenIntrospector`.

## When you're done

Stop the server with `Ctrl+C`. The `./task_sharing.db` file persists. Delete it before re-seeding from scratch (`rm task_sharing.db task_sharing.db-wal task_sharing.db-shm` — WAL mode produces sidecar files).

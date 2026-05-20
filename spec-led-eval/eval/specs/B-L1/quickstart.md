# Quickstart: Team Task Management

**Branch**: `006-task-management` | **Date**: 2026-05-17

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
python -m task_manager.server --seed --port 8084 --db-path ./task_manager.db
```

Flags:

| Flag        | Default              | Meaning                                                                                                                       |
|-------------|----------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `--port`    | `8084`               | TCP port to bind on `127.0.0.1`. Differs from 002 (`8080`), 003 (`8081`), 004 (`8082`), 005 (`8083`).                          |
| `--db-path` | `./task_manager.db`  | SQLite file. Use `:memory:` for an ephemeral run.                                                                              |
| `--seed`    | off                  | If set, seed four members, four bearer tokens, and four tasks across the three statuses. Idempotent — safe on a populated DB. |
| `--json`    | off                  | When combined with `--seed`, emit the seeded fixture as JSON on stdout instead of the human-readable table.                    |
| `--help`    | —                    | Human-readable usage on stdout.                                                                                                |

Errors print to stderr.

## Seeded fixture

`--seed` produces a deterministic fixture (same UUIDs, same tokens every run):

| Username     | Token            | Display name      |
|--------------|------------------|-------------------|
| `alice`      | `tkn-alice`      | Alice Member      |
| `bob`        | `tkn-bob`        | Bob Member        |
| `carol`      | `tkn-carol`      | Carol Member      |
| `dan`        | `tkn-dan`        | Dan Member        |

Seeded tasks (titles only; full bodies via the smoke commands below):

| Task id       | Title                          | Status         | Assignee | Created by | Notes                       |
|---------------|--------------------------------|----------------|----------|------------|-----------------------------|
| `task-001`    | `Write release notes`          | `in_progress`  | `alice`  | `alice`    | Has a due_date.             |
| `task-002`    | `Triage support backlog`       | `todo`         | `bob`    | `alice`    | Unassigned would also work. |
| `task-003`    | `Plan team offsite`            | `todo`         | (none)   | `carol`    | Unassigned.                  |
| `task-004`    | `Renew SSL certificate`        | `done`         | `dan`    | `dan`      | Already closed.              |

## Smoke test — end-to-end happy path

These commands assume the seeded server is running on `:8084`.

### 1. Alice creates a task (US1)

```bash
curl -sS -X POST http://127.0.0.1:8084/tasks \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "title": "Refresh README", "description": "Top section needs a 2026 update.", "due_date": "2026-05-31", "assignee_id": "<bob-uuid>" }'
```

Expected: `201 Created`, fresh `id`, `status: "todo"`, `created_by_display_name: "Alice Member"`, `assignee_display_name: "Bob Member"`.

### 2. Alice tries to create a task with an empty title (FR-005)

```bash
curl -sS -X POST http://127.0.0.1:8084/tasks \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "title": "   ", "description": "" }'
```

Expected: `400 validation_error`, `field_errors` lists `title`.

### 3. List all tasks ordered by most-recently-updated (US3, FR-014)

```bash
curl -sS http://127.0.0.1:8084/tasks \
  -H 'Authorization: Bearer tkn-bob'
```

Expected: `200 OK`, five tasks (four seeded + Alice's new one from step 1), ordered by `updated_at DESC`. Note: any authenticated user can see every task (Q2 = A; FR-003).

### 4. Bob filters to his own todo tasks (FR-015)

```bash
curl -sS 'http://127.0.0.1:8084/tasks?status=todo&assignee=mine' \
  -H 'Authorization: Bearer tkn-bob'
```

Expected: `200 OK`, the tasks where `status=todo` AND `assignee_id=<bob-uuid>`.

### 5. Bob searches by title substring (FR-015)

```bash
curl -sS 'http://127.0.0.1:8084/tasks?q=triage' \
  -H 'Authorization: Bearer tkn-bob'
```

Expected: `200 OK`, the seeded `Triage support backlog` task (and any other task whose title contains "triage" case-insensitively).

### 6. Bob picks up his task (`todo` → `in_progress`) (US2)

```bash
curl -sS -X PATCH http://127.0.0.1:8084/tasks/task-002 \
  -H 'Authorization: Bearer tkn-bob' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "in_progress" }'
```

Expected: `200 OK`, `status: "in_progress"`, `updated_at` refreshed.

### 7. Carol (anyone) edits Bob's task — flat permissions (FR-004, Q3 = A)

```bash
curl -sS -X PATCH http://127.0.0.1:8084/tasks/task-002 \
  -H 'Authorization: Bearer tkn-carol' \
  -H 'Content-Type: application/json' \
  -d '{ "description": "Focus on the oldest 20 tickets first." }'
```

Expected: `200 OK`. The flat permission model means Carol (not the assignee, not the creator) can edit any task.

### 8. Dan tries to edit a closed task without reopening (FR-011, US2 #5)

```bash
curl -sS -X PATCH http://127.0.0.1:8084/tasks/task-004 \
  -H 'Authorization: Bearer tkn-dan' \
  -H 'Content-Type: application/json' \
  -d '{ "description": "Add renewal date." }'
```

Expected: `409 task_closed`, `current_status: "done"`, message pointing the caller to set `status` in the same request.

### 9. Dan reopens-and-edits in one PATCH (FR-011, US2 #6)

```bash
curl -sS -X PATCH http://127.0.0.1:8084/tasks/task-004 \
  -H 'Authorization: Bearer tkn-dan' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "in_progress", "description": "Add renewal date." }'
```

Expected: `200 OK`. Both `status` and `description` updated atomically; `updated_at` refreshed.

### 10. Alice deletes a task (US4)

```bash
curl -sS -i -X DELETE http://127.0.0.1:8084/tasks/task-003 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: `204 No Content`. The task is gone from `GET /tasks/task-003` (404) and from `GET /tasks` (absent). The `task_deletions` table now contains one row recording Alice as the deleter and the task's title `Plan team offsite` at the moment of deletion (FR-018). Use the DB inspector to confirm:

```bash
sqlite3 ./task_manager.db "SELECT task_id, task_title_at_delete, deleted_by_user_id, deleted_at FROM task_deletions ORDER BY id DESC LIMIT 1;"
```

### 11. Concurrent edits — last write wins (Edge Cases, Assumptions)

Open two terminals; both edit the same task with different titles roughly simultaneously. Whichever request commits last is the value that sticks. There is no `409 conflict` and no optimistic-locking error.

## Smoke test — auth boundary

| What to do                                                                  | Expected response                | Why it matters         |
|-----------------------------------------------------------------------------|----------------------------------|------------------------|
| Any request with `Authorization: Bearer not-a-real-token`                   | `401 unauthenticated`            | FR-001, SC-005.        |
| Any request with no `Authorization` header                                  | `401 unauthenticated`            | FR-001.                |
| `GET /tasks/non-existent-task`                                              | `404 not_found`                  | Standard not-found.    |
| `PATCH /tasks/non-existent-task` with any body                              | `404 not_found`                  | Standard not-found.    |
| `DELETE /tasks/non-existent-task`                                           | `404 not_found`                  | Standard not-found.    |

## Run the tests

```bash
pytest tests/task_manager -q
```

Test groupings:

| File                                       | What it covers                                                                                                                |
|--------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `tests/task_manager/test_auth.py`          | Bearer-token resolution; 401 paths; ensures no business logic runs on a 401.                                                  |
| `tests/task_manager/test_validation.py`    | Per-field validation; per-field error reporting (FR-005…FR-008); whitespace trimming on `title`.                              |
| `tests/task_manager/test_service.py`       | Business logic — create, get, list with filters, edit, delete — against in-memory DB.                                         |
| `tests/task_manager/test_store.py`         | Schema, CHECK constraints, indexes, FK behaviour.                                                                              |
| `tests/task_manager/test_handlers.py`      | HTTP-level: status codes, response shapes, error envelopes; `Content-Type` consistency.                                       |
| `tests/task_manager/test_filtering.py`     | All combinations of `status` / `assignee` / `q` filters; AND semantics; default ordering by `updated_at DESC`.                |
| `tests/task_manager/test_closed_task_rule.py` | The FR-011 / US2 #5 / US2 #6 matrix: edit-only-on-done, status-change-only-on-done, atomic both-fields-and-status on done. |
| `tests/task_manager/test_concurrency.py`   | Last-write-wins on two concurrent PATCHes; both succeed, second overwrites first; `updated_at` reflects the later edit.        |
| `tests/task_manager/test_deletion_log.py`  | Deletions append to `task_deletions`; the row's `task_title_at_delete` matches the task's title at deletion time (FR-018).    |
| `tests/task_manager/test_invariants.py`    | SC-001…SC-006 probes; no-cross-feature regression (e.g., asserts the absence of officer / auditor / role concepts).            |

## Style and lint

```bash
ruff check src/task_manager tests/task_manager
```

Type hints on all public functions; `str | None` syntax (Constitution III).

## When you're done

Stop the server with `Ctrl+C`. The `./task_manager.db` file persists; delete it before re-seeding from scratch.

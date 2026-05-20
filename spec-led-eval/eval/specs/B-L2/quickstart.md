# Quickstart: SaaS Team Task Management with Audit Trail

**Branch**: `007-team-tasks` | **Date**: 2026-05-17

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
python -m team_tasks.server --seed --port 8085 --db-path ./team_tasks.db
```

Flags:

| Flag        | Default              | Meaning                                                                                                                                                |
|-------------|----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--port`    | `8085`               | TCP port to bind on `127.0.0.1`. Differs from 002–006 so all packages can run side by side locally.                                                     |
| `--db-path` | `./team_tasks.db`    | SQLite file. Use `:memory:` for an ephemeral run.                                                                                                       |
| `--seed`    | off                  | If set, seed two teams, five users (with overlapping memberships), bearer tokens, and a handful of tasks across both teams. Idempotent — safe on a populated DB. |
| `--json`    | off                  | When combined with `--seed`, emit the seeded fixture as JSON on stdout instead of the human-readable table.                                            |
| `--help`    | —                    | Human-readable usage on stdout.                                                                                                                         |

Errors print to stderr.

## Seeded fixture

`--seed` produces a deterministic fixture:

**Teams**:

| Team id   | Name                |
|-----------|---------------------|
| `team-T`  | Acme Engineering    |
| `team-U`  | Acme Marketing      |

**Users and memberships**:

| Username     | Token            | Display name      | Team-T role | Team-U role |
|--------------|------------------|-------------------|-------------|-------------|
| `alice`      | `tkn-alice`      | Alice Member      | `member`    | —           |
| `brenda`     | `tkn-brenda`     | Brenda Admin      | `admin`     | —           |
| `carol`      | `tkn-carol`      | Carol Member      | `member`    | `member`    |
| `dan`        | `tkn-dan`        | Dan Admin         | —           | `admin`     |
| `evan`       | `tkn-evan`       | Evan Outsider     | —           | —           |

`evan` belongs to neither team — useful for cross-team isolation probes.

**Tasks** (titles only; full bodies via the smoke commands below):

| Task id       | Team    | Title                       | Owner    | Status         | Assignee |
|---------------|---------|-----------------------------|----------|----------------|----------|
| `task-T-001`  | team-T  | `Write release notes`       | `alice`  | `in_progress`  | `alice`  |
| `task-T-002`  | team-T  | `Triage support backlog`    | `alice`  | `todo`         | `brenda` |
| `task-U-001`  | team-U  | `Plan Q3 launch campaign`   | `dan`    | `todo`         | `carol`  |

## Smoke test — end-to-end happy path

These commands assume the seeded server is running on `:8085`.

### 1. Alice creates a task in team-T (US1)

```bash
curl -sS -X POST http://127.0.0.1:8085/tasks \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'X-Team-Id: team-T' \
  -H 'Content-Type: application/json' \
  -d '{ "title": "Refresh README", "description": "2026 update for the top section.", "due_date": "2026-05-31" }'
```

Expected: `201 Created`, fresh `id`, `team_id: "team-T"`, `owner_id: <alice-uuid>`, `status: "todo"`. One new audit entry written with `change_description: "created"`.

### 2. Alice forgets the team header (FR-003)

```bash
curl -sS -X POST http://127.0.0.1:8085/tasks \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "title": "no team" }'
```

Expected: `400 missing_team_context`.

### 3. Alice tries to see a team-U task (FR-014, SC-004)

```bash
curl -sS -i http://127.0.0.1:8085/tasks/task-U-001 \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'X-Team-Id: team-T'
```

Expected: `404 Not Found` with body `{"error":"not_found","message":"No such task."}`. Byte-identical to:

```bash
curl -sS -i http://127.0.0.1:8085/tasks/fabricated-id \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'X-Team-Id: team-T'
```

### 4. Evan (no membership in either team) gets the byte-equivalent 404 on a real team-T task

```bash
curl -sS -i http://127.0.0.1:8085/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-evan' \
  -H 'X-Team-Id: team-T'
```

Expected: `404 Not Found`, body identical to step 3 — Evan isn't a member of team-T, so the team-context boundary returns the byte-equivalent `not_found` (FR-003).

### 5. Carol (member of both teams) acts in team-T

```bash
curl -sS http://127.0.0.1:8085/tasks \
  -H 'Authorization: Bearer tkn-carol' \
  -H 'X-Team-Id: team-T'
```

Expected: `200 OK`, all team-T tasks (including the one Alice just created in step 1). Carol's membership of team-U is irrelevant for this request.

### 6. Carol switches to team-U

```bash
curl -sS http://127.0.0.1:8085/tasks \
  -H 'Authorization: Bearer tkn-carol' \
  -H 'X-Team-Id: team-U'
```

Expected: `200 OK`, team-U tasks only. Same Carol, different team context.

### 7. Alice edits her own task (FR-008)

```bash
curl -sS -X PATCH http://127.0.0.1:8085/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'X-Team-Id: team-T' \
  -H 'Content-Type: application/json' \
  -d '{ "title": "Write release notes v2", "assignee_id": "<brenda-uuid>" }'
```

Expected: `200 OK`. One new audit entry with `change_description: "changed title, assignee"` (per-edit-event with field list, Q2 = A).

### 8. Carol (member, non-owner, non-admin) tries to edit Alice's task (FR-009, SC-005)

```bash
curl -sS -X PATCH http://127.0.0.1:8085/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-carol' \
  -H 'X-Team-Id: team-T' \
  -H 'Content-Type: application/json' \
  -d '{ "title": "Carol's override" }'
```

Expected: `403 permission_denied`. Task unchanged. **No audit entry written**.

### 9. Brenda (admin in team-T) edits Alice's task (FR-010, US4)

```bash
curl -sS -X PATCH http://127.0.0.1:8085/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-brenda' \
  -H 'X-Team-Id: team-T' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "done" }'
```

Expected: `200 OK`, `status: "done"`. Audit entry with `actor_user_id: <brenda-uuid>`, `actor_role: "admin"`, `change_description: "changed status"`.

### 10. Brenda tries to transfer ownership (FR-006, US4 #2)

```bash
curl -sS -X PATCH http://127.0.0.1:8085/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-brenda' \
  -H 'X-Team-Id: team-T' \
  -H 'Content-Type: application/json' \
  -d '{ "owner_id": "<carol-uuid>" }'
```

Expected: `400 validation_error`, `field_errors` lists `owner_id`. Task unchanged, no audit entry.

### 11. Alice deletes her task (FR-012, US3)

```bash
curl -sS -i -X DELETE http://127.0.0.1:8085/tasks/task-T-001 \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'X-Team-Id: team-T'
```

Expected: `204 No Content`. Task gone from `GET /tasks/task-T-001` (`404 not_found`) and from `GET /tasks` (absent). Audit entry with `change_description: "deleted"` written before the row was removed.

### 12. The audit endpoint still serves the deleted task's history (FR-016, US7)

```bash
curl -sS http://127.0.0.1:8085/tasks/task-T-001/audit \
  -H 'Authorization: Bearer tkn-carol' \
  -H 'X-Team-Id: team-T'
```

Expected: `200 OK`, `events` array containing every audit entry for the deleted task (`created`, every `changed <fields>`, final `deleted`), in chronological order. Carol — a non-admin non-owner member — can read the audit per FR-017.

### 13. A non-member of the team gets byte-equivalent 404 on the audit endpoint

```bash
curl -sS -i http://127.0.0.1:8085/tasks/task-T-001/audit \
  -H 'Authorization: Bearer tkn-dan' \
  -H 'X-Team-Id: team-U'
```

Expected: `404 not_found`. Dan is acting in team-U (where he's an admin), but the audit endpoint resolves the task to team-T, so the cross-team isolation rule applies (FR-014 extended to the audit endpoint).

### 14. Concurrent edits — last write wins, two audit entries written

Open two terminals; both edit `task-T-002` with different titles roughly simultaneously. Both PATCHes return 200. The task's final title is whichever PATCH committed last. `GET /tasks/task-T-002/audit` shows **both** edits in chronological order, each with its own `actor_user_id` and `occurred_at`.

## Smoke test — auth and team-context boundaries

| What to do                                                                  | Expected response                  | Why it matters         |
|-----------------------------------------------------------------------------|------------------------------------|------------------------|
| Any request with `Authorization: Bearer not-a-real-token`                   | `401 unauthenticated`              | FR-001, SC-006.        |
| Any request with no `Authorization` header                                  | `401 unauthenticated`              | FR-001.                |
| Any request to a task endpoint with no `X-Team-Id` header                   | `400 missing_team_context`         | FR-003.                |
| Any request with `X-Team-Id: team-Q-nonexistent`                            | `404 not_found` (byte-equivalent)  | FR-003 (non-membership = non-existent). |
| `GET /tasks/non-existent-task` with valid auth + valid team                 | `404 not_found` (byte-equivalent)  | Standard not-found.    |
| `DELETE /tasks/non-existent-task` with valid auth + valid team              | `404 not_found` (byte-equivalent)  | Standard not-found.    |

## Run the tests

```bash
pytest tests/team_tasks -q
```

Test groupings:

| File                                              | What it covers                                                                                                                |
|---------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `tests/team_tasks/test_auth.py`                   | Bearer-token resolution; 401 paths; ensures no business logic runs on a 401 (SC-006 probe).                                   |
| `tests/team_tasks/test_team_context.py`           | `X-Team-Id` parsing; missing → 400; non-membership → byte-equivalent 404; valid → handler runs with `(user_id, team_id, role)`. |
| `tests/team_tasks/test_permissions.py`            | Exhaustive (role × owner-or-not × action) matrix. Includes the 403 vs 404 split (in-team-but-not-owner → 403; cross-team → 404). |
| `tests/team_tasks/test_validation.py`             | Per-field validation; per-field error reporting; owner_id immutability rejection (FR-006).                                    |
| `tests/team_tasks/test_service.py`                | Business logic — create, list, view, edit, delete — against in-memory DB.                                                     |
| `tests/team_tasks/test_store.py`                  | Schema, CHECK constraints, FK behaviour, composite PK on `team_memberships`, append-only on `audit_entries` (static SQL probe). |
| `tests/team_tasks/test_handlers.py`               | HTTP-level: status codes, response shapes, error envelopes.                                                                   |
| `tests/team_tasks/test_filtering.py`              | All combinations of `status` / `assignee` / `q` filters; AND semantics; default ordering by `updated_at DESC`; team-scoping.   |
| `tests/team_tasks/test_cross_team_isolation.py`   | Constructs (own-team-task, other-team-task, fabricated-id) triples; asserts byte-equivalent 404 responses pairwise (SC-004).   |
| `tests/team_tasks/test_audit.py`                  | Per-edit-event semantics (one entry per save; empty-diff PATCH writes no entry); change_description shapes; snapshotted display name and role; audit survives task deletion. |
| `tests/team_tasks/test_invariants.py`             | SC-004…SC-008 catch-all probes including a runtime audit-immutability scan and a no-cross-feature-regression check.            |

## Style and lint

```bash
ruff check src/team_tasks tests/team_tasks
```

Type hints on all public functions; `str | None` syntax (Constitution III).

## When you're done

Stop the server with `Ctrl+C`. The `./team_tasks.db` file persists; delete it before re-seeding from scratch.

# HTTP API Contract: Team Task Management

**Branch**: `006-task-management` | **Date**: 2026-05-17

The service exposes exactly the five endpoints below. Any other path returns `404 not_found`. All requests and responses use `application/json; charset=utf-8`.

## Authentication (all endpoints)

```
Authorization: Bearer <token>
```

Resolution order, applied in `server.py` **before** any handler runs:

1. Header missing or malformed → `401 unauthenticated`.
2. Token unknown to the seeded `tokens` table → `401 unauthenticated`.
3. Token resolves to a `User`. The handler proceeds with `user` in scope.

```json
{ "error": "unauthenticated", "message": "Authentication required." }
```

There is no authorisation layer beyond authentication (Q3 = A — flat peers). Every authenticated caller can perform every operation.

## Common error envelope

```json
{ "error": "<code>", "message": "<human-readable description>" }
```

| HTTP status | error code           | When                                                                                                       |
|-------------|----------------------|------------------------------------------------------------------------------------------------------------|
| 400         | `validation_error`   | Body malformed; required field missing; title/description out of length; bad due_date; unknown assignee_id; unknown status. `field_errors` array carries per-field detail. |
| 401         | `unauthenticated`    | Missing / invalid `Authorization`. Returned before any handler logic.                                       |
| 404         | `not_found`          | Task with the given id does not exist.                                                                      |
| 409         | `task_closed`        | PATCH on a `done` task without simultaneously setting `status` to `todo` or `in_progress` (FR-011).        |
| 500         | `internal_error`     | Unexpected failure.                                                                                         |

### Field-error array (validation errors)

```json
{
  "error": "validation_error",
  "message": "One or more fields are invalid.",
  "field_errors": [
    { "field": "title", "message": "Title must be 1–200 characters after trimming whitespace." },
    { "field": "due_date", "message": "Due date must be ISO format YYYY-MM-DD." }
  ]
}
```

---

## `POST /tasks` — create a task

### Request

```http
POST /tasks HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "title": "Write release notes",
  "description": "Cover the 2.4 release; cross-reference the upgrade guide.",
  "due_date": "2026-05-24",
  "assignee_id": "user-uuid-or-null"
}
```

| Field        | Type          | Required | Notes                                                                       |
|--------------|---------------|----------|-----------------------------------------------------------------------------|
| `title`      | string        | yes      | 1–200 characters after trimming whitespace.                                 |
| `description`| string        | no       | 0–4000 characters. Defaults to `""`.                                        |
| `due_date`   | string \| null| no       | ISO date `YYYY-MM-DD`. Defaults to `null`. Past dates allowed.              |
| `assignee_id`| string \| null| no       | An existing user id, or `null`. Defaults to `null`.                         |

`status`, `created_by`, `created_at`, `updated_at` are server-controlled and ignored if present in the body.

### Responses

**201 Created** — task created with status `todo`:

```json
{
  "id": "task-uuid",
  "title": "Write release notes",
  "description": "Cover the 2.4 release; cross-reference the upgrade guide.",
  "due_date": "2026-05-24",
  "assignee_id": "user-uuid-or-null",
  "assignee_display_name": "Alice Member",
  "status": "todo",
  "created_by_user_id": "creator-uuid",
  "created_by_display_name": "Creator Member",
  "created_at": "2026-05-17T10:14:33.221Z",
  "updated_at": "2026-05-17T10:14:33.221Z"
}
```

When `assignee_id` is `null`, `assignee_display_name` is `null`.

**400 `validation_error`** — see envelope.

---

## `GET /tasks` — list and filter tasks

### Request

```http
GET /tasks?status=in_progress&assignee=mine&q=release HTTP/1.1
Authorization: Bearer <token>
```

| Query param | Type   | Required | Notes                                                                                                  |
|-------------|--------|----------|--------------------------------------------------------------------------------------------------------|
| `status`    | string | no       | One of `todo`, `in_progress`, `done`, `all`. Default `all`.                                            |
| `assignee`  | string | no       | One of `mine` (= caller's user_id), `unassigned`, a specific `<user_id>`, or `anyone`. Default `anyone`. |
| `q`         | string | no       | Case-insensitive title substring. Default unset.                                                       |

All three filters combine as a logical AND. The list is ordered by `updated_at DESC`.

### Responses

**200 OK**:

```json
{
  "tasks": [
    {
      "id": "task-uuid",
      "title": "Write release notes",
      "description": "Cover the 2.4 release; cross-reference the upgrade guide.",
      "due_date": "2026-05-24",
      "assignee_id": "user-uuid",
      "assignee_display_name": "Alice Member",
      "status": "in_progress",
      "created_by_user_id": "creator-uuid",
      "created_by_display_name": "Creator Member",
      "created_at": "2026-05-17T10:14:33.221Z",
      "updated_at": "2026-05-17T10:31:08.554Z"
    }
  ]
}
```

If no tasks match, `"tasks": []`.

**400 `validation_error`** — `status` not in the allowed set; `assignee` not in the allowed set and not a known user id.

---

## `GET /tasks/{id}` — view a single task

### Request

```http
GET /tasks/task-uuid HTTP/1.1
Authorization: Bearer <token>
```

### Responses

**200 OK** — same body shape as a `POST /tasks` 201 Created.

**404 `not_found`** — no task with that id.

---

## `PATCH /tasks/{id}` — edit a task

### Request

```http
PATCH /tasks/task-uuid HTTP/1.1
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "title": "Write release notes v2",
  "description": "Updated draft.",
  "due_date": null,
  "assignee_id": "user-uuid",
  "status": "in_progress"
}
```

Every field in the body is optional; the body MAY include any subset of `title`, `description`, `due_date`, `assignee_id`, `status`. A field absent from the body is unchanged. A field present with the value `null` clears it (applies to `due_date` and `assignee_id`; `title` and `status` cannot be cleared).

| Field        | Type          | Notes                                                                                                                    |
|--------------|---------------|--------------------------------------------------------------------------------------------------------------------------|
| `title`      | string        | Non-empty after trimming; ≤200 characters. Cannot be `null`.                                                             |
| `description`| string        | 0–4000 characters. Cannot be `null` (use `""` to clear).                                                                  |
| `due_date`   | string \| null| Valid ISO date `YYYY-MM-DD`, or `null` to clear.                                                                          |
| `assignee_id`| string \| null| An existing user id, or `null` to unassign.                                                                              |
| `status`     | string        | One of `todo`, `in_progress`, `done`. Cannot be `null`.                                                                  |

### Closed-task rule (FR-011, US2 #5/#6)

If the task's current status is `done`, the request MUST include `status` set to `todo` or `in_progress` to be accepted. Other field changes in the same request are applied atomically with the status change. A PATCH on a `done` task that omits `status` (or sets `status` to `done`) → `409 task_closed`.

### Responses

**200 OK** — task updated; body is the full task in the same shape as `POST /tasks` 201.

**400 `validation_error`** — any field-level validation failure (see field table).

**404 `not_found`** — no task with that id.

**409 `task_closed`**:

```json
{
  "error": "task_closed",
  "message": "This task is closed. Reopen it (set status to todo or in_progress) in the same request to edit other fields.",
  "current_status": "done"
}
```

---

## `DELETE /tasks/{id}` — delete a task

### Request

```http
DELETE /tasks/task-uuid HTTP/1.1
Authorization: Bearer <token>
```

### Responses

**204 No Content** — task deleted. The task is gone from every list, filter, search, and direct lookup. A row is appended to `task_deletions` recording the deleter, the task id, and the task title at the moment of deletion (FR-018).

**404 `not_found`** — no task with that id.

There is no `task_closed` response on DELETE: any task at any status can be deleted (FR-012). There is no confirmation step in this contract; clients are expected to confirm with the user before calling DELETE.

## Invariants the contract is built to expose

| Invariant                                                                  | Surfaced by                                                                                       |
|----------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| Authentication on every operation (FR-001, SC-005)                          | `401 unauthenticated` from the boundary before any handler runs                                    |
| Title trim + length, description length, due-date format, assignee existence (FR-005…FR-008) | `400 validation_error` with `field_errors` covering every offending field at once  |
| Closed-task PATCH rule (FR-011, US2 #5/#6)                                  | `409 task_closed` with the body explaining the reopen-or-fail expectation                          |
| Flat permissions, single workspace (FR-003, FR-004)                         | The absence of any `403 permission_denied` response; every authenticated user gets the same access |
| Permanent deletion + operational log (FR-012, FR-018)                       | `DELETE` returns 204; the task is gone from `GET /tasks/{id}` (404) and `GET /tasks` (absent); the `task_deletions` table records the event |

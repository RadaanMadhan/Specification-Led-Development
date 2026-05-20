# HTTP API Contract: SaaS Team Task Management with Audit Trail

**Branch**: `007-team-tasks` | **Date**: 2026-05-17

The service exposes exactly the six endpoints below. Any other path returns the byte-equivalent `not_found` response. All requests and responses use `application/json; charset=utf-8`.

## Authentication (all endpoints)

```
Authorization: Bearer <token>
```

Resolution in `server.py` **before** any handler runs:

1. Header missing or malformed → `401 unauthenticated`.
2. Token unknown to the seeded `tokens` table → `401 unauthenticated`.

```json
{ "error": "unauthenticated", "message": "Authentication required." }
```

## Team context (all endpoints)

```
X-Team-Id: <team_id>
```

Resolution in `server.py` **after** authentication, **before** any handler runs (FR-003):

1. Header missing → `400 missing_team_context`.
2. Header present but `(user_id, team_id)` not in `team_memberships` → byte-equivalent `404 not_found` (see "Byte-equivalent not-found response" below).

```json
{ "error": "missing_team_context", "message": "X-Team-Id header is required." }
```

When the team-context check passes, the handler runs with `(user_id, team_id, role)` in scope.

## Byte-equivalent not-found response

A single canonical not-found response is used for every "you can't see this" case on `GET`, `PATCH`, `DELETE` `/tasks/{id}` and on `GET /tasks/{id}/audit`:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8

{"error":"not_found","message":"No such task."}
```

This response is returned for:

- `{id}` does not exist.
- `{id}` exists but belongs to a different team than the caller's `X-Team-Id`.
- The caller's `X-Team-Id` names a team they are not a member of.
- `GET …/audit` is requested for a `{id}` the caller cannot see for any reason above.

Body bytes are identical across all these cases (FR-014). `Date`-style headers may differ; the spec's no-leakage requirement covers status + body, not unrelated transport headers.

## Common error envelope (other 4xx / 5xx)

```json
{ "error": "<code>", "message": "<human-readable description>" }
```

| HTTP status | error code                | When                                                                                                       |
|-------------|---------------------------|------------------------------------------------------------------------------------------------------------|
| 400         | `validation_error`        | Body malformed; required field missing; title/description out of length; bad `due_date`; assignee not a member of the current team; attempt to set `owner_id`. `field_errors` array carries per-field detail. |
| 400         | `missing_team_context`    | `X-Team-Id` header is missing.                                                                              |
| 401         | `unauthenticated`         | Missing / invalid `Authorization`. Returned before any handler logic.                                       |
| 403         | `permission_denied`       | Caller is a non-owner, non-admin member attempting to PATCH or DELETE a task they don't own (FR-009).      |
| 404         | `not_found`               | See "Byte-equivalent not-found response" above. (Both real "doesn't exist" and "you can't see it" use this.) |
| 500         | `internal_error`          | Unexpected failure.                                                                                         |

### Field-error array (validation errors)

```json
{
  "error": "validation_error",
  "message": "One or more fields are invalid.",
  "field_errors": [
    { "field": "title", "message": "Title must be 1–200 characters after trimming whitespace." },
    { "field": "assignee_id", "message": "Assignee must be a current member of this team." },
    { "field": "owner_id", "message": "Owner is immutable in v1; this field cannot be changed." }
  ]
}
```

## Permission matrix

| Action                              | `member` (non-owner of task) | `member` (owner of task) | `admin` (any task in team) | Non-member of team | Unauthenticated |
|-------------------------------------|------------------------------|--------------------------|----------------------------|--------------------|-----------------|
| `POST /tasks`                       | ✅                            | n/a                       | ✅                          | 404 (team gate)    | 401             |
| `GET /tasks` (list in current team) | ✅                            | n/a                       | ✅                          | 404 (team gate)    | 401             |
| `GET /tasks/{id}` (task in current team) | ✅                       | ✅                        | ✅                          | 404 (byte-equiv.)  | 401             |
| `PATCH /tasks/{id}`                 | 403 `permission_denied`      | ✅                        | ✅                          | 404 (byte-equiv.)  | 401             |
| `DELETE /tasks/{id}`                | 403 `permission_denied`      | ✅                        | ✅                          | 404 (byte-equiv.)  | 401             |
| `GET /tasks/{id}/audit`             | ✅                            | ✅                        | ✅                          | 404 (byte-equiv.)  | 401             |

**On the 403 vs 404 split**: PATCH/DELETE refused for non-owner non-admin members returns `403 permission_denied` rather than the byte-equivalent 404 because the caller is already a member of the team and can see the task via `GET`; hiding its existence would be theatre. The 404-byte-equivalent path is for *cross-team* refusals where the caller has no legitimate access at all.

---

## `POST /tasks` — create a task in the current team

### Request

```http
POST /tasks HTTP/1.1
Authorization: Bearer <token>
X-Team-Id: <team_id>
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
| `description`| string        | no       | 0–4000 characters. Default `""`.                                            |
| `due_date`   | string \| null| no       | ISO date `YYYY-MM-DD`. Default `null`. Past dates allowed.                  |
| `assignee_id`| string \| null| no       | A current member of the **current team** (`X-Team-Id`), or `null`. Default `null`. |

`status`, `team_id`, `owner_id`, `created_at`, `updated_at` are server-controlled and ignored if present. `team_id` is set from `X-Team-Id`; `owner_id` is set from the authenticated user; `status` is set to `todo`.

### Responses

**201 Created** — task created at status `todo`; one `created` audit entry written in the same transaction:

```json
{
  "id": "task-uuid",
  "team_id": "team-uuid",
  "title": "Write release notes",
  "description": "Cover the 2.4 release; cross-reference the upgrade guide.",
  "due_date": "2026-05-24",
  "assignee_id": "user-uuid-or-null",
  "assignee_display_name": "Alice Member",
  "status": "todo",
  "owner_id": "creator-uuid",
  "owner_display_name": "Creator Member",
  "created_at": "2026-05-17T10:14:33.221Z",
  "updated_at": "2026-05-17T10:14:33.221Z"
}
```

**400 `validation_error`** — see envelope.

---

## `GET /tasks` — list tasks in the current team

### Request

```http
GET /tasks?status=in_progress&assignee=mine&q=release HTTP/1.1
Authorization: Bearer <token>
X-Team-Id: <team_id>
```

| Query param | Type   | Required | Notes                                                                                                  |
|-------------|--------|----------|--------------------------------------------------------------------------------------------------------|
| `status`    | string | no       | One of `todo`, `in_progress`, `done`, `all`. Default `all`.                                            |
| `assignee`  | string | no       | One of `mine` (= caller's user_id), `unassigned`, a specific `<user_id>`, or `anyone`. Default `anyone`. |
| `q`         | string | no       | Case-insensitive title substring. Default unset.                                                       |

All three filters combine as a logical AND. The list is ordered by `updated_at DESC`. Only tasks where `tasks.team_id == X-Team-Id` are returned.

### Responses

**200 OK**: `{"tasks": [task, ...]}` — same task shape as `POST 201`. If no tasks match: `{"tasks": []}`.

---

## `GET /tasks/{id}` — view a single task

### Request

```http
GET /tasks/task-uuid HTTP/1.1
Authorization: Bearer <token>
X-Team-Id: <team_id>
```

### Responses

**200 OK** — task in the current team; body same as `POST 201`.

**404 `not_found` (byte-equivalent)** — task doesn't exist, or exists in another team.

---

## `PATCH /tasks/{id}` — edit a task

### Request

```http
PATCH /tasks/task-uuid HTTP/1.1
Authorization: Bearer <token>
X-Team-Id: <team_id>
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

Every field optional. A field absent from the body is unchanged. A field present with `null` clears it (`due_date`, `assignee_id` only).

| Field        | Type          | Notes                                                                                                                    |
|--------------|---------------|--------------------------------------------------------------------------------------------------------------------------|
| `title`      | string        | Non-empty after trimming; ≤200 characters. Cannot be `null`.                                                             |
| `description`| string        | 0–4000 characters. Cannot be `null` (use `""` to clear).                                                                  |
| `due_date`   | string \| null| Valid ISO `YYYY-MM-DD`, or `null` to clear.                                                                              |
| `assignee_id`| string \| null| A current member of the current team, or `null` to unassign.                                                              |
| `status`     | string        | One of `todo`, `in_progress`, `done`. Free transitions in any direction.                                                  |
| `owner_id`   | (any)         | **Rejected** with `400 validation_error` (FR-006: owner is immutable).                                                    |

### Authorisation

`role == admin`, OR `task.owner_id == caller.user_id`. Otherwise → `403 permission_denied`. Cross-team → byte-equivalent `404`.

### Behaviour

In one transaction:

1. Authenticate, resolve `X-Team-Id`, look up task. If task is in a different team → byte-equivalent `404`.
2. Permission check (owner-or-admin). Otherwise → `403 permission_denied`.
3. Validate body. On failure → `400 validation_error`.
4. Compute the set of fields whose values actually differ from the current state. If the set is empty → `200 OK` is returned with the unchanged task body and **no audit entry is written** (the audit log is the source of truth for changes, not for requests).
5. Otherwise, UPDATE the task (set the changed fields + `updated_at = now()`) and INSERT one audit entry with `change_description = "changed <field>[, <field>]*"` (in the order the fields are listed in the schema).
6. Return the full updated task.

### Responses

**200 OK** — body is the full task (same shape as POST 201).

**400 `validation_error`** — any field-level failure, including a forbidden `owner_id` mutation.

**403 `permission_denied`** — caller is a non-owner non-admin member of the team.

**404 `not_found` (byte-equivalent)** — task doesn't exist or is in another team.

---

## `DELETE /tasks/{id}` — delete a task

### Request

```http
DELETE /tasks/task-uuid HTTP/1.1
Authorization: Bearer <token>
X-Team-Id: <team_id>
```

### Authorisation

Same as PATCH: `role == admin` OR `task.owner_id == caller.user_id`.

### Behaviour

In one transaction:

1. Authenticate, resolve `X-Team-Id`, look up task. Cross-team → byte-equivalent `404`.
2. Permission check.
3. INSERT a final audit entry with `change_description = "deleted"`.
4. DELETE the task row.

The audit entry is inserted **before** the task DELETE so that the snapshot of actor/role/timestamp is taken while the task still notionally exists; the audit row carries no FK to `tasks`, so the order of writes within the transaction is not load-bearing for referential integrity, but the order matches the human reading of "we recorded the deletion, then the task was deleted".

### Responses

**204 No Content** — task deleted; audit trail preserved.

**403 `permission_denied`** — caller is a non-owner non-admin member.

**404 `not_found` (byte-equivalent)** — task doesn't exist or is in another team.

---

## `GET /tasks/{id}/audit` — view a task's audit trail

### Request

```http
GET /tasks/task-uuid/audit HTTP/1.1
Authorization: Bearer <token>
X-Team-Id: <team_id>
```

### Authorisation

Any member of the team. Cross-team → byte-equivalent `404` (FR-017).

### Responses

**200 OK** — every audit entry for this task, in chronological order (FR-017):

```json
{
  "task_id": "task-uuid",
  "events": [
    {
      "actor_user_id": "creator-uuid",
      "actor_display_name": "Alice Member",
      "actor_role": "member",
      "occurred_at": "2026-05-17T10:14:33.221Z",
      "change_description": "created"
    },
    {
      "actor_user_id": "creator-uuid",
      "actor_display_name": "Alice Member",
      "actor_role": "member",
      "occurred_at": "2026-05-17T11:02:08.554Z",
      "change_description": "changed title, assignee"
    },
    {
      "actor_user_id": "admin-uuid",
      "actor_display_name": "Brenda Admin",
      "actor_role": "admin",
      "occurred_at": "2026-05-19T09:30:00.000Z",
      "change_description": "deleted"
    }
  ]
}
```

`actor_display_name` and `actor_role` are the values **at the time of the change** (snapshots, FR-015); even if the user has since been renamed or had their role changed, these strings do not change.

For a deleted task, the events array still resolves and the `deleted` entry is present.

**404 `not_found` (byte-equivalent)** — task doesn't exist, is in another team, or caller's `X-Team-Id` is not their team.

## Invariants the contract is built to expose

| Invariant                                                                                  | Surfaced by                                                                                                                                            |
|--------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
| Authentication required (FR-001, SC-006)                                                    | `401 unauthenticated` from the boundary before any handler runs                                                                                         |
| Team-context required (FR-003)                                                              | `400 missing_team_context` for missing `X-Team-Id`; `404 not_found` (byte-equivalent) for non-membership                                                |
| Cross-team isolation (FR-011, FR-014, SC-004)                                               | Single `responses.not_found_response()` helper returns identical `(status, body)` for every cross-team and non-existent case                            |
| Owner-or-admin edit/delete (FR-008–FR-010, SC-005)                                          | `403 permission_denied` when the caller is a member of the team but neither the owner nor an admin                                                      |
| Owner immutability (FR-006)                                                                 | `400 validation_error` with `field_errors` naming `owner_id` whenever a PATCH body includes it                                                          |
| Audit trail written per save (FR-015, SC-007)                                               | The PATCH 200 response is paired with exactly one new audit entry per save (asserted in tests); empty-diff PATCH writes no entry                       |
| Audit trail outlives the task (FR-016)                                                      | DELETE returns 204; the audit endpoint for the same id continues to return the full event list including the `deleted` entry                            |
| Audit visible to all team members (FR-017)                                                  | The audit endpoint requires only the `member` role and the team-context predicate                                                                       |
| Snapshotted actor identity (FR-015)                                                         | The audit entries persist `actor_display_name` and `actor_role` at the time of each change; renames in the host product do not retroactively rewrite history |

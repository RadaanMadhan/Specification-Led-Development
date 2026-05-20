# HTTP API Contract: Multi-Tenant Task Management with Per-Task Sharing and Audit

**Branch**: `008-task-sharing` | **Date**: 2026-05-17

The service exposes exactly the five endpoints from the user description. Any other path returns the byte-equivalent `not_found` response. All requests and responses use `application/json; charset=utf-8`.

## Authentication (all endpoints) — OAuth 2.0 bearer

```
Authorization: Bearer <token>
```

Resolution in `server.py` **before** any handler runs (FR-001):

1. Header missing or malformed → `401 unauthenticated`.
2. `TokenIntrospector.introspect(token)` returns `None` (unknown / expired / missing required claims) → `401 unauthenticated`.

```json
{ "error": "unauthenticated", "message": "Authentication required." }
```

When introspection succeeds, the handler runs with an `AuthenticatedCaller(user_id, team_id, role)`. The `team_id` and `role` are taken from the introspection result, **never** from the request payload (FR-002, FR-002a, SC-006).

## Byte-equivalent not-found response

A single canonical not-found response is used for every "you cannot see / act on this" case across all four `/tasks/{id}*` endpoints:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8
Content-Length: 53

{"error":"not_found","message":"No such task."}
```

This response is returned for:

- `{id}` does not exist.
- `{id}` belongs to a team other than the caller's `team_id`.
- The caller is an in-team non-owner non-admin non-sharee.
- The caller is a sharee attempting `DELETE` (Q3 = B sharees cannot delete; same byte-equivalent 404 as for "you can't see this").
- `GET /tasks/{id}/audit` where the caller has no read access.

Body bytes, `Content-Type`, and `Content-Length` are identical across all these cases (FR-014). Transport-level headers (`Date`, `Server`, etc.) are out of scope of byte-equivalence.

A single helper `responses.not_found_response()` returns the canonical bytes; static + runtime tests assert that every unauthorised-access code path uses it.

## Common error envelope (other 4xx / 5xx)

```json
{ "error": "<code>", "message": "<human-readable description>" }
```

| HTTP status | error code                | When                                                                                                       |
|-------------|---------------------------|------------------------------------------------------------------------------------------------------------|
| 400         | `validation_error`        | Body malformed; required field missing; title/description out of length; bad `due_date`; attempt to set `owner_id`/`team_id`; attempt by non-owner to set `shared_with`; `shared_with` includes a user not in the owner's team. `field_errors` array carries per-field detail. |
| 401         | `unauthenticated`         | Missing / invalid OAuth bearer token, or missing `team_id`/`role` claims. Returned before any handler logic. |
| 404         | `not_found`               | See "Byte-equivalent not-found response" above.                                                            |
| 503         | `audit_unavailable`       | Audit write would exceed the 1-second SLA (FR-018); the task mutation was rolled back; no audit entries were written. |
| 500         | `internal_error`          | Unexpected failure.                                                                                         |

### Field-error array (validation errors)

```json
{
  "error": "validation_error",
  "message": "One or more fields are invalid.",
  "field_errors": [
    { "field": "title", "message": "Title must be 1–200 characters after trimming whitespace." },
    { "field": "shared_with", "message": "Only the task owner can change the share list." },
    { "field": "shared_with", "message": "Sharee 'user-XYZ' is not a member of this team." },
    { "field": "owner_id", "message": "Owner is immutable in v1; this field cannot be changed." }
  ]
}
```

`field_errors` may contain multiple entries per field (e.g., two different problems with `shared_with`). Reports **all** offending fields at once.

## Permission matrix

(See research.md for the source-of-truth table. Reproduced here for the contract.)

| Action                              | Outsider | In-team-no-rel | Sharee | Team admin | Owner |
|-------------------------------------|----------|----------------|--------|------------|-------|
| `POST /tasks`                       | n/a       | ✅ (becomes owner) | n/a | ✅      | n/a   |
| `GET /tasks/{id}`                   | 404 (byte-equiv.) | 404 (byte-equiv.) | ✅ | ✅ | ✅ |
| `PATCH /tasks/{id}` — fields only (no `shared_with`) | 404 | 404 | ✅ | ✅ | ✅ |
| `PATCH /tasks/{id}` — body includes `shared_with` | 404 | 404 | 400 `validation_error` on `shared_with` | 400 `validation_error` on `shared_with` | ✅ |
| `DELETE /tasks/{id}`                | 404      | 404            | 404 (byte-equiv.) | ✅      | ✅     |
| `GET /tasks/{id}/audit`             | 404      | 404            | ✅      | ✅          | ✅     |

The 400-vs-404 split is deliberate: for callers in the same team who *can* see the task, a forbidden `shared_with` change is reported as a 400 validation error (revealing only that the request is malformed, not that the task is sharable). For callers outside the read-set (sharee on DELETE, in-team-no-rel, outsider), the response is the byte-equivalent 404. The unifying rule is FR-014: the response must be byte-equivalent whenever the caller is *not in the read-set*.

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
  "description": "Cover the 2.4 release.",
  "due_date": "2026-05-24",
  "status": "todo",
  "shared_with": ["<carol-user-id>"]
}
```

| Field         | Type           | Required | Notes                                                                          |
|---------------|----------------|----------|--------------------------------------------------------------------------------|
| `title`       | string         | yes      | 1–200 characters after trimming whitespace.                                    |
| `description` | string         | no       | 0–4000 characters. Default `""`.                                               |
| `due_date`    | string \| null | no       | ISO date `YYYY-MM-DD`. Default `null`. Past dates allowed.                     |
| `status`      | string         | no       | One of `todo`, `in_progress`, `done`. Default `todo`. Ignored if set to anything other than `todo` on create. |
| `shared_with` | list[string]   | no       | List of `user_id` strings, all current members of the creator's team. Default `[]`. The creator is implicitly in the read-set as owner; do not include their own user_id. |

`team_id`, `owner_id`, `created_at`, `updated_at` are server-controlled and ignored if present. `team_id` is taken from the token claims; `owner_id` is the authenticated user; `created_at` and `updated_at` are `now()`.

### Responses

**201 Created** — task created at status `todo`; one `created` audit entry written; one `shared` audit entry per initial sharee, all in the same transaction within the 1-second SLA:

```json
{
  "id": "task-uuid",
  "team_id": "team-uuid",
  "owner_id": "creator-uuid",
  "owner_display_name": "Alice Member",
  "title": "Write release notes",
  "description": "Cover the 2.4 release.",
  "due_date": "2026-05-24",
  "status": "todo",
  "shared_with": ["<carol-user-id>"],
  "created_at": "2026-05-17T10:14:33.221Z",
  "updated_at": "2026-05-17T10:14:33.221Z"
}
```

**400 `validation_error`** — see envelope.

**503 `audit_unavailable`** — audit write exceeded the 1-second budget; transaction rolled back; no task created.

---

## `GET /tasks/{id}` — view a task

### Request

```http
GET /tasks/task-uuid HTTP/1.1
Authorization: Bearer <token>
```

### Responses

**200 OK** — same task shape as `POST 201`. Returned to owner, active sharee, or team admin of the task's team.

**404 `not_found` (byte-equivalent)** — task doesn't exist OR caller has no read access (cross-team outsider, in-team-non-rel).

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
  "status": "in_progress",
  "shared_with": ["<carol-user-id>", "<dan-user-id>"]
}
```

Every field optional. A field absent from the body is unchanged. Per FR-016 / Q2 = A semantics:

| Field         | Type                | Notes                                                                                                            |
|---------------|---------------------|------------------------------------------------------------------------------------------------------------------|
| `title`       | string              | 1–200 chars after trim. Cannot be `null`.                                                                        |
| `description` | string              | 0–4000 chars. Cannot be `null` (use `""`).                                                                       |
| `due_date`    | string \| null      | ISO date or `null` to clear.                                                                                      |
| `status`      | string              | One of `todo`, `in_progress`, `done`. Cannot be `null`. Free transitions in any direction.                       |
| `shared_with` | list[string] \| null | Owner-only. Full set replacement (not delta). `null` is treated as `[]`. Non-owner attempts → 400 `validation_error`. |
| `owner_id`    | any                 | **Rejected** with 400 `validation_error` (immutable).                                                            |
| `team_id`     | any                 | **Rejected** with 400 `validation_error` (immutable).                                                            |

### Behaviour

Per the PATCH → audit-entries decomposition (see research.md and data-model.md):

1. Validate the body.
2. Resolve the caller's relationship to the task. If `OUTSIDER` or `IN_TEAM_NONE` → byte-equivalent 404.
3. Authorise per the action matrix. `change_shared_with` requires `OWNER`; non-owner with `shared_with` in body → `400 validation_error` (`field_errors.shared_with`).
4. Compute the field diff (excluding `shared_with`) and the share-set diff.
5. If the union is empty → `200 OK` with the unchanged task body; no audit entries written.
6. Otherwise, in one `BEGIN IMMEDIATE … COMMIT`: UPDATE task, INSERT/DELETE in `task_shares`, INSERT audit rows (one `edited` if fields changed; one `shared` per added sharee; one `unshared` per removed sharee). COMMIT.
7. If the COMMIT exceeds 800 ms → `503 audit_unavailable`, rollback.

### Responses

**200 OK** — full updated task body (same shape as POST 201). Includes the up-to-date `shared_with` array.

**400 `validation_error`** — field-level failure (immutable field, non-owner `shared_with`, cross-team sharee, bad value, etc.).

**404 `not_found` (byte-equivalent)** — task doesn't exist or caller has no access.

**503 `audit_unavailable`** — audit write exceeded the 1-second budget.

---

## `DELETE /tasks/{id}` — delete a task

### Request

```http
DELETE /tasks/task-uuid HTTP/1.1
Authorization: Bearer <token>
```

### Authorisation

`OWNER` or `TEAM_ADMIN` (in the task's team). Any other relationship → byte-equivalent `404 not_found`. Specifically: a sharee attempting `DELETE` gets the byte-equivalent 404 (the sharee can `GET` so they know the task exists, but the 404 keeps the contract uniform — FR-011, FR-014).

### Behaviour

In one transaction:

1. Resolve the caller. Compute relationship.
2. If not `OWNER` or `TEAM_ADMIN` → byte-equivalent 404.
3. INSERT one `deleted` audit entry (`diff_summary = ""`).
4. DELETE FROM tasks (CASCADE removes task_shares).
5. COMMIT. On COMMIT timeout → 503.

### Responses

**204 No Content** — task deleted; audit trail preserved (FR-017). Subsequent `GET /tasks/{id}` returns byte-equivalent 404. Subsequent `GET /tasks/{id}/audit` continues to return the full chronological list including the `deleted` entry, accessible to anyone who had read access at the time of deletion (and team admins indefinitely).

**404 `not_found` (byte-equivalent)** — task doesn't exist or caller is not owner or admin.

**503 `audit_unavailable`** — audit write exceeded budget.

---

## `GET /tasks/{id}/audit` — view audit trail

### Authorisation

Any caller with `view_task` access (owner, active sharee, team admin in the task's team). Cross-team or in-team-no-rel → byte-equivalent 404 (FR-019).

For a deleted task, the audit endpoint continues to resolve and return the full audit trail. Access is granted to: (a) anyone who was in the read-set at the moment of deletion (owner, sharees-at-time-of-deletion, team admin); (b) the team admin indefinitely. This is achieved by storing `team_id` directly on each audit row (data-model.md): the access check looks at `team_id` and the deletion entry's actor history, not at the (deleted) `tasks` row.

### Responses

**200 OK**:

```json
{
  "task_id": "task-uuid",
  "events": [
    {
      "actor_user_id": "creator-uuid",
      "actor_display_name": "Alice Member",
      "actor_role": "member",
      "occurred_at": "2026-05-17T10:14:33.221Z",
      "operation": "created",
      "diff_summary": "title, description, due_date, shared_with"
    },
    {
      "actor_user_id": "creator-uuid",
      "actor_display_name": "Alice Member",
      "actor_role": "member",
      "occurred_at": "2026-05-17T10:14:33.221Z",
      "operation": "shared",
      "diff_summary": "sharee=carol-user-id"
    },
    {
      "actor_user_id": "carol-user-id",
      "actor_display_name": "Carol Sharee",
      "actor_role": "member",
      "occurred_at": "2026-05-17T11:02:08.554Z",
      "operation": "edited",
      "diff_summary": "status"
    },
    {
      "actor_user_id": "admin-uuid",
      "actor_display_name": "Brenda Admin",
      "actor_role": "team_admin",
      "occurred_at": "2026-05-19T09:30:00.000Z",
      "operation": "deleted",
      "diff_summary": ""
    }
  ]
}
```

Events are in chronological order. `actor_display_name` and `actor_role` are snapshots taken at the time of each event (FR-016).

**404 `not_found` (byte-equivalent)** — caller has no read access OR task doesn't exist.

## Invariants the contract is built to expose

| Invariant                                                                                       | Surfaced by                                                                                                                                             |
|-------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| OAuth bearer required + team_id/role from token (FR-001/FR-002, SC-005/SC-006)                  | `401 unauthenticated` from the boundary; no handler ever reads `team_id`/`role` from the body                                                            |
| Byte-equivalent cross-team and in-team-no-rel responses (FR-014, SC-003)                         | Single `responses.not_found_response()` helper; all four endpoints route through it for unauthorised access; identical `(status, content_type, content_length, body)` |
| Owner-only `shared_with` changes (FR-010, Q1 = A, SC-011)                                       | 400 `validation_error` with `field_errors.shared_with` for any non-owner caller that includes `shared_with`                                              |
| Sharee can edit but not delete (FR-011, Q3 = B, SC-004)                                         | Sharee PATCHing fields → 200 OK; sharee DELETE → byte-equivalent 404                                                                                     |
| Cross-team sharing forbidden (FR-012)                                                           | 400 `validation_error` with `field_errors.shared_with` enumerating each forbidden sharee                                                                 |
| Per-event audit semantics; one PATCH can yield multiple entries (FR-015/FR-016/FR-018, SC-007)  | Single-transaction INSERT of N audit rows alongside the task UPDATE; all 1-second-budget-bound; `503 audit_unavailable` on contention                     |
| Audit immutable + outlives task (FR-017, SC-009)                                                 | No UPDATE/DELETE SQL on `audit_entries`; no FK from `audit_entries.task_id` to `tasks`; deletion of a task is a recorded event, not a log truncation     |
| Audit visibility to owner / sharee / admin (FR-019)                                              | `permissions.is_allowed('view_audit', task)` uses the same relationship computation as `view_task`                                                       |
| Performance target (FR-021, SC-010)                                                              | WAL mode + tuned PRAGMAs + indexed read paths; smoke load test in `tests/task_sharing/test_performance.py`                                                |

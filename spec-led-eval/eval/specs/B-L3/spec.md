# Feature Specification: Multi-Tenant Task Management with Per-Task Sharing and Audit

**Feature Branch**: `008-task-sharing`
**Created**: 2026-05-17
**Status**: Draft
**Input**: User description: "Build a task management feature for a multi-tenant SaaS workspace. Each user is authenticated via OAuth 2.0 and belongs to exactly one team identified by team_id. Users have one of two roles: member or team_admin. Members can create, edit, delete, and view tasks they own; they cannot view or modify any task owned by another user, even within the same team, except where a task has been explicitly shared with them. Team admins can view, edit, and delete any task within their own team, but have no access to other teams' tasks. Cross-team data isolation must be absolute: the response payload for GET /tasks/{id} must be byte-equivalent for an unauthorised caller regardless of whether the requested task exists in a different team. Every mutation (create, edit, delete) must be appended to a task-level audit log within 1 second of the operation completing; entries record task_id, actor_user_id, actor_role, timestamp, operation, and a diff_summary. Audit entries are immutable. The API must sustain at least 200 requests per second per workspace at p99 latency ≤ 300ms. Endpoints: POST /tasks, GET /tasks/{id}, PATCH /tasks/{id}, DELETE /tasks/{id}, GET /tasks/{id}/audit." (Three scope-defining clarifications were resolved as: **Q1 = A** — sharing is owner-controlled and indefinite; only the task's owner may create or revoke a share; a share lives until revoked, the task is deleted, or the sharee leaves the team. **Q2 = A** — `diff_summary` is a field-name list (comma-separated string of field names; `sharee=<user_id>` for share events; empty for `deleted`); no pre-edit values stored. **Q3 = B** — a sharee may **view and edit** the task (no delete, no onward sharing).)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Member Creates a Private Task (Priority: P1)

A signed-in team member working in a multi-tenant SaaS workspace wants to record a piece of work that is, by default, **only visible to them**. They click "New task", enter a title (and optionally other fields), and save. The task is created in the user's team, owned by the creator, and **invisible** to every other member of the team — including other members — unless and until the owner explicitly shares it (see US3). Team admins of the same team **can** see it (US4); team admins of other teams cannot. The first audit entry is written within 1 second.

**Why this priority**: Without this story, no tasks exist; it is the indispensable first slice. The "private by default" semantics is the defining shape of 008 vs prior task-management features (007's team-tasks were visible to every team member by default).

**Independent Test**: A test member can create a task with a title; the task is visible to that member; another member of the **same team** (who is not an admin and is not a sharee) does not see the task in any read endpoint; a team admin of the same team does see it; the audit endpoint for the task contains exactly one entry (`created`) written within 1 second of the create response being returned.

**Acceptance Scenarios**:

1. **Given** an authenticated member of team T, **When** they create a task with a non-empty title (and optionally other fields), **Then** the system stores the task scoped to team T with the creator as owner, makes it visible **only** to the creator and to team-T admins (until shared), and writes the first audit entry within 1 second with `operation = "created"` and a `diff_summary` listing the fields supplied at creation (comma-separated field-name list).
2. **Given** an authenticated member of team T, **When** they attempt to create a task with an empty title or a title longer than 200 characters, **Then** the system blocks the submission with a field-level message and does not store the task or any audit entry.
3. **Given** a member of team T who is not the creator and not an admin and has not been shared the task, **When** they `GET /tasks/{id}` for that task, **Then** the system returns the byte-equivalent `404 not_found` response (the same bytes as for a task that does not exist).

---

### User Story 2 - Owner Edits and Deletes Their Own Task (Priority: P1)

A member returns to a task they own. They change its title, description, due date, or status; or they delete the task. Each mutation produces exactly one new audit entry within 1 second, capturing the operation and a `diff_summary` (a comma-separated field-name list of what changed). Members who are not the owner / sharee / admin cannot reach the task at all.

**Why this priority**: Without this story, tasks are write-once and never reflect actual progress. P1 alongside US1.

**Independent Test**: A test member who created a task can edit any field and save (each save adds an audit entry within 1 second; the `diff_summary` lists the changed fields); they can delete the task (the deletion produces a final `deleted` audit entry with empty `diff_summary`, and the task disappears from every read endpoint they have access to). A different non-sharee non-admin member of the team continues to see the byte-equivalent 404 throughout.

**Acceptance Scenarios**:

1. **Given** an authenticated owner of a task, **When** they `PATCH /tasks/{id}` with one or more field changes, **Then** the system applies the change, refreshes the task's last-updated timestamp, and writes **one** audit entry within 1 second with `operation = "edited"` and `diff_summary` equal to a comma-separated list of the fields that actually differ from the pre-PATCH state (e.g., `"title, status"`).
2. **Given** an authenticated owner of a task, **When** they `DELETE /tasks/{id}`, **Then** the system removes the task from every read endpoint, writes one final audit entry within 1 second with `operation = "deleted"` and an empty `diff_summary`, and preserves the task's full audit log (visible to anyone who could read the task before deletion, plus admins).
3. **Given** a member of team T who is not the owner, not a sharee, and not an admin, **When** they `PATCH` or `DELETE` `/tasks/{id}`, **Then** the system returns the byte-equivalent `404 not_found` response, the task is unchanged, and no audit entry is written.

---

### User Story 3 - Owner Shares a Task with Another Team Member (Priority: P1)

The owner of a task wants a teammate to be able to see and collaborate on the task. The owner shares the task with that teammate by adding their `user_id` to the task's `shared_with` list via `PATCH /tasks/{id}`. Once shared, the sharee can `GET` the task, `PATCH` any field (title, description, due_date, status) on it, and `GET /tasks/{id}/audit`. The sharee cannot `DELETE` the task and cannot themselves modify the share list. Only the owner can revoke a share (by removing the user from `shared_with`). Share creation and revocation are themselves audit-logged.

**Why this priority**: Without this story, the description's "except where a task has been explicitly shared with them" clause is dead text. Sharing is the only way to broaden a task's visibility short of admin override (US4). P1.

**Independent Test**: A test owner can `PATCH` their task with `{"shared_with": [<carol_id>]}`. Before this PATCH, Carol gets the byte-equivalent 404; after, Carol can `GET` the task (200 OK with full body) and `PATCH` any field. Carol attempting `DELETE` returns the byte-equivalent 404 (she is not part of the delete-allowed set). Carol attempting to add or remove someone from `shared_with` (including herself) returns `400 validation_error` (only owners change the share list). The audit trail contains an entry with `operation = "shared"` and `diff_summary = "sharee=<carol_id>"`.

**Acceptance Scenarios**:

1. **Given** an authenticated owner of a task, **When** they `PATCH /tasks/{id}` with `shared_with` including a new user_id who is a current member of the same team, **Then** the system records the new share, the sharee can subsequently `GET /tasks/{id}` and `PATCH` non-share-list fields; and the system writes one audit entry with `operation = "shared"` and `diff_summary = "sharee=<new_user_id>"` within 1 second of the response.
2. **Given** a sharee with an active share, **When** they `PATCH` the task with any non-share-list field change (title, description, due_date, status), **Then** the change is applied and one audit entry is written with `operation = "edited"` and a field-name-list `diff_summary` (the sharee is the `actor_user_id`, their role is recorded as their actual role — `member` or `team_admin`).
3. **Given** a sharee with an active share, **When** they `DELETE /tasks/{id}` or `PATCH` the task with a `shared_with` change, **Then** the system refuses the action: `DELETE` returns the byte-equivalent `404 not_found` (delete-not-permitted is indistinguishable from doesn't-exist for non-owners-non-admins); `PATCH` with `shared_with` returns `400 validation_error` with a field-level message naming `shared_with`.
4. **Given** an authenticated owner, **When** they `PATCH /tasks/{id}` with `shared_with` excluding a user that was previously in the list, **Then** the system removes the share, the previously-sharee user immediately receives the byte-equivalent `404` on subsequent `GET /tasks/{id}` requests, and the system writes one audit entry with `operation = "unshared"` and `diff_summary = "sharee=<former_sharee_id>"`.
5. **Given** sharing a task with a user outside the owner's team, **When** the owner `PATCH`es `shared_with` with that `user_id`, **Then** the system refuses the request with `400 validation_error` — cross-team sharing is not permitted in v1 (FR-012, Assumptions).
6. **Given** a team admin (not the owner), **When** they `PATCH /tasks/{id}` with `shared_with`, **Then** the system refuses with `400 validation_error` — only the owner may change the share list (Q1 = A), even though admins can edit any other field on any task in their team. The admin gets direct access to the task via FR-005 and does not need to be a sharee.

---

### User Story 4 - Team Admin Views, Edits, or Deletes Any Task in Their Team (Priority: P1)

A team admin of team T can see and act on every task in team T regardless of who owns it and regardless of whether it has been shared with them. They have no access whatsoever to tasks in any other team U ≠ T. They cannot, however, modify the `shared_with` list of a task they do not own (Q1 = A).

**Why this priority**: Explicit constraint in the user description. P1.

**Independent Test**: A test team-admin of team T can `GET`, `PATCH` (non-share-list fields), and `DELETE` any task in team T (their own, another member's unshared task, or a task shared with them). The same admin's request for a team-U task receives the byte-equivalent `404 not_found`. Every mutation by the admin produces an audit entry with `actor_role = "team_admin"`. A `PATCH` by the admin including `shared_with` is rejected with `400 validation_error`.

**Acceptance Scenarios**:

1. **Given** a team admin B of team T and any task owned by any member of team T (whether shared with B or not), **When** B `GET`/`PATCH`/`DELETE`s it (without setting `shared_with`), **Then** the action succeeds and an audit entry is written with `actor_role = "team_admin"` within 1 second.
2. **Given** a team admin B of team T and a task in team U (U ≠ T), **When** B attempts any operation on it, **Then** the system returns the byte-equivalent `404 not_found`, the task is unchanged, and no audit entry is written for it.
3. **Given** a team admin B and a task they do not own, **When** B `PATCH`es it with a `shared_with` value, **Then** the system refuses with `400 validation_error` naming `shared_with` (Q1 = A: only the owner may change shares).

---

### User Story 5 - Cross-Team Byte-Equivalent Isolation (Priority: P1)

A user of team T issues `GET /tasks/{id}` (or any other endpoint) for an `{id}` that belongs to team U, where U ≠ T. The system MUST return a response that is **byte-identical** (status code, headers under application control, body bytes) to the response it would return for an `{id}` that does not exist in the system at all. No information leaks about the existence of any task in any other team.

**Why this priority**: The user description elevates this to an explicit, absolute requirement. Multi-tenant SaaS leaks are reputation-ending; the test for this invariant is automated and run on every release. P1.

**Independent Test**: With three identifiers — `task-A` (owned by Alice in team T), `task-B` (owned by Bob in team U), and `task-C` (a UUID that has never existed) — Alice's `GET /tasks/task-B` and Alice's `GET /tasks/task-C` produce responses with the same HTTP status code, the same body bytes, the same `Content-Length`, and the same `Content-Type`. The same holds for `PATCH`, `DELETE`, and `GET …/audit`.

**Acceptance Scenarios**:

1. **Given** any authenticated user U-A whose team is T and any task `task-X` that does not belong to team T (whether `task-X` is in another team or simply does not exist), **When** U-A issues `GET /tasks/task-X`, **Then** the response status, body bytes, `Content-Length`, and `Content-Type` are identical across the two cases (task-in-other-team vs nonexistent-id).
2. **Given** the same setup, **When** U-A issues `PATCH /tasks/task-X`, `DELETE /tasks/task-X`, or `GET /tasks/task-X/audit`, **Then** the same byte-equivalence property holds across all four endpoints.

---

### User Story 6 - Audit Log Written Within 1 Second of Every Mutation (Priority: P1)

For every successful create / edit / delete / share / unshare on a task, the system writes one audit entry containing `task_id`, `actor_user_id`, `actor_role`, `timestamp`, `operation`, and `diff_summary`. The entry is durably persisted within 1 second of the response to the mutation being sent to the client. If the audit write cannot complete within 1 second, the mutation MUST roll back and return an error; under no circumstances does an observable state change exist without an audit entry.

A single `PATCH` request that produces multiple semantic events (e.g., changes the title **and** adds a sharee in one body) MUST produce one audit entry **per semantic event** (one `edited` entry for the title change plus one `shared` entry for the sharee addition), all written atomically with the task mutation; if any one of them would exceed the SLA, the whole request rolls back.

**Why this priority**: Explicit constraint in the user description; the audit log is the system's auditable history and SaaS-product compliance hinges on it. P1.

**Independent Test**: For every mutation endpoint, an integration test asserts that the audit entry / entries exist in storage within 1 second of the response. A separate test holds the audit storage in a contended state, fires a mutation, and asserts the mutation is rolled back with a `503 audit_unavailable` response and the task state is unchanged. A combined-edit-and-share PATCH writes exactly two audit entries in one transaction.

**Acceptance Scenarios**:

1. **Given** any successful create, edit, delete, share, or unshare, **When** the operation completes, **Then** within 1 second of the response being sent, an audit entry exists in storage with `task_id`, `actor_user_id`, `actor_role` (snapshotted at the time of the change), `timestamp` (UTC ISO 8601), `operation` ∈ {`created`, `edited`, `deleted`, `shared`, `unshared`}, and a `diff_summary` (field-name list).
2. **Given** the audit-write path is under contention and would exceed the 1-second budget, **When** a mutation is attempted, **Then** the system rolls back the task mutation and returns `503 audit_unavailable`; the task state is unchanged and no partial audit entry is visible to any reader.
3. **Given** a single `PATCH` that changes one or more fields **and** adds/removes one or more sharees, **When** the request succeeds, **Then** the system writes exactly one `edited` audit entry (with a field-name-list `diff_summary` of the changed fields) **plus** one `shared`/`unshared` entry per affected sharee, all in the same transaction within the 1-second budget.

---

### User Story 7 - Read the Task's Audit Trail (Priority: P2)

Any user with read access to a task (the owner, an active sharee, or a team admin) can fetch the task's audit trail and see who has done what to it.

**Why this priority**: P2 because the audit log is being *written* in the P1 stories — visibility is an enhancement that can ship in a follow-up release. If shipped later, the audit data is already being collected.

**Independent Test**: For any task in the caller's read-set, the audit endpoint returns the full chronological list of audit entries. For any task **not** in the caller's read-set (cross-team, or in-team-not-shared-with-them and they're not an admin), the audit endpoint returns the byte-equivalent `404 not_found`.

**Acceptance Scenarios**:

1. **Given** a task `task-X` and an authenticated caller who has read access to it (owner / active sharee / team admin), **When** they `GET /tasks/task-X/audit`, **Then** the system returns the full chronological list of audit entries, each containing every required field (FR-016).
2. **Given** a task and a caller who is **not** in the read-set, **When** they `GET /tasks/task-X/audit`, **Then** the response is byte-identical to a `GET` for a non-existent task id (FR-014 cross-team byte-equivalence extends to the audit endpoint).

---

### Edge Cases

- **Concurrent edits on the same task** by two callers (the owner and a sharee, or the owner and an admin): the last write wins; both writes succeed in sequence and both produce audit entries. There is no optimistic-locking conflict response in v1. The audit log is the source of truth for the order of events.
- **Audit-write SLA at the boundary**: the audit write(s) are atomic with the task mutation. If the combined write would exceed 1 second, the mutation rolls back; the client receives `503 audit_unavailable`; no observable state change exists without an audit entry (US6, SC-007).
- **OAuth token expiry mid-request**: a token valid at request arrival but that expires before the handler completes is treated as valid for the duration of the in-flight request. Per-request OAuth validation happens once at the boundary. A subsequent request with the same expired token gets `401`.
- **Sharing a task that is then deleted**: the share is no longer meaningful (the task is gone). The audit trail preserves both the original `shared` entry and the subsequent `deleted` entry. The (now-former) sharee, on `GET /tasks/{id}`, receives the byte-equivalent `404`.
- **Owner is removed from their team or has their team changed**: their existing tasks remain in the team they were created in (the task's `team_id` is immutable). Day-to-day operations fall to admins; the audit trail remains faithful. (Member team-change is the host product's responsibility; out of scope here.)
- **A team admin's role is downgraded to member**: they retain access only to tasks they own personally or are sharees on. Tasks they previously edited under admin authority are recorded in the audit log with `actor_role = "team_admin"` at the time of those edits (snapshot semantics).
- **Sharee being demoted out of the team while a share exists**: the share becomes inert because the cross-team isolation rule (FR-014) takes precedence; the sharee, now in a different team, receives the byte-equivalent `404`. The owner can clean up the dangling sharee_id entry on the next PATCH if they wish.
- **A user attempts to PATCH `owner_id`, `team_id`, or any other immutable field**: rejected with `400 validation_error` (FR-009).
- **A user attempts to PATCH `shared_with` while not being the owner**: rejected with `400 validation_error` naming `shared_with`. This is true even for team admins (Q1 = A).
- **A sharee attempts to `DELETE` the task**: rejected with the byte-equivalent `404` (the delete-allowed set is owner-or-admin only; Q3 = B).
- **`PATCH /tasks/{id}` with an empty body or a body containing only fields equal to the current values**: the request succeeds with `200 OK` and the full current task body, but **no audit entry is written** (the audit log is the source of truth for *changes*, not for *requests*).
- **Audit-trail entries themselves**: append-only; no API path updates or deletes them. Task deletion preserves the audit trail (FR-017).

## Requirements *(mandatory)*

### Functional Requirements

#### Authentication, identity, and team derivation

- **FR-001**: All API endpoints (`POST /tasks`, `GET /tasks/{id}`, `PATCH /tasks/{id}`, `DELETE /tasks/{id}`, `GET /tasks/{id}/audit`) MUST require an OAuth 2.0 bearer token in the `Authorization: Bearer <token>` header. Requests missing the header, malformed, or carrying an invalid/expired token MUST be rejected with `401 unauthenticated` **before** any business logic runs, and MUST NOT produce any audit entry.
- **FR-002**: The system MUST resolve every authenticated request to (a) a `user_id`, (b) a `team_id`, and (c) a `role` ∈ {`member`, `team_admin`}. All three MUST be taken from the introspected OAuth token's claims and never from the request payload. The user belongs to **exactly one team** — multi-team membership is **not** supported in v1.
- **FR-002a**: The system MUST treat the OAuth introspection result as the authoritative source for `team_id` and `role`. If those claims are missing or malformed, the request MUST be rejected with `401 unauthenticated`.

#### Permissions and visibility

- **FR-003**: A `member` of team T MAY: create tasks in team T (becomes owner); view, edit, and delete tasks they own; view and edit (but not delete) tasks where they are an active sharee. They MAY not change the `shared_with` list of any task they do not own (Q1 = A).
- **FR-004**: A `member` of team T MUST NOT be able to view, edit, or delete tasks they do not own and which are not actively shared with them — even within the same team.
- **FR-005**: A `team_admin` of team T MAY view, edit, and delete **any** task in team T, irrespective of ownership and sharing status. A `team_admin` MAY NOT change the `shared_with` list of a task they do not own (Q1 = A — share control is owner-only).
- **FR-006**: No user (member or team_admin) MAY view, edit, delete, or otherwise interact with any task in a team they are not a member of. The cross-team isolation rule (FR-014) is invariant under role and overrides admin privilege.

#### Task creation, content, and ownership

- **FR-007**: A task MUST have a non-empty title of 1–200 characters (whitespace-trimmed). A task MAY have a description (0–4000 characters), a due date (date-only, past dates allowed), and a status from the fixed set (FR-008).
- **FR-008**: The status set MUST be exactly `todo`, `in_progress`, `done` (Assumptions). Transitions are free in any direction. The initial status on creation is `todo`. Anyone with edit permission on a task (owner, sharee, team admin) MAY change its status as part of an edit.
- **FR-009**: Each task has exactly one `owner_id`, recorded at creation time and set to the creator (FR-002). The fields `owner_id` and `team_id` are **immutable** in v1; any PATCH that attempts to set them MUST be rejected with `400 validation_error`.

#### Per-task sharing (resolved Q1 = A, Q3 = B)

- **FR-010**: The task object MUST carry a `shared_with` field — an unordered set of `user_id` strings identifying users who currently have sharee access. The only way to modify `shared_with` is `PATCH /tasks/{id}` with a body containing the desired full new value of `shared_with`. **Only the task's owner** may modify `shared_with`; any other caller (sharee, team admin, anyone else) that includes `shared_with` in a `PATCH` body MUST be refused with `400 validation_error`. Shares are indefinite: they last until the owner removes the user_id from `shared_with`, the task is deleted, or the sharee leaves the owner's team.
- **FR-011**: A sharee — a user whose `user_id` is currently in a task's `shared_with` — MAY `GET /tasks/{id}`, `PATCH /tasks/{id}` with any subset of the editable fields (`title`, `description`, `due_date`, `status`) but **not** `shared_with`, `owner_id`, or `team_id`, and `GET /tasks/{id}/audit`. A sharee MAY NOT `DELETE` the task; a sharee `DELETE` MUST receive the byte-equivalent `404 not_found` (the same response a non-member of the read-set would receive — see FR-014 for the rationale).
- **FR-012**: Every `user_id` placed in `shared_with` MUST be a current member of the **same team** as the task owner at the time of the PATCH. Any attempt to share with a user in a different team MUST be rejected with `400 validation_error`. (This invariant holds the line on cross-team isolation even via the sharing path.)
- **FR-013**: Every successful change to `shared_with` MUST produce one audit entry per affected `user_id`: an entry with `operation = "shared"` for each newly-added sharee, and `operation = "unshared"` for each removed sharee, with `diff_summary = "sharee=<user_id>"` in each entry.

#### Cross-team isolation (byte-equivalent)

- **FR-014**: For **every** endpoint on `/tasks/{id}` (`GET`, `PATCH`, `DELETE`) and `/tasks/{id}/audit` (`GET`), if the caller does not have the read-or-act permission for the task identified by `{id}`, the system MUST return a response whose HTTP status code, response body bytes, `Content-Type` header, and `Content-Length` header are **identical** to the response for the same endpoint and method with a `{id}` that does not exist anywhere in the system. The "does not have permission" set includes: cross-team callers, in-team non-owner non-admin non-sharee callers, sharees attempting `DELETE`, and any caller for whom the task they reference is invisible. (Unauthenticated/invalid-token callers get `401`, not this 404 — distinct path.) The byte-equivalence requirement covers headers under the application's control; transport-layer headers (`Date`, etc.) are out of scope.

#### Audit trail (per-mutation, 1-second SLA, immutable; Q2 = A)

- **FR-015**: Every successful mutation on a task (create, edit, delete, share, unshare) MUST result in exactly one new audit entry per logical event. A `PATCH` that changes a field is one event (`edited`); a `PATCH` that adds a sharee is one event (`shared`); a `PATCH` that does both produces two entries (one `edited` and one `shared`). There MUST NOT be any successful state change without a matching audit entry, and there MUST NOT be any audit entry without a matching state change.
- **FR-016**: Each audit entry MUST contain: `task_id`, `actor_user_id`, `actor_role` snapshotted at the time of the change (`member` or `team_admin`), `timestamp` (UTC ISO 8601 with millisecond precision and `Z` suffix), `operation` (one of `created`, `edited`, `deleted`, `shared`, `unshared`), and `diff_summary` as a **comma-separated string of field names** (Q2 = A) according to the following shape rules:
  - `created` → `diff_summary` is the comma-separated list of fields that were supplied at creation, in canonical order: `title`, `description`, `due_date`, `status`, `shared_with`. (Fields not supplied are omitted.)
  - `edited` → `diff_summary` is the comma-separated list of fields whose values actually changed from the immediately preceding state, in canonical order.
  - `deleted` → `diff_summary` is the empty string.
  - `shared` and `unshared` → `diff_summary` is the literal string `"sharee=<user_id>"` for the affected sharee.
  Pre-edit field values are **not** stored in any audit entry (Q2 = A).
- **FR-017**: Audit entries MUST be **immutable**: there MUST be no API endpoint (and no role, including team_admin) that can update or delete an existing audit entry. Deletion of a task MUST preserve all of that task's audit entries (the `deleted` entry remains the latest entry, and earlier entries remain discoverable to anyone in the original read-set of the task).
- **FR-018**: Audit entries MUST be durably persisted within **1 second** of the mutation operation completing. If the audit write(s) would exceed the 1-second budget, the mutation MUST be rolled back and the request MUST return `503 audit_unavailable`; the task state MUST be unchanged and no partial audit entry MUST be visible to any reader. A `PATCH` that would produce N audit entries treats this as one combined write within the same 1-second budget; if any one of the N entries cannot be persisted in time, the whole transaction rolls back.
- **FR-019**: Audit entries MUST be readable via `GET /tasks/{id}/audit` by any caller who has read access to the task (owner, active sharee, or team admin of the task's team). The cross-team isolation rule (FR-014) extends to this endpoint: callers without read access receive the byte-equivalent `404`.
- **FR-020**: Audit entries MUST be retained for at least 12 months from the date of the entry (Assumptions — typical SaaS application-log retention). Tamper detection (e.g., chained-hash) is **out of scope** for this feature.

#### Performance

- **FR-021**: The system MUST be designed and tested so that, for a single workspace (i.e., one team's tasks), it can sustain at least **200 requests per second** with a p99 latency of **≤ 300 ms** at the API edge, measured under a representative mix of `GET /tasks/{id}` (60%), `PATCH /tasks/{id}` (20%), `POST /tasks` (10%), `GET /tasks/{id}/audit` (5%), and `DELETE /tasks/{id}` (5%).

### Key Entities *(include if feature involves data)*

- **User**: A person who can sign in via OAuth 2.0. Has a `user_id`, a `display_name`, exactly one `team_id`, and exactly one `role` ∈ {`member`, `team_admin`}. The user's team and role are read from OAuth introspection claims; this feature does not manage memberships or roles.
- **Team**: A SaaS-workspace grouping of users within which tasks live. Has an identity. Tasks belong to exactly one team; users belong to exactly one team.
- **Task**: A single unit of work owned by a single user in a single team. Carries: `task_id`, `team_id` (denormalised from the owner's team for the cross-team isolation invariant), `owner_id` (immutable), `title` (non-empty, ≤200 chars), `description` (≤4000 chars), `due_date` (optional, date-only), `status` (`todo` / `in_progress` / `done`), `shared_with` (set of `user_id` strings, all current members of `team_id`), `created_at`, `updated_at`.
- **Audit Entry**: An immutable append-only record of one mutation on one task. Carries: `task_id`, `actor_user_id`, `actor_role` snapshot (`member` / `team_admin`), `timestamp`, `operation` (`created` / `edited` / `deleted` / `shared` / `unshared`), `diff_summary` (a comma-separated field-name string or `"sharee=<user_id>"`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A team member can create a task with a title in under 30 seconds from opening the task UI.
- **SC-002**: A team member can edit a task they own or are a sharee on in under 15 seconds per change.
- **SC-003**: **Zero** occurrences in production where a caller without legitimate read access (cross-team, or in-team non-owner non-admin non-sharee, or sharee on `DELETE`) successfully receives any task data, audit data, or any response whose bytes differ from the byte-equivalent `404 not_found`. (Verified by automated probes that compare responses across `(task-in-other-team, in-team-not-shared, fabricated-id, sharee-on-delete)` quadruples for every endpoint.)
- **SC-004**: **Zero** occurrences in production where a non-owner, non-admin, non-sharee member of a team successfully edits a task in their team.
- **SC-005**: **Zero** occurrences in production where an unauthenticated request creates, edits, deletes, returns, or audits a task.
- **SC-006**: **Zero** occurrences in production where the actor's `team_id` or `role` is taken from the request payload rather than from the introspected OAuth token (verified by a static probe + an integration probe that injects a forged payload).
- **SC-007**: **Zero** observable state changes exist without a corresponding audit entry, and **zero** audit entries exist without a corresponding state change. (Reconciled periodically.)
- **SC-008**: 99% of audit entries are durably persisted within **1 second** of the corresponding mutation's response being sent; the remaining ≤1% of mutations roll back and return `503 audit_unavailable` rather than emit a state change with a deferred audit.
- **SC-009**: **Zero** occurrences in production where an audit entry, once written, is observed to have been updated or deleted within its 12-month retention window. (Enforced by code-path absence.)
- **SC-010**: At a single-workspace sustained load of **200 requests per second** across the mix defined in FR-021, p99 latency at the API edge is **≤ 300 ms**. (Measured by an automated load test in pre-production prior to each release.)
- **SC-011**: **Zero** occurrences in production where any caller other than the task owner successfully changes the `shared_with` list of a task. (Verified by automated probes across the role × caller-relationship matrix.)
- **SC-012**: At least 90% of users (members and admins) report (via post-launch survey) that the per-task sharing model gives them enough flexibility for their day-to-day collaboration.

## Assumptions

- **Authentication**: OAuth 2.0 bearer tokens are issued and validated by the host product's identity provider, which is out of scope for this feature. Introspection of a token returns the user's `user_id`, `team_id`, and `role`. The interface is the contract; the v1 implementation behind the seam is a stub.
- **One-team-per-user (per description)**: Each user belongs to exactly one team. Multi-team membership is **out of scope** for v1.
- **Team and membership management**: Creating teams, adding/removing users, and granting/revoking the `team_admin` role are the host product's responsibilities and **out of scope** here.
- **Ownership transfer (resolved as immutable per FR-009)**: A task's `owner_id` is **immutable** in v1.
- **Sharing mechanism (resolved Q1 = A)**: Owner-controlled, indefinite. Only the task's owner may add or remove sharees. Team admins, despite having full edit/delete privilege on any team task, do **not** have authority over the share list. Shares last until the owner removes the user, the task is deleted, or the sharee is no longer a member of the owner's team.
- **Sharee permissions (resolved Q3 = B)**: A sharee may view and edit the task (any of `title`, `description`, `due_date`, `status`). A sharee may **not** delete the task and may **not** modify `shared_with`, `owner_id`, or `team_id`. A sharee cannot share the task with someone else (no transitive shares).
- **`diff_summary` format (resolved Q2 = A)**: A comma-separated string of field names per the shape rules in FR-016. Pre-edit values are **not** preserved.
- **Cross-team sharing**: Out of scope for v1. Shares MUST target a user in the same team as the task owner (FR-012).
- **Group / link sharing**: Out of scope for v1. A share targets exactly one user.
- **Task content fields**: Title (1–200), description (0–4000), due_date (date-only, past dates allowed), status (`todo` / `in_progress` / `done`). No tags, priorities, attachments, subtasks, comments, time tracking, recurring tasks.
- **Notifications**: Out of scope for v1.
- **Search and listing**: The user description enumerates exactly five endpoints, none of which is a list endpoint. v1 ships **no** `GET /tasks` list endpoint; pagination, search, and filtering across all of a team's tasks are deferred to a future feature.
- **OAuth introspection seam**: v1 uses a stub introspector behind a `TokenIntrospector` interface matching RFC 7662 OAuth 2.0 Token Introspection, so a real introspection endpoint can drop in 1:1. Same pattern as feature 005.
- **Audit retention**: 12 months (typical SaaS application-log retention). Not FCA-style 6-year (see feature 005 for that regime).
- **Tamper detection on audit entries**: Out of scope for v1. Append-only is enforced by code-path absence (no UPDATE/DELETE path against `audit_entries`).
- **Time source**: All timestamps are UTC, ISO 8601, millisecond precision, explicit `Z`.
- **Concurrency**: Last-write-wins on concurrent task edits. No optimistic locking in v1; the audit log records both edits.
- **Identifier shape**: `task_id` and `user_id` are opaque UUID-shaped strings.
- **PATCH semantics**: A field absent from the body is unchanged. A field present with value `null` clears it (applies to `due_date`, `description`, and `shared_with` — though `shared_with: null` is equivalent to `shared_with: []`). `title` and `status` cannot be cleared.

## Out of Scope

- Team and team-membership management (host product responsibility).
- OAuth 2.0 token issuance, refresh, revocation, JWKS rotation; identity-provider configuration.
- Multi-team membership; cross-team admin / workspace-owner role.
- Cross-team sharing of tasks.
- Group / link sharing; share invitations that don't target a specific existing user.
- Ownership transfer between users in v1.
- Listing / search / pagination across tasks (no `GET /tasks` endpoint in v1).
- Comments, attachments, subtasks, dependencies, tags, priorities, time tracking, recurring tasks.
- Notifications (email / push / in-app).
- Bulk operations.
- In-app restore of deleted tasks.
- Customisable workflows / per-team status sets.
- Audit-log tamper detection / chained-hash (cf. feature 005).
- Forensic reconstruction of pre-edit field values from the audit log (Q2 = A explicitly excludes this).
- Member onboarding, sign-up, password reset.
- Cross-feature integration with prior task-management features (006, 007). 008 is independent.

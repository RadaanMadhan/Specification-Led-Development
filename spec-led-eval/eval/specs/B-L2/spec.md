# Feature Specification: SaaS Team Task Management with Audit Trail

**Feature Branch**: `007-team-tasks`
**Created**: 2026-05-17
**Status**: Draft
**Input**: User description: "Build a task management feature for a SaaS workspace where authenticated team members can create, edit, and delete tasks within their team. Each task is owned by the member who created it. Team admins can edit or delete any task in their team. Members cannot see or modify tasks belonging to other teams. The system must keep an audit trail of changes to each task, including who made the change and when." (Two scope-defining clarifications were resolved as: **Q1 = B** — multi-team membership; the current team is supplied on every request via the `X-Team-Id` header; the user must be a current member of that team. **Q2 = A** — per-edit-event audit trail; one entry per save, enumerating which fields changed; pre-edit values are **not** preserved.)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Member Creates a Task in Their Team (Priority: P1)

A signed-in team member working in a SaaS workspace wants to record a piece of work. They select which team they are working in (via their client's team-picker, which sets the `X-Team-Id` header on subsequent requests), open the team's task list, click "New task", enter a title (and optionally a description, due date, and assignee from the same team), and save. The task is created in the selected team, owned by the creator, and visible only to members of that team. Other members of the same team see it immediately on refresh; members of other teams never see it at all.

**Why this priority**: Without this story, no tasks exist; it is the indispensable first slice and the trigger for every other interaction.

**Independent Test**: A test member can sign in, set `X-Team-Id` to a team they belong to, create a task with a title, save, and see the task in that team's list. The task carries the creator's identity. A test member of a different team viewing their own list (different `X-Team-Id`) does not see the task.

**Acceptance Scenarios**:

1. **Given** an authenticated member with `X-Team-Id: T` set to a team T they belong to, **When** they create a task with a non-empty title (and optionally description, due date, and assignee from team T), **Then** the system stores the task scoped to team T, records the creator's identity and creation time, sets the owner to the creator, makes it visible to every member of team T, and writes the first audit-trail entry (`created`).
2. **Given** an authenticated member, **When** they attempt to create a task with an empty title or a title longer than 200 characters, **Then** the system blocks the submission with a field-level message and does not store the task.
3. **Given** a member creating a task with an assignee, **When** they pick the assignee, **Then** the assignee MUST be a current member of the **same team** (the one named by `X-Team-Id`); assignment to a member of another team or to a non-member is rejected with a field-level message.

---

### User Story 2 - Member Edits Their Own Task (Priority: P1)

A member returns to a task they previously created. They change its title, description, due date, assignee, or status. Each saved edit refreshes the task's last-updated timestamp, replaces the relevant fields, and appends **one** new entry to the task's audit trail capturing the actor, the timestamp, and which fields changed in that save.

**Why this priority**: Without this story, tasks are write-once and never reflect actual progress; this is the second half of the indispensable create-and-manage loop.

**Independent Test**: A test member who created a task can edit any field and save. The list reflects the change. The audit trail now contains the original `created` entry plus exactly one `modified` entry per save, attributed to the editor with the correct timestamp and a field-list in the change description.

**Acceptance Scenarios**:

1. **Given** a task created by member A in team T, **When** member A edits one or more fields (title, description, due date, assignee within team T, or status) in a single save, **Then** the system applies the change, refreshes `updated_at`, and appends **exactly one** audit-trail entry recording A as the actor, the current time, and a change description listing the fields modified (e.g., `"changed title, assignee"`).
2. **Given** any edit attempt, **When** the request omits required fields or violates a field-level rule (e.g., empty title, assignee from a different team), **Then** the system rejects it with `400 validation_error` and **does not** append an audit-trail entry or modify the task.

---

### User Story 3 - Member Deletes Their Own Task (Priority: P1)

A member realises a task they created is no longer needed and deletes it. The task disappears from every list, filter, search, and direct lookup within the team. The audit trail for that task is preserved (visible via the audit endpoint to anyone in the team) so admins and members can later see who created and deleted it.

**Why this priority**: Permanent removal is a normal part of "manage tasks" and one of the three operations the user description explicitly enumerates. P1.

**Independent Test**: A test member can delete a task they created. It no longer appears in the list or by direct id lookup. The audit endpoint for the task identifier still resolves and shows the original `created` entry plus a final `deleted` entry attributed to the deleter.

**Acceptance Scenarios**:

1. **Given** a task created by member A in team T, **When** member A deletes it, **Then** the system removes it from every team-T list and direct lookup, and appends one final audit-trail entry recording A as the actor, the current time, and `deleted`.
2. **Given** a deleted task, **When** any team-T member queries the audit endpoint by the deleted task's identifier, **Then** the system returns the full audit trail including the `deleted` entry.

---

### User Story 4 - Team Admin Edits or Deletes Another Member's Task (Priority: P1)

A team admin needs to clean up a teammate's stale task or correct it on their behalf. They open the team's task list, find the task (which they did not create), and either edit it or delete it. The audit trail records the admin's identity and their role at the time of the change.

**Why this priority**: The "admin can edit/delete any task in their team" rule is one of the four explicit constraints the user description states. Without admin override, the spec wording is not satisfied.

**Independent Test**: A test admin of team T can edit or delete a task created by a different member of team T and the action succeeds; the audit trail records the admin (not the original creator) as the actor and `admin` as the actor role on that change. The admin's role applies only within team T — see US6.

**Acceptance Scenarios**:

1. **Given** a task created by member A in team T and an admin B in team T (B ≠ A), **When** B edits or deletes the task, **Then** the system applies the action and appends one audit-trail entry recording B as the actor, `admin` as the actor role, and an appropriate change description.
2. **Given** the same setup, **When** B attempts to edit the task's `owner` (transfer ownership), **Then** the system rejects the request with `400 validation_error` because ownership is immutable in v1 (see Assumptions); the task is unchanged and no audit-trail entry is appended.

---

### User Story 5 - Member Lists and Finds Tasks in Their Team (Priority: P2)

A member opens their team's task list and sees every task in that team (theirs and other members'), ordered most-recently-updated first. They filter by status, by assignee ("mine" / "unassigned" / a specific teammate / "anyone"), and search by title substring. Filters can be combined and cleared.

**Why this priority**: P2 because the P1 stories deliver a working create/edit/delete loop without filtering; large-team usability benefits from this but it is not strictly required for MVP.

**Independent Test**: With ~30 seeded tasks across multiple statuses and assignees in team T, a test member of T (with `X-Team-Id: T`) can list, filter, and search and see only team-T tasks matching the criteria. A test member of team U sees no team-T tasks under any filter.

**Acceptance Scenarios**:

1. **Given** a team T with ≥1 task, **When** any member of T (with `X-Team-Id: T`) lists tasks with no filters, **Then** they see every team-T task ordered most-recently-updated first.
2. **Given** any combination of status, assignee, and title-substring filters, **When** the member applies them, **Then** the visible list is exactly the team-T tasks matching all active criteria.
3. **Given** any team-T list, **When** clearing all filters, **Then** the unfiltered team-T list is shown.

---

### User Story 6 - Cross-Team Isolation Invariant (Priority: P1)

A member of team T attempts (intentionally or by accident) to view, edit, or delete a task that belongs to team U, where T ≠ U. The system refuses the action and returns the same response as for a non-existent task identifier — no information about the other team's task leaks. Admin status in team T does **not** confer any access to team U.

**Why this priority**: This is the explicit "Members cannot see or modify tasks belonging to other teams" rule from the user description, and SaaS multi-tenancy is failure-mode-critical: a single cross-tenant leak undermines trust. P1.

**Independent Test**: With member A in team T and a task `task-u-001` in team U, an attempt by A (with `X-Team-Id: T`) to `GET`, `PATCH`, or `DELETE` `task-u-001` returns the same response as a `GET`/`PATCH`/`DELETE` on a fabricated identifier under `X-Team-Id: T`. The task is unchanged. No audit-trail entry is written.

**Acceptance Scenarios**:

1. **Given** member A acting with `X-Team-Id: T`, **When** they `GET /tasks/{id}` for an `{id}` that belongs to team U, **Then** the system returns `404 not_found` with the same body as for an identifier that does not exist anywhere; A cannot tell from the response whether team-U has a task with that id or not.
2. **Given** member A acting with `X-Team-Id: T` (even if A is an admin in T), **When** they `PATCH /tasks/{id}/...` or `DELETE /tasks/{id}` for an `{id}` in team U, **Then** the system returns `404 not_found`, the task in team U is unchanged, and no audit-trail entry is appended to it.
3. **Given** member A who happens to be a member of both teams T and U, **When** they act with `X-Team-Id: T` and reference a task that belongs to team U, **Then** the same 404 behaviour applies; the path to access the team-U task is to re-send the request with `X-Team-Id: U`.

---

### User Story 7 - Audit Trail Visibility (Priority: P2)

A team member opens a task and wants to see who has changed it and when. They click "History" and see a chronological list of audit-trail entries for that task: who created it, every edit and which fields changed, the final deletion (if any). Each entry shows the actor's name, their role at the time of the change, the timestamp, and the change description.

**Why this priority**: P2 because the audit log is being *written* in the P1 stories (US1–US4) — visibility to members is an enhancement on top of that. If shipped later, the audit data is still being collected and can be exposed in a follow-up release.

**Independent Test**: For any task in a team T that the caller is a member of (with `X-Team-Id: T`), a test member of T can fetch the audit trail and see every change in chronological order with actor + role + timestamp + change description. A member of team U sees the same 404 isolation response (US6).

**Acceptance Scenarios**:

1. **Given** any task in team T with N audit entries, **When** any member of T (including non-admin members, with `X-Team-Id: T`) requests the audit trail for that task, **Then** the system returns the N entries in chronological order, each containing the actor's identity (user_id and display name), the actor's role at the time of the change (`member` or `admin`), the timestamp (UTC ISO 8601), and a change description (which fields changed, or `created` / `deleted`).
2. **Given** the same setup, **When** a member of team U (or any non-member of T) requests the audit trail for the same task, **Then** the response is byte-identical to the response for a non-existent task id (US6 cross-team isolation extends to the audit endpoint).

---

### Edge Cases

- **Concurrent edits on the same task** by two members in two browser tabs: the last write wins; both writes succeed in sequence and both produce audit-trail entries. There is no optimistic-locking conflict response in v1; the audit trail itself is the source of truth for "what happened in what order".
- **An admin removes another member from team T** while that member has open tasks: those tasks' `owner` and `assignee` fields are preserved (the member's name still shows) but the removed member cannot be the target of new assignments. (Member-removal is handled by the host product's team-membership feature; out of scope here.)
- **The original creator is deleted/deactivated**: the task's `owner_id` is preserved (the audit trail remains accurate); the owner field is rendered as "(deactivated)" rather than the name. Edit / delete by the deactivated user is no longer possible because they cannot authenticate; admins remain able to edit/delete.
- **A task with a due date in the past**: not auto-closed; visible with the past date plainly. No notifications.
- **An unauthenticated request reaches the system**: rejected at the authentication boundary before any business logic runs; no task is read or written; no audit entry is appended.
- **A request without an `X-Team-Id` header**: rejected with `400 missing_team_context` before any business logic runs. No audit entry is appended.
- **A request whose `X-Team-Id` names a team the caller is not a member of**: rejected with `404 not_found` (byte-equivalent to a non-existent team_id) — the response does not reveal whether that team exists.
- **A title with leading/trailing whitespace**: trimmed at save time; stored title has no surrounding whitespace.
- **A description / title containing markdown or HTML-like text**: stored verbatim and rendered as plain text in the task list; no markup interpretation in v1.
- **An admin in team T attempts to act on a team-U task**: the cross-team isolation rule (US6) wins over admin privilege; the response is the same 404 as for any non-existent id.
- **Audit-trail entries themselves**: are append-only; there is no API path to update or delete an existing audit entry, and the deletion of a task does not delete its audit trail — only the task row.

## Requirements *(mandatory)*

### Functional Requirements

#### Authentication and team context

- **FR-001**: Every request that reads or writes tasks MUST be performed by an authenticated user. Unauthenticated requests MUST be rejected before any business logic runs and MUST NOT produce any audit entry.
- **FR-002**: The system MUST resolve the acting user's identity from the authentication context, never from the request payload.
- **FR-003**: Every request to a task or audit endpoint MUST carry an `X-Team-Id` header identifying the **current team context**. Requests missing the header MUST be rejected with `400 missing_team_context` before any business logic runs. Requests whose `X-Team-Id` value names a team the caller is not a current member of MUST receive the byte-equivalent `404 not_found` response (same as for a non-existent team identifier), so non-membership is indistinguishable from "no such team".
- **FR-004**: For every request that passes FR-001 / FR-003, the acting user MUST be a current member of the resolved team. Any task action against a different team is refused per the cross-team isolation rule (FR-014).

#### Team scope and permissions

- **FR-005**: Tasks belong to exactly one team, recorded at creation time. A task's team MUST NOT change after creation.
- **FR-006**: Each task has exactly one **owner**, recorded at creation time and set to the creator. The `owner_id` field MUST be immutable in v1; any request that attempts to change it MUST be rejected with `400 validation_error` (see Assumptions for the rationale).
- **FR-007**: A team has two member-level roles: **member** (default) and **admin**. A user can hold a different role in each team they are a member of (e.g., admin of team T, member of team U). Roles are managed by the host product's team-membership feature and are read from the resolved team context.
- **FR-008**: A **member** MAY create tasks in their team, view any task in their team, edit any task in their team that they own (i.e., are the creator of), and delete any task in their team that they own.
- **FR-009**: A **member** MUST NOT be able to edit or delete a task in their team that they do not own (only the owner or an admin can).
- **FR-010**: An **admin** MAY do everything a member can, plus edit and delete **any** task in their team (not just their own).
- **FR-011**: No role within team T grants any access (read or write) to any task that belongs to team U where U ≠ T. The cross-team isolation rule (FR-014) is invariant under role and overrides admin privilege.

#### Task creation, content, and assignment

- **FR-012**: A task MUST have a non-empty title of 1–200 characters (whitespace-trimmed). A task MAY have a description (0–4000 characters), a due date (date-only, past dates allowed), an assignee (a current member of the **same team**), and a status from a fixed set.
- **FR-013**: The status set MUST be exactly `todo`, `in_progress`, `done` (Assumptions). Transitions are free in any direction. The initial status on creation is `todo`. Members and admins with edit permission on a task MAY change its status as part of an edit.

#### Cross-team isolation invariant

- **FR-014**: For any caller and any task identifier, if the task does not belong to the caller's current team (the team named by `X-Team-Id`), the system MUST return the **same response** (status code and body) as for a non-existent task identifier under the same `X-Team-Id`. This applies to `GET`, `PATCH`, and `DELETE` on `/tasks/{id}` and to `GET /tasks/{id}/audit`. The response MUST NOT reveal whether the identifier refers to a task in another team or to no task at all.

#### Audit trail (per-edit-event)

- **FR-015**: Every task MUST have an append-only audit trail of changes. The audit trail's granularity is **per-edit-event**: one entry per save, regardless of how many fields changed in that save. Each audit entry MUST contain: the task's identifier, the actor's `user_id`, the actor's display name **as snapshotted at the time of the change** (so renames in the host product do not retroactively rewrite the audit log), the actor's role **at the time of the change** (`member` or `admin`), a UTC ISO 8601 timestamp, and a change description. The change description MUST take one of three shapes:
  - `"created"` for the entry written when a task is first saved.
  - `"changed <field>[, <field>]*"` for an edit that changed one or more fields (e.g., `"changed title"`, `"changed title, assignee"`). The list MUST enumerate exactly the fields whose values differ from the immediately preceding state. Pre-edit values are **not** stored in the audit entry.
  - `"deleted"` for the entry written when a task is deleted.
- **FR-016**: The audit trail MUST be immutable: there MUST be no API path (and no role) that can update or delete an existing audit entry. The deletion of a task removes the task row but preserves all of that task's audit entries (so the `deleted` entry remains discoverable along with every prior entry).
- **FR-017**: The audit trail for a task MUST be readable via a dedicated endpoint by any current member of the task's team (including non-admin members). Members of other teams MUST receive the cross-team isolation response (FR-014).
- **FR-018**: Audit entries MUST be retained for at least 12 months from the date the entry was written (typical SaaS application-log retention). Tamper detection (e.g., chained-hash) is **out of scope** for this feature; the append-only property is enforced by code-path absence (no UPDATE/DELETE path against the audit table).

#### Listing and filtering

- **FR-019**: The system MUST present any member of team T with a list of every task in team T, ordered most-recently-updated first.
- **FR-020**: The system MUST support filtering the list by status (`todo` / `in_progress` / `done` / `all`), by assignee (`mine` / `unassigned` / a specific team-T member / `anyone`), and by title substring (case-insensitive). Filters combine as a logical AND. Clearing filters returns the default unfiltered team-T list.

### Key Entities *(include if feature involves data)*

- **User**: A person who can sign in. Has an identity and a display name. Belongs to one or more teams via the host product's team-membership system; this feature does not manage memberships.
- **Team**: A SaaS-workspace grouping of users within which tasks are shared. Has an identity and a name.
- **Team Membership**: The (many-to-many) relationship between a user and a team, carrying the user's role in that team (`member` or `admin`). A single user may have several team memberships, each with its own role.
- **Task**: A single unit of work owned by a team. Carries: title (non-empty, ≤200 chars), description (≤4000 chars), due date (optional, date-only), assignee (optional team member), status (`todo` / `in_progress` / `done`), team (the owning team), owner (the creator, immutable), `created_at`, `updated_at`.
- **Audit Entry**: An append-only per-edit-event record of one save on one task. Carries: task identifier, actor user id, actor display-name snapshot, actor role snapshot (`member` / `admin`), timestamp, and change description (`"created"` / `"changed <fields>"` / `"deleted"`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A team member can create a task with a title (and optionally other fields) in under 30 seconds from opening the team's task list.
- **SC-002**: A team member can change a task's status, title, description, due date, or assignee in under 15 seconds per change.
- **SC-003**: At least 95% of members can locate a task by title substring in under 10 seconds, given the team has ≤500 active tasks.
- **SC-004**: **Zero** occurrences in production where a member can view, edit, delete, or read audit entries for a task in a team they are not a member of. (Verified by automated cross-tenant probes that compare responses across `X-Team-Id` values.)
- **SC-005**: **Zero** occurrences in production where a non-owner, non-admin member of a team successfully edits or deletes a task in their team. (Verified by automated probes.)
- **SC-006**: **Zero** occurrences in production where an unauthenticated request creates, edits, deletes, or returns a task or audit entry; and **zero** occurrences where a request lacking `X-Team-Id` reaches business logic.
- **SC-007**: **Zero** occurrences in production where a task change has no corresponding audit-trail entry, or where an audit-trail entry exists without a corresponding completed change. (Reconciled periodically.)
- **SC-008**: **Zero** occurrences in production where an audit entry, once written, is observed to have been updated or deleted within its 12-month retention window. (Enforced by code-path absence.)
- **SC-009**: At least 90% of admins report (via post-launch survey) that the audit trail gives them enough information to investigate a task's history without contacting individual members.

## Assumptions

The following defaults were chosen because each has a clear industry-standard or reasonable answer for a SaaS workspace; any of them can be tightened via `/speckit-clarify` later.

- **Authentication**: Users are already authenticated through the host product's existing identity system (session cookie or bearer token — implementation detail). This feature does not introduce sign-up, sign-in, or password flows.
- **Team membership management (resolved Q1 = B)**: Multi-team-per-user; the current team is supplied by the client on every request via the `X-Team-Id` HTTP header. The host product's team-membership feature manages who is in which team and with which role; this feature *reads* the relationship and *never* modifies it.
- **Audit-trail granularity (resolved Q2 = A)**: Per-edit-event; one entry per save. The change description enumerates which fields changed (`"changed title, assignee"`) but pre-edit values are **not** stored. Full forensic reconstruction of past values is not supported in v1; if a future feature needs it (e.g., for FCA-style compliance), see feature 005 for the chained-hash pattern.
- **Ownership transfer**: A task's `owner_id` is **immutable** in v1. If a member needs to "transfer" a task, the workflow is to delete and recreate (or to ask an admin to delete and recreate). v2 may introduce explicit transfer.
- **Status set**: Exactly three statuses: `todo`, `in_progress`, `done`. No customisable workflows.
- **Assignee count**: At most one assignee per task. No multi-assignee in v1.
- **Title / description length**: Title 1–200 chars; description 0–4000 chars.
- **Due date semantics**: Date-only (no time-of-day, no timezone agonising). Past due dates allowed.
- **Notifications**: Out of scope for v1. Members learn of changes by refreshing.
- **Search**: Title substring only in v1, case-insensitive. No description search.
- **Sort order**: Default is most-recent-edit-first.
- **Deletion is permanent for the task row**, but the audit trail (including the `deleted` entry) is preserved.
- **Conflict resolution on concurrent edit**: Last-write-wins. No optimistic locking in v1; concurrent edits each generate their own audit entry, so the trail is the source of truth for "what happened in what order".
- **Identifiers**: Tasks have opaque internal identifiers (UUID-like). No human-readable reference numbers in v1.
- **Audit-retention window**: 12 months (typical SaaS application-log retention). This is **not** an FCA-style regulated audit log; if a future feature requires longer retention or tamper detection, that is a separate spec (see 005).
- **Audit visibility**: Audit trail is readable by **any** member of the task's team (including non-admin members). This is the transparency default; a future feature could restrict it to admins only if business needs change.
- **No tamper detection on audit entries**: Append-only is enforced by code-path absence (no UPDATE/DELETE path against the audit table). Out-of-band DB tampering is not defended against in v1.
- **Actor display name and role snapshotting**: Audit entries store the actor's display name and role *as they were at the time of the change*, so subsequent renames or role changes do not retroactively rewrite history.

## Out of Scope

- Team and team-membership management (host product responsibility).
- Comments, attachments, subtasks, dependencies, tags, priorities, time tracking, recurring tasks.
- Email / push / in-app notifications; mentions inside descriptions.
- Bulk operations.
- Sort options beyond most-recently-updated-first; advanced search; full-text search; pagination.
- In-app restore of deleted tasks.
- Multi-assignee, watchers, followers.
- Customisable workflows / per-team statuses.
- Ownership transfer between members in v1.
- Member onboarding, sign-up, password reset.
- Audit-log tamper detection / chained-hash (cf. feature 005, which does require it).
- Cross-team admin (a "workspace owner" role above team admin).
- Forensic reconstruction of pre-edit field values from the audit log (Q2 = A explicitly excludes this).

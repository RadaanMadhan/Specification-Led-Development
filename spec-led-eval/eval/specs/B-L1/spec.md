# Feature Specification: Team Task Management

**Feature Branch**: `006-task-management`
**Created**: 2026-05-17
**Status**: Draft
**Input**: User description: "Build a feature where team members can create and manage tasks." (Three scope-defining clarifications were resolved as: **Q1 = A** — core v1 operations only [create, view, edit, change status, delete]; **Q2 = A** — single implicit workspace, every authenticated user is a member; **Q3 = A** — flat permissions, all members are peers.)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Member Creates a Task (Priority: P1)

A team member wants to record a piece of work that needs to be done. They open the task list, click "New task", give the task a short title, optionally add a longer description, optionally set a due date, optionally assign it to someone (themselves or another member), and save. The task appears immediately in the workspace task list at the default status ("todo"), with the creator recorded as the author and the current time recorded as the creation time.

**Why this priority**: Without this story, no tasks exist; it is the indispensable first slice and the trigger for every other interaction.

**Independent Test**: A test member can open the task list, create a task with a title (and optional fields), save, and see the task in the workspace task list with the correct title, status, and author. Other members see the same task when they refresh.

**Acceptance Scenarios**:

1. **Given** an authenticated member, **When** they create a task with a non-empty title (and optionally a description, due date, and assignee), **Then** the system stores the task with status "todo", records the author and creation time, makes it visible to every member in the workspace task list, and shows the creator a confirmation.
2. **Given** an authenticated member, **When** they attempt to create a task with an empty title or a title longer than 200 characters, **Then** the system blocks the submission with a field-level message and does not store the task.
3. **Given** a member assigning a task at creation time, **When** they pick an assignee, **Then** the assignee MUST be an existing member of the workspace; assignment to a non-member is rejected with a field-level message.

---

### User Story 2 - Member Updates a Task's Status and Fields (Priority: P1)

A member working on a task moves it through its lifecycle: from "todo" to "in_progress" when they start, and to "done" when they finish. They may also rename the task, edit its description, change its due date, or change its assignee at any point before it is "done". After the status reaches "done", the task is effectively closed; editing closed tasks is restricted (see Edge Cases).

**Why this priority**: Without this story, tasks are write-once and never reflect actual progress; the value of "manage" hinges on this. P1 alongside US1.

**Independent Test**: A test member can open an existing task, change its status from "todo" → "in_progress" → "done", edit its title and description, change its due date, and reassign it. Every other member sees the changes after refresh. An attempt to edit a task with status "done" without simultaneously transitioning it out of "done" is blocked.

**Acceptance Scenarios**:

1. **Given** a task with status "todo", **When** an authenticated member transitions it to "in_progress" (or directly to "done"), **Then** the system updates the status, records the change time, and the new status is visible to every member.
2. **Given** a task with status "in_progress", **When** an authenticated member transitions it to "done", **Then** the system updates the status and records the completion time.
3. **Given** a task at any status, **When** an authenticated member edits the title (≤200 chars, non-empty), description, due date, or assignee, **Then** the change is saved and visible to every member.
4. **Given** any task field edit, **When** the edit completes, **Then** the system records the editor and the edit time, replacing the previous `updated_at` value.
5. **Given** a closed (status "done") task, **When** any member attempts to edit any field (title, description, due date, or assignee) **without simultaneously** transitioning the task to "todo" or "in_progress" in the same request, **Then** the system blocks the edit with a message saying the task is closed and offering the option to reopen it.
6. **Given** a closed (status "done") task, **When** any member submits a single edit request that **simultaneously** sets `status` to "todo" or "in_progress" **and** changes one or more other fields, **Then** the system applies both changes atomically and the task moves out of "done".

---

### User Story 3 - Member Lists, Filters, and Finds Tasks (Priority: P1)

A member wants to see what is on their plate, or to find a specific task by title. They open the task list, which shows all of the workspace's tasks by default, ordered most-recently-updated first. They can filter by status (todo / in_progress / done / all), by assignee ("mine" / "unassigned" / a named member / anyone), and search by title substring. They can clear filters to return to the default view.

**Why this priority**: With more than a handful of tasks, the unfiltered list is unusable. Filtering and search are what makes "manage" practical, not just possible. P1.

**Independent Test**: With a seeded set of ~30 tasks across multiple statuses and assignees, a test member can: see them sorted most-recently-updated first; filter by status and see only tasks in that status; filter by "mine" and see only their assigned tasks; search by title substring and see only matching tasks; clear filters and return to the full list.

**Acceptance Scenarios**:

1. **Given** a workspace with ≥1 task, **When** any authenticated member opens the task list with no filters, **Then** they see every task in the workspace, ordered most-recently-updated first, regardless of who created or is assigned to it.
2. **Given** any combination of filter (status, assignee) and search (title substring), **When** the member applies them, **Then** the visible list is exactly the tasks that match all active criteria, with the same most-recently-updated-first ordering.
3. **Given** any active filter or search, **When** the member clears them, **Then** the list returns to the default unfiltered view.

---

### User Story 4 - Member Deletes a Task (Priority: P2)

A member realises a task is no longer needed (duplicate, misfiled, or simply abandoned). They delete it. The task is removed from the task list and no longer appears in any view. Deletion is permanent for v1 (no in-app restore); deletions are recorded so audit-style reconstruction is possible from logs outside this feature.

**Why this priority**: Useful but not strictly required for the create/manage loop; can ship after the P1 stories. Misfires are recoverable by the team simply recreating the task.

**Independent Test**: A test member can delete an existing task and confirm it no longer appears in any list, filter, or search; another member opening the list at the same moment sees the same absence after refresh.

**Acceptance Scenarios**:

1. **Given** any task, **When** any authenticated member confirms deletion, **Then** the task disappears from every view and is no longer addressable by its identifier.
2. **Given** a deletion attempt, **When** the system processes it, **Then** the deletion is recorded in operational logs (timestamp, deleter identity, task identifier, and task title at time of deletion); the in-app history of the task itself is not retained beyond the operational log.

---

### Edge Cases

- **Concurrent edits on the same task** by two members in two browser tabs: the last write wins; the loser's edit overwrites the earlier change without any conflict-resolution UI in v1. Each save replaces the previous `updated_at`, so members can see when the last change was made.
- **A task is "done", then a member changes their mind and reopens it**: any member can transition a "done" task back to "in_progress" (or "todo") through an ordinary status change request; if the same request also includes other field edits, both apply atomically (US2 acceptance #6).
- **Assignee is no longer an active member** (rare: the workspace's identity system reports them as deactivated): the existing assignment is preserved (the task still shows their name) but new assignments to that person are rejected. (Member deactivation is handled by the host product's identity system; out of scope for this feature.)
- **Task with a due date in the past**: the task is not auto-closed; it is shown in the list with the past due date visible to all members. No notifications are sent (out of scope).
- **An unauthenticated request reaches the system**: rejected at the authentication boundary before any business logic runs; no task is created, viewed, or modified.
- **A title with leading/trailing whitespace**: trimmed at save time; the stored title has no surrounding whitespace.
- **A description / title containing markdown or HTML-like text**: stored verbatim and rendered as plain text in the task list; no markup interpretation in v1.

## Requirements *(mandatory)*

### Functional Requirements

#### Authentication and identity

- **FR-001**: Every request that creates, edits, deletes, or views tasks MUST be performed by an authenticated member. Unauthenticated requests MUST be rejected before any task is created, modified, or returned.
- **FR-002**: The system MUST take the acting user's identity from the authentication context and never from the request payload (the payload's `created_by` or equivalent is ignored if present).

#### Workspace scope and permissions

- **FR-003**: All tasks reside in a **single implicit workspace**: every authenticated user is a member, every task is visible to every authenticated user, and there is no per-workspace picker, no Team entity, and no cross-workspace isolation rule in v1.
- **FR-004**: All authenticated members have **equal permissions** (flat peer model): any member MAY create a task, view any task, edit any field of any task (subject to the closed-task rule in FR-012), change any task's status, and delete any task. There is no role hierarchy, no admin tier, and no creator-only restriction in v1.

#### Task creation, content, and assignment

- **FR-005**: A task MUST have a non-empty title of 1–200 characters. Leading and trailing whitespace MUST be trimmed before validation and storage.
- **FR-006**: A task MAY have a description (free text, 0–4000 characters). Markdown and HTML-like text are stored verbatim and rendered as plain text (no markup interpretation in v1).
- **FR-007**: A task MAY have a due date (date only, no time-of-day). Due dates MAY be in the past; the system does not reject past due dates.
- **FR-008**: A task MAY have at most one assignee at any time, who MUST be a current member of the workspace at the time of assignment. A task MAY be unassigned.
- **FR-009**: On creation, the system MUST record the creator's identity and the creation timestamp; these MUST NOT change after creation.

#### Task management — status, edits, deletion

- **FR-010**: A task's status MUST be one of: `todo`, `in_progress`, `done`. The initial status on creation is `todo`. Any authenticated member MAY transition a task between any two of these three statuses (forward or backward, in any order). The system MUST record the timestamp of the most recent status change as part of `updated_at`.
- **FR-011**: Any authenticated member MAY change a task's title (subject to FR-005), description, due date, or assignee at any time, **except** that a task at status `done` MAY only be edited as part of a request that **simultaneously** transitions the task back to `todo` or `in_progress` in the same edit. The system MUST record the editor and the edit timestamp on every successful edit.
- **FR-012**: Any authenticated member MAY delete any task. Deletion is permanent; the task is removed from every list, filter, search, and direct lookup, and there is no in-app restore.

#### v1 manage scope (positive enumeration)

- **FR-013**: The "manage" scope for v1 consists of **exactly** the operations specified in FR-005 through FR-012: creating a task with title and optional fields; viewing tasks; editing the task's title, description, due date, assignee, and status; and deleting a task. Comments, attachments, subtasks, tags, priorities, time tracking, recurring tasks, and bulk operations are **out of scope** for v1 (see Out of Scope).

#### Listing, filtering, and search

- **FR-014**: The system MUST present any authenticated member with the list of every task in the workspace, ordered by most-recent-edit-or-status-change first, with no per-member visibility differences (all members see the same tasks).
- **FR-015**: The system MUST support filtering the list by status (one of `todo`, `in_progress`, `done`, or "all"), by assignee (one of "mine" / "unassigned" / a specific named member / "anyone"), and by title substring (case-insensitive substring match). Multiple filters MUST be applied as a logical AND.
- **FR-016**: The system MUST allow clearing all filters in one action and returning to the default unfiltered view.

#### History and observability

- **FR-017**: Every task MUST carry a `created_at` and an `updated_at` timestamp. `created_at` is set at creation and never changes; `updated_at` is set to the current time on every edit (field change, status change, or assignment change).
- **FR-018**: Deletions MUST be recorded in operational logs (out of in-app view): timestamp, deleter identity, task identifier, and task title at the moment of deletion. In-app deletion history beyond what the operational log provides is out of scope for v1.

### Key Entities *(include if feature involves data)*

- **Member**: A person who can sign in. Has an identity and a display name. Every authenticated user is a member of the single implicit workspace; there is no separate Team entity in v1.
- **Task**: A single unit of work in the workspace. Has a non-empty title (≤200 chars), an optional description (≤4000 chars), an optional due date, an optional assignee (a current member), a status (`todo` / `in_progress` / `done`), a creator (the member who created it), a `created_at` timestamp, and an `updated_at` timestamp.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A member can create a task with a title (and optionally description, due date, and assignee) in under 30 seconds from opening the task list.
- **SC-002**: A member can change a task's status, title, description, due date, or assignee in under 15 seconds per change.
- **SC-003**: At least 95% of members can locate a task by title substring in under 10 seconds, given the workspace has ≤500 active tasks.
- **SC-004**: The task list visibly reflects another member's create / edit / delete within 5 seconds of that member's action, on a refresh.
- **SC-005**: Zero cases occur in production where an unauthenticated request creates, edits, deletes, or returns a task.
- **SC-006**: 100% of tasks have a non-null `created_at` and `updated_at`; 100% of tasks have a status from the allowed set (`todo`, `in_progress`, `done`).
- **SC-007**: At least 90% of members report (via post-launch survey) that the task list helps them know what they need to work on next.

## Assumptions

The following defaults were chosen because each has a clear industry-standard or reasonable answer; any of them can still be challenged via `/speckit-clarify` later.

- **Authentication**: Members are already authenticated through the host product's existing identity system. This feature does not introduce sign-up, sign-in, or password flows.
- **Workspace scope (resolved Q2 = A)**: A single implicit workspace; every authenticated user is a member; every task is visible to every authenticated user. No Team entity, no per-workspace isolation rule.
- **Permission model (resolved Q3 = A)**: Flat — all members are equal peers. No role hierarchy.
- **v1 manage scope (resolved Q1 = A)**: Core operations only (create, view, edit, change status, delete). Comments, attachments, subtasks, tags, priorities, etc. are deferred to future features.
- **Status set**: Exactly three statuses for v1: `todo`, `in_progress`, `done`. No customisable workflows.
- **Assignee count**: At most one assignee per task. No multi-assignee, no watchers, no followers in v1.
- **Title / description length**: Title 1–200 chars; description 0–4000 chars.
- **Due date semantics**: Date-only (no time-of-day, no timezone agonising). Past due dates are allowed and shown plainly; no auto-close.
- **Notifications**: Out of scope for v1. Members learn of changes by refreshing the task list.
- **Search**: Title substring only in v1, case-insensitive. No description search, no full-text indexing.
- **Sort order**: Default is most-recent-edit-or-status-change first. A future feature can add user-controlled sort.
- **Deletion is permanent**: No in-app restore.
- **Conflict resolution on concurrent edit**: Last-write-wins. No optimistic locking or merge UI in v1.
- **Identifiers**: Tasks have opaque internal identifiers. No human-readable reference numbers in v1.
- **Member deactivation**: Out of scope for *this* feature; handled by the host product's identity system. Deactivated members keep their existing assignments but cannot be newly assigned.

## Out of Scope

- Comments / discussion threads on tasks.
- Attachments and file uploads.
- Subtasks, parent-child task relationships, dependencies, blockers.
- Tags, labels, custom fields.
- Priority levels (high/medium/low).
- Time tracking (estimates, logged time).
- Recurring tasks.
- Kanban / board view; calendar view; Gantt; reporting / dashboards.
- Email / push / in-app notifications; mentions (`@`) inside descriptions.
- Bulk operations (multi-select, bulk-status-change, bulk-delete).
- Sort options beyond the default most-recently-updated-first.
- Description-text search; full-text search; advanced query language.
- In-app restore of deleted tasks.
- Multi-assignee, watchers, followers.
- Customisable workflows / per-team statuses.
- Multiple teams / multi-workspace scope; team-membership management; admin / role tiers.
- Member onboarding, sign-up, password reset.

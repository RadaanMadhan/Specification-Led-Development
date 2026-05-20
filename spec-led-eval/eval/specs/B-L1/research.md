# Research: Team Task Management

**Branch**: `006-task-management` | **Date**: 2026-05-17

The spec has no remaining `[NEEDS CLARIFICATION]` markers — the three scope-defining questions were resolved by the user as **Q1 = A** (core ops only), **Q2 = A** (single implicit workspace), **Q3 = A** (flat peer permissions). With those settled, 006 is the simplest of the six features in this repo by some margin: no audit log, no role hierarchy, no cross-workspace isolation, no notifications, no OAuth 2.0 boundary, no tamper detection, no byte-equivalent unauthorised response. The interesting design decisions reduce to (1) carrying forward the established stdlib HTTP + SQLite pattern, (2) the closed-task PATCH rule from US2 #5/#6, and (3) the filter/search shape from US3.

## HTTP server: stdlib `http.server` (ThreadingHTTPServer)

**Decision**: As in every prior feature in this repo (002–005). `http.server.ThreadingHTTPServer` + dispatch in `server.py`. No framework.

**Rationale**: Constitution I. Five JSON endpoints with simple bodies do not justify a framework.

## Storage: stdlib `sqlite3`

**Decision**: SQLite via `sqlite3`. File-backed in normal runs; `:memory:` in tests. Schema and all SQL in `store.py`. One process-wide connection guarded by `threading.Lock`.

**Rationale**: Constitution I; consistent with prior features. The 006 schema is small (`users`, `tokens`, `tasks`, `task_deletions`) and has no structural enforcement beyond column CHECKs — there is no claim race, no in-flight uniqueness, no audit-chain, no partial unique index. Last-write-wins concurrency (Assumptions) means no version columns or optimistic-locking error envelope. The simplest schema we've produced in this repo.

## Authentication: bearer-token stub

**Decision**: `Authorization: Bearer <token>` on every request, resolved against a seeded `tokens` table to a `User`. Missing/invalid → `401 unauthenticated` before any handler logic runs.

**Rationale**: The host product's identity system is out of scope (Assumptions). The bearer stub is the smallest construct that satisfies FR-001 and is consistent with the rest of the repo. Unlike 005, there is no OAuth 2.0 introspection seam — Q1 = A keeps v1 narrow, and FR-001 says only that requests are "authenticated by the bank's existing authentication mechanism", whose wire-level shape is left to the host product. If a future feature introduces a real OAuth boundary, the stub introspector pattern from 005 can be borrowed.

## Authorisation: none, beyond "is the caller authenticated?"

**Decision**: With Q3 = A (flat peers), every authenticated user can do every operation. There is **no** permissions module. The single check in every handler is the `auth.authenticate(request)` call that returns either a `User` or raises `AuthError` (→ `401`). No `is_allowed(role, action, context)` predicate exists.

**Rationale**: Constitution VI (clarity over cleverness). Introducing a `permissions.py` with a single rule "yes, if authenticated" would be more code for less clarity. If a future feature adds roles (Q3 = B or Q3 = C in a later iteration), `permissions.py` can be added then, in one obvious place.

## Closed-task PATCH rule (US2 #5/#6, FR-011)

**Decision**: A single `PATCH /tasks/{id}` endpoint handles all edits. The service layer enforces the closed-task rule like this:

1. Load the task.
2. If `task.status == 'done'` and the request body does **not** include `status` set to `'todo'` or `'in_progress'`, return `409 task_closed`.
3. Otherwise apply all provided fields (title, description, due_date, assignee_id, status) in one `UPDATE` and one `updated_at` refresh.

In SQL, this is one conditional UPDATE: `UPDATE tasks SET <provided fields>, updated_at=? WHERE id=? AND (status != 'done' OR ? IN ('todo','in_progress'))`, where the second parameter is the requested status (or `NULL` if absent, which fails the `IN` check). `rowcount == 0` after the UPDATE plus a follow-up SELECT to distinguish `task_closed` from `not_found`.

**Rationale**: Avoids a two-request workflow ("first reopen, then edit") which would clutter the API and the UI. One PATCH that says "reopen and rename" is the natural shape.

**Alternatives considered**:
- **Refuse closed-task edits outright**: simpler but worse UX; the user would have to send two PATCH requests instead of one.
- **Implicit reopen on any edit to a closed task**: would silently move the task out of `done`, which is surprising. Requiring an explicit `status` change in the same body keeps the API self-describing.

## Listing, filtering, and search

**Decision**: `GET /tasks` accepts three query parameters:

- `status` ∈ {`todo`, `in_progress`, `done`, `all`} — default `all`.
- `assignee` ∈ {`mine`, `unassigned`, `<user_id>`, `anyone`} — default `anyone`. `mine` resolves to the caller's `user_id`.
- `q` — case-insensitive title substring; default unset.

All three combine as a logical AND in the WHERE clause. Results are ordered by `updated_at DESC`. The search uses `LOWER(title) LIKE LOWER('%'||?||'%')`, which is fine for the scale (≤500 active tasks per SC-003) and avoids a full-text index dependency. The result body has the shape `{"tasks": [task, ...]}`. No pagination in v1 (Out of Scope).

**Rationale**: FR-014 / FR-015 / FR-016 map 1:1 onto these three query parameters plus the default ordering. The substring search is intentionally simple because the spec caps the realistic workload at "≤500 active tasks" (SC-003); a full-text index would be premature.

## Deletion log: a SQLite table, no API endpoint

**Decision**: A `task_deletions` table captures every deletion as one append-only row: `task_id`, `deleter_user_id`, `task_title_at_deletion`, `deleted_at`. No API endpoint exposes this table; it is "out of in-app view" per FR-018. Operators inspect it via direct DB access.

**Rationale**: FR-018 says "operational logs", which a logfile would also satisfy, but a SQL table is testable (`test_service.py` asserts the row was written) and durable across process restarts in a way a logfile is not. The table has no `audit_entries`-style invariants — no chain, no immutability check, no API exposure — because the spec asked for an operational log, not an audit log.

**Alternatives considered**:
- **`logging.info` line to stderr only**: satisfies the FR but loses testability and durability across process restarts.
- **Soft-delete (a `deleted_at` column on `tasks`)**: would let an in-app restore exist, which the spec explicitly excludes (Out of Scope). Rejected.

## Identifier shape

**Decision**: Task identifiers are UUID4 strings. No human-readable references in v1 (Assumptions).

**Rationale**: Trivial and stdlib (`uuid.uuid4()`). The spec does not require a reference format.

## Project layout: `src/task_manager/` package

**Decision**: A new top-level package `src/task_manager/` parallel to the existing packages (`bank_transfer/`, `loan_application/`, `loan_workflow/`, `fca_loans/`). Tests under `tests/task_manager/`.

**Rationale**: 006 is a distinct feature with a different domain. Sharing a package with any of the loan features would entangle them. The internal module shape is the smallest in the repo — no `permissions.py`, no `notifications.py`, no `audit.py` — because the spec demands no role hierarchy, no notifications, and no audit chain.

**Note on the growing pile of near-identical packages**: this is the fifth (after `bank_transfer`, `loan_application`, `loan_workflow`, `fca_loans`) and the case for a shared `src/_common/` (HTTP dispatch, bearer auth, error envelope) is now strong. Extracting it is out of scope for this feature; flagged here for a future refactor.

## What is intentionally NOT researched

These are out of scope per the spec's Out of Scope and Assumptions:

- Comments, attachments, subtasks, dependencies, tags, priorities, time tracking, recurring tasks.
- Notifications (email, push, in-app).
- Mentions inside descriptions.
- Bulk operations.
- Sort options beyond most-recently-updated-first.
- Full-text or description-text search.
- In-app restore of deletions.
- Multi-assignee, watchers, followers.
- Multiple teams / multi-workspace scope (Q2 = A locks this to single workspace).
- Role hierarchy / admin tier (Q3 = A locks this to flat peers).
- Member onboarding and sign-in flows.

Optimistic locking and conflict-resolution UI are also out of scope (Assumptions: last-write-wins).

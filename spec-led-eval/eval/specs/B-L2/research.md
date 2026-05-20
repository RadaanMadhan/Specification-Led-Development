# Research: SaaS Team Task Management with Audit Trail

**Branch**: `007-team-tasks` | **Date**: 2026-05-17

The spec has no remaining `[NEEDS CLARIFICATION]` markers — Q1 was resolved to **B** (multi-team membership, current team via `X-Team-Id` header) and Q2 to **A** (per-edit-event audit). 007 sits between 006 (single workspace, flat perms, no audit) and 005 (FCA-grade audit + byte-equivalence) in complexity: it picks up multi-team isolation and an audit log from 005, but **without** the OAuth boundary, the tamper-detection chain, the 2-second SLA, the byte-equivalent body-bytes pinning, or the assignment workflow. The interesting design decisions reduce to (1) how the `X-Team-Id` boundary is resolved, (2) how the cross-team isolation rule is implemented uniformly, (3) the per-edit-event audit shape, and (4) the two-tier role check (member vs admin, with owner-only edit for members).

## HTTP server: stdlib `http.server` (ThreadingHTTPServer)

**Decision**: As in every prior feature in this repo (002–006). `http.server.ThreadingHTTPServer` + dispatch in `server.py`. No framework.

**Rationale**: Constitution I. Six JSON endpoints with simple bodies do not justify a framework.

## Storage: stdlib `sqlite3`

**Decision**: SQLite via `sqlite3`. File-backed in normal runs; `:memory:` in tests. Schema and all SQL in `store.py`. One process-wide connection guarded by `threading.Lock`. Schema covers `users`, `teams`, `team_memberships`, `tokens`, `tasks`, `audit_entries`.

**Rationale**: Constitution I; consistent with prior features. 007's schema is larger than 006's (new `teams` and `team_memberships` tables; new `audit_entries` table) but each row is conceptually simple. No partial unique indexes, no claim races, no conditional UPDATEs encoding a state machine — task status transitions are free in any direction (FR-013).

## Authentication: bearer-token stub + team-context resolver

**Decision**: Two-stage boundary check in `server.py` before any handler runs:

1. **Authentication** — `Authorization: Bearer <token>` resolved against the seeded `tokens` table. Missing/invalid → `401 unauthenticated`.
2. **Team context** — `X-Team-Id: <team_id>` resolved against `team_memberships(user_id, team_id)`. Missing header → `400 missing_team_context`. Present but the `(user_id, team_id)` pair is not in `team_memberships` → `404 not_found` with the **same body** as a nonexistent-task `404` (so non-membership is indistinguishable from "no such team"; FR-003).

The handler runs with `(user_id, team_id, role)` in scope, where `role ∈ {member, admin}` is read from `team_memberships.role`.

**Why the team-context check returns 404, not 403**: Returning `403 forbidden` would leak whether the supplied `team_id` exists in the system. The byte-equivalent `404` matches the same no-leakage principle FR-014 imposes on task ids; we extend it consistently to team ids.

**Alternatives considered**:
- **Path-based team scoping** (`POST /teams/{team_id}/tasks`): cleaner from a REST-purity standpoint, but Q1 = B's wording was explicitly "query parameter or header", and the header pattern keeps task URLs identical across teams (`/tasks/{id}`), which the cross-team isolation invariant (FR-014) implicitly assumes when it says "byte-equivalent to a non-existent task identifier" — a *task* id, not a team-scoped path.
- **Query parameter `?team_id=`**: equivalent to the header in semantics but more visible in client logs and easier to forget on POST/PATCH/DELETE bodies. Header is the more idiomatic SaaS choice.

## Authorisation: small explicit table with a per-task predicate

**Decision**: A `permissions.is_allowed(role, action, context)` function consults an explicit table. The interesting predicate is on edit/delete:

| Action                          | Required role | Per-action predicate                                                                                                  |
|---------------------------------|---------------|------------------------------------------------------------------------------------------------------------------------|
| `create_task`                   | `member`       | none                                                                                                                  |
| `list_tasks`                    | `member`       | none                                                                                                                  |
| `view_task`                     | `member`       | `task.team_id == caller.team_id` (otherwise → byte-equivalent 404 from FR-014)                                        |
| `edit_task` / `delete_task`     | `member`       | `task.team_id == caller.team_id AND (task.owner_id == caller.user_id OR caller.role == 'admin')`                       |
| `view_audit`                    | `member`       | `task.team_id == caller.team_id`                                                                                       |

`member` is the lowest privilege — admins trivially satisfy any check that requires `member`, so the role column is the minimum role needed. The interesting bit is the predicate: it encodes FR-008/FR-009/FR-010 (owner-or-admin) in one place.

Cross-team isolation (FR-014, FR-011) is encoded as the `task.team_id == caller.team_id` clause in every predicate. If that check fails, the service layer returns `None` and the handler converts it to a `404 not_found` via the `not_found_response()` helper.

**Why a per-action predicate rather than splitting "edit own" and "edit any" into two actions**: The spec asks "can this person edit this task?". One predicate that says yes-if-owner-or-admin is more readable than two actions plus a dispatcher.

## Cross-team isolation: a single `not_found_response()` helper

**Decision**: A canonical `responses.not_found_response()` returns:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8

{"error":"not_found","message":"No such task."}
```

Every code path that returns 404 — task not found, task in another team, team-id not a member's team, audit lookup on a cross-team task — uses this single helper. The body is identical across cases; the same response represents "doesn't exist" and "exists but you're not allowed to see it" indistinguishably.

This is the same pattern feature 005 used for FR-020 byte-equivalence, but **with one less guarantee**: 005 also pinned `Content-Length` and ran a dedicated probe over header bytes. 007's spec (FR-014) only requires the **status code and body** to be the same; we satisfy that and document that `Date`-style headers may differ. This is the SaaS-not-FCA framing.

**Tests**: `test_cross_team_isolation.py` constructs (own-team-task, other-team-task, fabricated-id) triples and asserts the 404 cases produce byte-identical bodies, and the GETable case produces a 200 with the expected payload.

## Audit trail (per-edit-event, Q2 = A)

**Decision**: One row in `audit_entries` per successful save. Each row carries the actor's `user_id`, **snapshotted** display name (`actor_display_name`) and role (`actor_role`), the timestamp, and a `change_description` string of one of three shapes (FR-015):

- `"created"` — written in the same transaction as the task INSERT.
- `"changed <field>[, <field>]*"` — written in the same transaction as the PATCH UPDATE. The field list is computed in `service.py` by diffing the in-memory pre-PATCH task against the proposed PATCH body and listing only the fields whose values actually differ. (A PATCH that happens to set every field to its current value writes no audit entry and the response carries an explanation; alternative: write `"changed (no-op)"`. Chosen: **no audit entry written**, with the PATCH still returning `200 OK` — the audit log is the source of truth for *changes*, not for *requests*.)
- `"deleted"` — written in the same transaction as the task DELETE. The task row is deleted; the audit entries are not (FR-016).

**Snapshot rationale**: FR-015 explicitly requires the display name and role to be captured at the time of the change. If a user is renamed in the host product six months after their edit, the audit entry continues to read "Alice Edited Title" rather than retroactively showing the new name.

**No pre-edit values stored**: Q2 = A deliberately excludes them. The change description says *which* fields changed but not *what they used to be*. This is the headline tradeoff vs. Q2 = B; if a future feature needs forensic reconstruction, 005's pattern is the reference.

**Atomicity**: every audit-writing operation (create, edit, delete) runs in a `BEGIN IMMEDIATE … COMMIT` transaction containing both the task mutation and the audit INSERT. If either fails, both roll back. SC-007 is the testable invariant.

**Append-only at two layers**: code-layer (no UPDATE/DELETE SQL targets `audit_entries` in `store.py`; a static grep probe in `test_invariants.py` enforces this) and at the runtime probe layer (`test_invariants.py` runs every endpoint as every role and asserts no audit row's content changes between snapshots).

## Status state machine

**Decision**: Same shape as 006 — three statuses (`todo`, `in_progress`, `done`), free transitions in any direction, no closed-task PATCH rule. (007 dropped the closed-task rule that 006 had; the spec is silent on it because admins can edit anything anyway and a "reopen" workflow is naturally a regular status change.)

## Listing and filtering

**Decision**: `GET /tasks` accepts three query parameters — `status`, `assignee`, `q` — combined as a logical AND, ordered `updated_at DESC`. Same shape as 006, scoped to the `X-Team-Id` team.

## Project layout: `src/team_tasks/` package

**Decision**: A new top-level package `src/team_tasks/` parallel to the existing five (`bank_transfer/`, `loan_application/`, `loan_workflow/`, `fca_loans/`, `task_manager/`). Tests under `tests/team_tasks/`.

**Rationale**: 007 is a distinct feature with materially different invariants from 006 (multi-team isolation, two-tier roles, audit log) and from 005 (no OAuth, no tamper detection, no SLA, smaller byte-equivalence guarantee). Sharing a package would entangle these.

**This is now the sixth near-identical-shape package in the repo**. The case for a shared `src/_common/` (HTTP dispatch, bearer-token plumbing, error envelope, `not_found_response()` helper) is no longer flag-worthy; it's overdue. Extracting it is out of scope for *this* feature but should be the first item in a follow-up cleanup feature. Constitution VI's "two duplications < premature abstraction" rule has been exceeded.

## What is intentionally NOT researched

These are out of scope per the spec's Out of Scope and Assumptions:

- OAuth 2.0 token issuance / refresh / revocation.
- Tamper-detectable audit log (chained-hash). For that pattern, see feature 005.
- 2-second audit-write SLA. The audit write *is* synchronous (same transaction), so it's bounded by SQLite write latency, but no explicit SLA is asserted or tested.
- Forensic pre-edit-value reconstruction from the audit log (Q2 = A excludes it).
- Ownership transfer.
- Notifications.
- Comments, attachments, tags, priorities, subtasks, time tracking, recurring tasks.
- Multi-assignee.
- Customisable workflows / per-team status sets.
- Pagination / advanced search.
- Member onboarding and sign-in flows.
- Cross-team admin / workspace-owner role.

# Implementation Plan: SaaS Team Task Management with Audit Trail

**Branch**: `007-team-tasks` | **Date**: 2026-05-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/007-team-tasks/spec.md`

## Summary

A small Python 3.11+ HTTP backend service exposing six endpoints — `POST /tasks`, `GET /tasks`, `GET /tasks/{id}`, `PATCH /tasks/{id}`, `DELETE /tasks/{id}`, `GET /tasks/{id}/audit` — that implements a multi-team SaaS task tracker with strict cross-team isolation, a two-tier per-team role model (`member` / `admin`), creator-ownership (immutable in v1), and a per-edit-event audit trail. Every request carries an `X-Team-Id` header that names the caller's current team (Q1 = B); a missing header → `400 missing_team_context`, a non-member team_id → byte-equivalent `404 not_found`. Members can edit/delete tasks they own; admins can edit/delete any task in their team; no role in team T grants any access to team U. The audit log records one entry per save (Q2 = A) with a change description of `"created"` / `"changed <fields>"` / `"deleted"`; pre-edit values are not stored. The audit entries are append-only at the code layer (no UPDATE/DELETE path) and outlive the task they describe (no FK from `audit_entries.task_id` to `tasks.id`), so the `deleted` entry remains discoverable. Built on the Python standard library only (`http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`). The cross-team isolation rule (FR-014) is enforced by a single `responses.not_found_response()` helper used at every cross-team or non-existent code path, producing identical bytes (`status + body`). The owner-or-admin edit/delete rule (FR-008–FR-010) lives as one predicate in `permissions.py`. The audit-trail per-edit-event shape, including actor display-name and role snapshotting (FR-015), is computed in `service.py` and persisted in the same transaction as the task mutation.

## Technical Context

**Language/Version**: Python 3.11+
**Primary Dependencies**: None at runtime (standard library only — `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `typing.Protocol`, `urllib.request` (tests only)). Dev-only: `pytest`, `ruff`.
**Storage**: SQLite via stdlib `sqlite3`. File-backed for `python -m team_tasks.server` runs; `:memory:` for tests. One process-wide connection guarded by `threading.Lock`. Six tables: `users`, `tokens`, `teams`, `team_memberships`, `tasks`, `audit_entries`. Composite PK on `team_memberships(user_id, team_id)`. Every read query on `tasks` and `audit_entries` includes `team_id = ?` in its WHERE clause (the structural enforcement of FR-014). The `audit_entries` table has no FK to `tasks` (so audit entries outlive their task per FR-016) but does have a FK to `teams` (so cross-team isolation on the audit endpoint is a single WHERE clause).
**Testing**: pytest. End-to-end tests start a real `ThreadingHTTPServer` on an ephemeral port and hit it with `urllib.request`. Dedicated suites cover the cross-team isolation invariant (`test_cross_team_isolation.py`), the per-edit-event audit shape and append-only invariant (`test_audit.py`), the owner-or-admin matrix (`test_permissions.py`), and the team-context boundary (`test_team_context.py`). The 403-vs-404 split (in-team-non-owner-non-admin → 403; cross-team → 404) is asserted explicitly in `test_permissions.py`.
**Target Platform**: Local developer machine (macOS / Linux), Python 3.11+. PoC, not a production deployment.
**Project Type**: HTTP backend service (single project), parallel to the existing five packages.
**Performance Goals**: Not in scope at the timing level. SC-003 ("locate a task in under 10 seconds at ≤500 active tasks per team") is trivially satisfied by `LOWER(title) LIKE LOWER('%'||?||'%')` over the team-scoped index.
**Constraints**: Standard library only (Constitution I). No web framework. No OAuth 2.0 token-introspection boundary (auth is the bearer-token stub from prior features — the spec is silent on the wire-level auth mechanism, so we use the established pattern). No tamper detection on the audit log (out of scope — see feature 005 for that pattern). No 2-second audit SLA (audit write is synchronous in the same transaction). 12-month audit retention is satisfied by the absence of any DELETE code path against `audit_entries`.
**Scale/Scope**: PoC. ≤2 seeded teams, ≤5 seeded users (with overlapping memberships including a dual-team user, an admin in each team, and an outsider), ≤3 seeded tasks. Approximately 900–1,200 LOC across `src/team_tasks/`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Initial check (pre-Phase 0)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | No runtime dependencies planned. All modules listed in Primary Dependencies are stdlib. |
| II. Test Every Module | PASS | Every module planned under `src/team_tasks/` has a corresponding `tests/team_tasks/test_*.py` (see Project Structure). Plus four invariant-focused suites: cross-team isolation, per-edit-event audit, owner-or-admin permission matrix, team-context boundary. |
| III. PEP 8 and Type Hints | PASS | All public functions/methods will carry type hints with modern syntax (`str \| None`, etc.). Linted with ruff. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | The deliverable is an HTTP service. The `python -m team_tasks.server` runner is a thin CLI wrapper exposing `--help`, `--seed`, `--json`, `--port`, `--db-path` with errors on stderr. With `--seed --json` the seeded fixture is emitted as JSON; without `--json` it is printed as a human-readable table. |
| V. Explicit Error Handling | PASS | Every failure mode in the spec maps to a typed exception in `errors.py` (`AuthError`, `MissingTeamContext`, `PermissionDenied`, `NotFound`, `ValidationError`) and a documented HTTP status code. No bare `except`. SQLite errors propagate with context. The cross-team-isolation not-found is not a typed exception — it is a *response shape* produced by the handler when the service layer returns `None` for an unauthorised read. |
| VI. Clarity Over Cleverness | PASS | Module count is 11 — between 006 (9) and 005 (11). Each module has a single responsibility. The owner-or-admin rule lives as one predicate in `permissions.py`. The cross-team isolation rule is enforced by one helper in `responses.py` plus a `team_id = ?` clause in every SQL query in `store.py`. The per-edit-event audit shape is computed in one function in `service.py` (`build_change_description`). No metaclasses, decorators-as-DSL, or hand-rolled framework. |

No violations. Initial gate passed.

### Post-design re-check (after Phase 1)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | Phase 1 design did not introduce any non-stdlib dependency. |
| II. Test Every Module | PASS | Every module in the Project Structure below has a matching `tests/team_tasks/test_*.py`. The contract documents 14 numbered smoke-test steps in `quickstart.md` covering every endpoint × happy/failure combination across the role-set + team-membership matrix. |
| III. PEP 8 and Type Hints | PASS | Data classes and enums in `data-model.md` use `StrEnum` and modern type-hint syntax (`str \| None`, composite PKs in dataclass form). |
| IV. Dual-Format CLI Output | PASS (scope-limited) | `quickstart.md` documents `--seed`, `--json`, `--help`, `--port`, `--db-path`. |
| V. Explicit Error Handling | PASS | The HTTP API contract (`contracts/http-api.md`) enumerates every error code and the precise condition that raises it; the `errors.py` types map 1:1 to those codes. The 403-vs-404 split (in-team-but-not-permitted → 403; cross-team or not-a-member → 404 byte-equivalent) is called out explicitly. |
| VI. Clarity Over Cleverness | PASS | Phase 1 added no extra layers. The six endpoints in the contract map directly to six service-layer functions (`create_task`, `list_tasks`, `get_task`, `update_task`, `delete_task`, `get_audit`); the permission rules, the audit-description builder, the team-context resolver, and the byte-equivalent not-found helper are each in one obvious place. |

No violations after design. Post-design gate passed.

## Project Structure

### Documentation (this feature)

```text
specs/007-team-tasks/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── http-api.md
├── checklists/
│   └── requirements.md
└── tasks.md            # Generated by /speckit-tasks (NOT this command)
```

### Source Code (repository root)

```text
src/
├── bank_transfer/                # Existing — 002 feature; unchanged.
├── loan_application/             # Existing — 003 feature; unchanged.
├── loan_workflow/                # Existing — 004 feature; unchanged.
├── fca_loans/                    # Existing — 005 feature; unchanged.
├── task_manager/                 # Existing — 006 feature; unchanged.
└── team_tasks/
    ├── __init__.py
    ├── __main__.py               # Entry point: python -m team_tasks
    ├── server.py                 # ThreadingHTTPServer wiring + request dispatch + auth boundary + team-context boundary + CLI (argparse: --seed, --json, --port, --db-path)
    ├── handlers.py               # Per-endpoint request handlers (parse, authorize via permissions table, call service, format response)
    ├── responses.py              # Canonical response builders. `not_found_response()` returns the fixed byte-equivalent envelope used at every cross-team and non-existent code path (FR-014, FR-017)
    ├── auth.py                   # Bearer-token resolution; `AuthenticatedCaller` dataclass carrying `(user_id, team_id, role)` after both boundary checks pass
    ├── permissions.py            # Single explicit (action) → (required role + predicate(context)) table. Encodes FR-008/FR-009/FR-010 as `(task.owner_id == caller.user_id OR caller.role == 'admin')` in one place
    ├── service.py                # Business logic: create_task, list_tasks, get_task, update_task, delete_task, get_audit. Returns `None` for any not-authorised-to-see case (handler converts via `not_found_response()`). Contains `build_change_description(old, new) -> str` for the per-edit-event audit shape
    ├── validation.py             # Field-level validation; reports all errors at once (FR-012); explicitly rejects any `owner_id` in PATCH body (FR-006)
    ├── store.py                  # SQLite schema, connection, all SQL. Every read query includes `team_id = ?`. No UPDATE/DELETE code path against `audit_entries`. No FK on `audit_entries.task_id` — entries outlive the task (FR-016)
    ├── models.py                 # Dataclasses: User, Token, Team, TeamMembership, Task, AuditEntry; Role, TaskStatus enums
    └── errors.py                 # AuthError, MissingTeamContext, PermissionDenied, NotFound, ValidationError

tests/
└── team_tasks/
    ├── __init__.py
    ├── conftest.py               # Fixtures: in-memory DB, two seeded teams, five seeded users with overlapping memberships (incl. a dual-team user and an outsider), several seeded tasks across both teams, ephemeral-port server
    ├── test_auth.py              # Bearer-token resolution; 401 paths; ensures no business logic runs on a 401
    ├── test_team_context.py      # `X-Team-Id` parsing; missing → 400; non-member team_id → byte-equivalent 404; valid → handler runs with `(user_id, team_id, role)`
    ├── test_permissions.py       # Exhaustive (role × owner-or-not × action) matrix. Explicitly tests the 403-vs-404 split (in-team-non-owner-non-admin → 403; cross-team → 404 byte-equivalent)
    ├── test_validation.py        # Per-field validation; per-field error reporting; owner_id immutability rejection (FR-006)
    ├── test_service.py           # Business logic — create, list (with filters), view, edit (with diff-based audit description), delete (with audit-preserving deletion) — against in-memory DB
    ├── test_store.py             # Schema, CHECK constraints, FK behaviour, composite PK on `team_memberships`, append-only on `audit_entries` (static SQL probe + runtime probe)
    ├── test_handlers.py          # HTTP-level: status codes, response shapes, error envelopes; X-Team-Id round-tripping through every endpoint
    ├── test_filtering.py         # All combinations of `status` / `assignee` / `q` filters; AND semantics; default ordering by `updated_at DESC`; team-scoping (a filter that would match a task in another team must not return it)
    ├── test_cross_team_isolation.py  # Constructs (own-team-task, other-team-task, fabricated-id) triples; asserts byte-equivalent (status, body) tuples pairwise on every reading endpoint (FR-014, SC-004)
    ├── test_audit.py             # Per-edit-event semantics: one entry per save; empty-diff PATCH writes no entry; change_description shapes; actor display-name and role snapshotted at the time of the change; audit survives task deletion (FR-015, FR-016, FR-017, SC-007)
    └── test_invariants.py        # SC-004…SC-008 catch-all probes including a runtime audit-immutability scan and the no-cross-feature-regression check
```

**Structure Decision**: A new top-level package `src/team_tasks/` parallel to the five existing packages. The internal module shape adds three modules over the simplest features (006):

- `responses.py` — for the byte-equivalent not-found helper (new in 007).
- `permissions.py` — re-introduced (absent in 006 because flat-peer perms didn't need it; needed here for the owner-or-admin rule).
- An `audit_entries` table and a `build_change_description` helper in `service.py` (no separate `audit.py` module — the chained-hash machinery from 005 is out of scope here, so a single helper function suffices).

**This is the sixth near-identical-shape package in the repo**. Constitution VI's "two duplications < premature abstraction" rule has been comfortably exceeded; a shared `src/_common/` (HTTP dispatch, bearer-token plumbing, error envelope, `not_found_response()` helper, validation primitives) is **overdue**. Extracting it is out of scope for *this* feature, but should be the first thing in a follow-up cleanup feature. Research.md and quickstart.md both flag this.

The separation between `service.py` (business logic, DB-aware, returns `None` for not-authorised-to-see) and `handlers.py` (HTTP-aware, converts `None` → byte-equivalent not-found, applies the 403-vs-404 split based on whether the caller is in-team-but-not-permitted or cross-team) is what lets unit tests exercise the cross-team isolation invariant without standing up a real server, while `test_cross_team_isolation.py` confirms the HTTP layer reproduces the same response bytes.

## Complexity Tracking

No violations to justify.

007 sits between 006 (single workspace, flat perms, no audit — simplest) and 005 (FCA-grade audit + tamper detection + byte-equivalence with header-pinning — most complex). It picks up multi-team isolation and an audit log from 005, but **deliberately drops** the chained-hash tamper detection, the 2-second SLA, the OAuth 2.0 introspection seam, and the Content-Length-pinned byte equivalence. Each of those is out of scope per the SaaS-not-FCA framing in Assumptions.

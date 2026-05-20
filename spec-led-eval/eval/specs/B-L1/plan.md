# Implementation Plan: Team Task Management

**Branch**: `006-task-management` | **Date**: 2026-05-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/006-task-management/spec.md`

## Summary

A small Python 3.11+ HTTP backend service exposing five endpoints — `POST /tasks`, `GET /tasks`, `GET /tasks/{id}`, `PATCH /tasks/{id}`, `DELETE /tasks/{id}` — that implements a single-workspace, flat-permission team task tracker. Every authenticated member can create, view, list-and-filter, edit, change the status of, and delete any task. The status set is exactly three values (`todo`, `in_progress`, `done`); transitions are free in any direction. The only non-trivial rule beyond field validation is the closed-task edit rule (FR-011): a PATCH on a `done` task must include a `status` change to `todo` or `in_progress` in the same request, or the request is rejected with `409 task_closed`. Built on the Python standard library only (`http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`); no web framework, no ORM. The design is intentionally the leanest of the six features in this repo — there is **no** permissions module (Q3 = A — flat peers; the only authz check is "is the caller authenticated"), **no** team / workspace entity (Q2 = A — single implicit workspace), **no** audit log, **no** tamper detection, **no** OAuth boundary, **no** byte-equivalence requirement, **no** notification system, and **no** in-flight uniqueness or claim-race invariants. The `task_deletions` table provides the operational deletion log (FR-018); it has no API endpoint and is read by operators via direct DB access. Last-write-wins concurrency (Assumptions) means no optimistic-locking error envelope and no version columns.

## Technical Context

**Language/Version**: Python 3.11+
**Primary Dependencies**: None at runtime (standard library only — `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `urllib.request` (tests only)). Dev-only: `pytest`, `ruff`.
**Storage**: SQLite via stdlib `sqlite3`. File-backed for `python -m task_manager.server` runs; `:memory:` for tests. One process-wide connection guarded by `threading.Lock`. Four tables: `users`, `tokens`, `tasks`, `task_deletions`. Three indexes on `tasks` (by `updated_at`, by `assignee_id`, by `status`) to support the filtered list (FR-014, FR-015).
**Testing**: pytest. End-to-end tests start a real `ThreadingHTTPServer` on an ephemeral port and hit it with `urllib.request`; service-layer tests bypass HTTP and call the service directly with an in-memory DB. Dedicated suites cover the closed-task rule (`test_closed_task_rule.py`), the filter/search matrix (`test_filtering.py`), the deletion log (`test_deletion_log.py`), and last-write-wins concurrency (`test_concurrency.py`).
**Target Platform**: Local developer machine (macOS / Linux), Python 3.11+. PoC, not a production deployment.
**Project Type**: HTTP backend service (single project), parallel to the existing `src/bank_transfer/` (002), `src/loan_application/` (003), `src/loan_workflow/` (004), `src/fca_loans/` (005) packages.
**Performance Goals**: Not in scope at the timing level. SC-003 ("locate a task in under 10 seconds at ≤500 active tasks") implies the substring search needs to be O(n) at most over ~500 rows, which is trivially satisfied by `LOWER(title) LIKE LOWER('%'||?||'%')` over an unindexed scan.
**Constraints**: Standard library only (Constitution I). No web framework. No notification system. No audit log. No role hierarchy. No team/workspace entity. Comments / attachments / tags / priorities / subtasks / time tracking are out of scope per the spec.
**Scale/Scope**: PoC. ≤4 seeded members, ≤4 seeded tasks. SC-003 design budget: ≤500 active tasks per workspace. Approximately 500–800 LOC across `src/task_manager/` — the smallest feature package in the repo.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Initial check (pre-Phase 0)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | No runtime dependencies planned. All modules listed in Primary Dependencies are stdlib. |
| II. Test Every Module | PASS | Every module planned under `src/task_manager/` has a corresponding `tests/task_manager/test_*.py` (see Project Structure). Plus four invariant-focused suites: closed-task rule, filter matrix, deletion log, last-write-wins concurrency. |
| III. PEP 8 and Type Hints | PASS | All public functions/methods will carry type hints with modern syntax (`str \| None`, etc.). Linted with ruff. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | The deliverable is an HTTP service. The `python -m task_manager.server` runner is a thin CLI wrapper exposing `--help`, `--seed`, `--json`, `--port`, `--db-path` with errors on stderr. With `--seed --json` the seeded fixture is emitted as JSON; without `--json` it is printed as a human-readable table. |
| V. Explicit Error Handling | PASS | Every failure mode in the spec maps to a typed exception in `errors.py` (`AuthError`, `ValidationError`, `NotFound`, `TaskClosed`) and a documented HTTP status code. No bare `except`. SQLite errors propagate with context. The error-code surface is the smallest in the repo because the spec has no role-gated 403, no concurrency-conflict 409, and no SLA-breach 503. |
| VI. Clarity Over Cleverness | PASS | Module count is the smallest in the repo: **9 modules** (no `permissions.py`, no `notifications.py`, no `audit.py`). Each module has a single responsibility. The closed-task rule lives in `service.py` only. The substring search is `LOWER(...) LIKE LOWER(...)` in one SQL string. No metaclasses, decorators-as-DSL, or hand-rolled framework. |

No violations. Initial gate passed.

### Post-design re-check (after Phase 1)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | Phase 1 design did not introduce any non-stdlib dependency. |
| II. Test Every Module | PASS | Every module in the Project Structure below has a matching `tests/task_manager/test_*.py`. The contract documents 11 numbered smoke-test steps in `quickstart.md` covering every endpoint × happy/failure combination. |
| III. PEP 8 and Type Hints | PASS | Data classes and enums in `data-model.md` use `StrEnum` and modern type-hint syntax. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | `quickstart.md` documents `--seed`, `--json`, `--help`, `--port`, `--db-path` on the `python -m task_manager.server` entry point. |
| V. Explicit Error Handling | PASS | The HTTP API contract (`contracts/http-api.md`) enumerates every error code and the precise condition that raises it; the `errors.py` types map 1:1 to those codes. The contract has only five distinct error codes (`unauthenticated`, `validation_error`, `not_found`, `task_closed`, `internal_error`) — the smallest in the repo. |
| VI. Clarity Over Cleverness | PASS | Phase 1 added no extra layers. The five endpoints in the contract map directly to five service-layer functions (`create_task`, `list_tasks`, `get_task`, `update_task`, `delete_task`); the validation rules and the closed-task rule live each in one obvious place. |

No violations after design. Post-design gate passed.

## Project Structure

### Documentation (this feature)

```text
specs/006-task-management/
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
└── task_manager/
    ├── __init__.py
    ├── __main__.py               # Entry point: python -m task_manager
    ├── server.py                 # ThreadingHTTPServer wiring + request dispatch + CLI (argparse: --seed, --json, --port, --db-path)
    ├── handlers.py               # Per-endpoint request handlers (parse, authenticate, call service, format response). NOTE: no permissions layer; the only authz check is the auth.authenticate boundary call.
    ├── auth.py                   # Bearer-token parsing → User; stub auth backend (seeded tokens table).
    ├── service.py                # Business logic: create_task, list_tasks (with filters), get_task, update_task (with closed-task rule), delete_task (with task_deletions write).
    ├── validation.py             # Field-level validation; reports all errors at once (FR-005…FR-008). Whitespace-trim on title before validation.
    ├── store.py                  # SQLite schema, connection, all SQL. No partial unique indexes, no conditional UPDATEs encoding a state machine — task status transitions are free in any direction.
    ├── models.py                 # Dataclasses: User, Task, TaskDeletion; TaskStatus enum.
    └── errors.py                 # AuthError, ValidationError, NotFound, TaskClosed.

tests/
└── task_manager/
    ├── __init__.py
    ├── conftest.py               # Fixtures: in-memory DB, seeded users, seeded tasks across all statuses, ephemeral-port server.
    ├── test_auth.py              # Bearer-token resolution; 401 paths; ensures no business logic runs on a 401 (SC-005 probe).
    ├── test_validation.py        # Per-field validation; per-field error reporting (FR-005…FR-008); whitespace-trim on title.
    ├── test_service.py           # Business logic — create, get, list (no filters), edit (no closed-task), delete — against in-memory DB.
    ├── test_store.py             # Schema, CHECK constraints, indexes, FK behaviour, task_deletions write.
    ├── test_handlers.py          # HTTP-level: status codes, response shapes, error envelopes; Content-Type consistency.
    ├── test_filtering.py         # All combinations of `status` / `assignee` / `q` filters; AND semantics; default ordering by `updated_at DESC`; substring matching on title (case-insensitive); empty-result case.
    ├── test_closed_task_rule.py  # The FR-011 / US2 #5 / US2 #6 matrix: edit-only-on-done (rejected); status-change-only-on-done (accepted); atomic both-fields-and-status PATCH on done (accepted).
    ├── test_concurrency.py       # Last-write-wins on two concurrent PATCHes; both succeed; second overwrites first; `updated_at` reflects the later edit.
    ├── test_deletion_log.py      # Deletions append to `task_deletions`; the row's `task_title_at_delete` matches the task's title at deletion time (FR-018).
    └── test_invariants.py        # SC-001…SC-006 probes; no-cross-feature regression (asserts absence of officer / auditor / role concepts, absence of audit log).
```

**Structure Decision**: A new top-level package `src/task_manager/` parallel to the four existing packages. The package shape is the leanest in the repo:

- **No `permissions.py`** — Q3 = A (flat peers) makes role-based authz vacuous. The only check is "is the caller authenticated", which lives in `server.py`'s dispatch.
- **No `notifications.py`** — notifications are out of scope per the spec.
- **No `audit.py`** — there is no audit log; the `task_deletions` table is a plain operational log with no chain, no verification, no API exposure.
- **No `assignment.py`** — there is no automatic-assignment algorithm; assignment is just a field a member can set or clear.

The internal module count is 9 (vs 10 for 003/004 and 11 for 005), which is in line with the spec's reduced surface area.

This is now the fifth near-identical-shaped package in the repo (HTTP dispatch + bearer auth + SQLite + a small business-logic core). A shared `src/_common/` (HTTP dispatch, bearer-token plumbing, error envelope) is a strong refactor candidate after 006 ships. Constitution VI still prefers four duplications over a premature extraction — but the case is getting hard to ignore. Flagged for a future cleanup feature; out of scope here.

## Complexity Tracking

No violations to justify. 006 is the simplest feature in the repo.

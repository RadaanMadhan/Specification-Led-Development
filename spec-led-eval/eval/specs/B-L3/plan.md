# Implementation Plan: Multi-Tenant Task Management with Per-Task Sharing and Audit

**Branch**: `008-task-sharing` | **Date**: 2026-05-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/008-task-sharing/spec.md`

## Summary

A small Python 3.11+ HTTP backend service exposing exactly the five endpoints the user description locks in — `POST /tasks`, `GET /tasks/{id}`, `PATCH /tasks/{id}`, `DELETE /tasks/{id}`, `GET /tasks/{id}/audit` — implementing a multi-tenant SaaS task tracker with **OAuth 2.0** auth, **per-task ownership and explicit sharing**, **two-tier roles** (`member`, `team_admin`), **absolute byte-equivalent cross-tenant isolation** including `Content-Length` (FR-014), an **immutable per-event audit log written within a 1-second SLA** (FR-018), and an explicit **200 req/s @ p99 ≤ 300 ms performance target** (FR-021, SC-010). With the clarifications resolved as **Q1 = A** (owner-controlled, indefinite shares), **Q2 = A** (field-name-list `diff_summary`), and **Q3 = B** (sharee can view + edit, no delete, no onward share), sharing is exposed by treating `shared_with` as a field on the task editable **only** by the owner via `PATCH /tasks/{id}`; the service decomposes a single PATCH into multiple audit entries (one `edited` for the field diff plus one `shared`/`unshared` per affected sharee) all written in the same `BEGIN IMMEDIATE … COMMIT` transaction. Built on the Python standard library only (`http.server`, `sqlite3` in WAL mode with tuned PRAGMAs, `hashlib` is not needed here unlike 005, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `typing.Protocol`). The cross-team isolation invariant is enforced by a `responses.not_found_response()` helper returning identical `(status, content_type, content_length, body_bytes)` at every cross-team / in-team-no-rel / sharee-on-DELETE code path. The 1-second audit SLA is enforced by the SQLite connection `timeout=0.8` — a contended `BEGIN IMMEDIATE … COMMIT` raises `OperationalError` and is mapped to `503 audit_unavailable` with the transaction rolled back. The 200 req/s @ p99 ≤ 300 ms target is achieved via WAL-mode SQLite + indexed read paths + a single-process / single-connection model with a `threading.Lock`; throughput analysis in `research.md` shows this is comfortably above the workload's write-lock-occupation budget (~70–350 ms/sec at 200 req/s for the specified mix).

## Technical Context

**Language/Version**: Python 3.11+
**Primary Dependencies**: None at runtime (standard library only — `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `typing.Protocol`, `urllib.request` (tests only)). Dev-only: `pytest`, `ruff`.
**Storage**: SQLite via stdlib `sqlite3` in **WAL mode**, with `synchronous=NORMAL`, `temp_store=MEMORY`, `mmap_size=128 MiB`, opened with `timeout=0.8` seconds for FR-018. File-backed for `python -m task_sharing.server` runs; `:memory:` for tests. One process-wide connection guarded by `threading.Lock`. Six tables: `users`, `teams`, `tokens`, `tasks`, `task_shares` (junction), `audit_entries`. Composite PK on `task_shares(task_id, sharee_user_id)` with `ON DELETE CASCADE` on `task_id`. The `audit_entries` table has **no FK to `tasks`** (so audit entries outlive the task — FR-017) but does have a FK to `teams` (so cross-team isolation on the audit endpoint is a single WHERE clause without joining the deleted task row).
**Testing**: pytest. End-to-end tests start a real `ThreadingHTTPServer` on an ephemeral port and hit it with `urllib.request`. Dedicated suites cover: OAuth introspection seam + forged-payload probes (`test_oauth.py`), byte-equivalent isolation across four endpoints × four caller-categories (`test_byte_equivalence.py`), per-event audit decomposition (`test_audit.py`), 1-second SLA contention path (`test_audit_sla.py`), sharing lifecycle (`test_sharing.py`), and a smoke performance load test (`test_performance.py`, skipped on CI where wall-clock measurement is unreliable).
**Target Platform**: Local developer machine (macOS / Linux), Python 3.11+. PoC, not a production deployment. **For production deployment at SC-010 scale beyond one workspace, a real RDBMS (PostgreSQL) is recommended**; the `store.py` boundary keeps the swap mechanical. This is documented in `research.md` and is **not** a violation of Constitution I — the stdlib choice is for the PoC, and the design isolates the swap point.
**Project Type**: HTTP backend service (single project), parallel to the existing six packages (002–007).
**Performance Goals**: **200 requests per second per workspace at p99 latency ≤ 300 ms**, under a mix of 60% `GET /tasks/{id}`, 20% `PATCH /tasks/{id}`, 10% `POST /tasks`, 5% `GET …/audit`, 5% `DELETE /tasks/{id}` (FR-021, SC-010). Throughput analysis in `research.md` shows the WAL-mode design comfortably meets this on a developer machine.
**Constraints**: Standard library only (Constitution I). No web framework. OAuth 2.0 is the auth boundary at the contract level (stub introspector behind the `TokenIntrospector` Protocol for v1, RFC 7662 swap-in for production). Audit log is append-only enforced by code-path absence (no UPDATE/DELETE SQL targets `audit_entries`). 12-month retention satisfied by absence of DELETE path. **Tamper detection on the audit log is out of scope for this feature** (see feature 005 for the chained-hash pattern). Pricing/scoring/notifications/comments/attachments/etc. all out of scope.
**Scale/Scope**: PoC. ≤2 seeded teams, ≤6 seeded users (mix of roles and including a cross-team admin probe), ≤4 seeded tasks. Approximately 1,000–1,400 LOC across `src/task_sharing/`. The largest feature in the repo by LOC and by number of distinct invariants.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Initial check (pre-Phase 0)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | No runtime dependencies planned. All modules in Primary Dependencies are stdlib. The performance target (FR-021) was scrutinised here: research.md shows stdlib SQLite in WAL mode meets the SC-010 budget on a developer machine, so the target does not justify a non-stdlib dependency. The plan documents the production-deployment caveat (real RDBMS recommended) without blocking on it. |
| II. Test Every Module | PASS | Every module planned under `src/task_sharing/` has a corresponding `tests/task_sharing/test_*.py` (see Project Structure). Plus six invariant-focused suites: OAuth + forged-payload, byte-equivalent isolation, per-event audit, 1-second SLA, sharing lifecycle, performance smoke test. |
| III. PEP 8 and Type Hints | PASS | All public functions/methods will carry type hints with modern syntax. Linted with ruff. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | The deliverable is an HTTP service. The `python -m task_sharing.server` runner is a thin CLI wrapper exposing `--help`, `--seed`, `--json`, `--port`, `--db-path` with errors on stderr. |
| V. Explicit Error Handling | PASS | Every failure mode in the spec maps to a typed exception in `errors.py` (`AuthError`, `ValidationError`, `NotFound`, `AuditUnavailable`) and a documented HTTP status code. No bare `except`. `OperationalError` from SQLite is the one stdlib exception we translate deliberately (FR-018 → `503 audit_unavailable`). |
| VI. Clarity Over Cleverness | PASS | Module count is 12 — the highest in the repo, justified by the highest invariant count. Each module has a single responsibility. The relationship classification (owner/sharee/admin/in-team-none/outsider) lives in one function (`permissions.relationship`). The PATCH → audit-entries decomposition lives in one function (`service.update_task`). The byte-equivalence helper is one function (`responses.not_found_response`). No metaclasses, decorators-as-DSL, or hand-rolled framework. |

No violations. Initial gate passed.

### Post-design re-check (after Phase 1)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | Phase 1 design did not introduce any non-stdlib dependency. |
| II. Test Every Module | PASS | Every module in the Project Structure below has a matching `tests/task_sharing/test_*.py`. The contract documents 17 numbered smoke-test steps in `quickstart.md` covering every endpoint × happy/failure combination across the caller-relationship matrix. |
| III. PEP 8 and Type Hints | PASS | Data classes and enums in `data-model.md` use `StrEnum`, `Protocol`, `frozenset`, and modern type-hint syntax. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | Documented in `quickstart.md`. |
| V. Explicit Error Handling | PASS | The HTTP API contract enumerates every error code and the precise condition that raises it; `errors.py` types map 1:1. The 400-vs-404 split (in-team-can-see-task but forbidden-shared_with-change → 400; everything-else-unauthorised → byte-equivalent 404) is documented in `contracts/http-api.md` and tested explicitly in `test_byte_equivalence.py` and `test_permissions.py`. |
| VI. Clarity Over Cleverness | PASS | Phase 1 added no extra layers. The five endpoints in the contract map to five service-layer functions plus the `update_task` PATCH-decomposition helper. The byte-equivalence helper, the 1-second SLA mechanism (connection `timeout=0.8`), the OAuth introspection seam, the relationship classifier, and the audit-entry-builder are each in one obvious place. |

No violations after design. Post-design gate passed.

## Project Structure

### Documentation (this feature)

```text
specs/008-task-sharing/
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
├── team_tasks/                   # Existing — 007 feature; unchanged.
└── task_sharing/
    ├── __init__.py
    ├── __main__.py               # Entry point: python -m task_sharing
    ├── server.py                 # ThreadingHTTPServer wiring + request dispatch + OAuth boundary check + CLI (argparse: --seed, --json, --port, --db-path). PRAGMA-driven WAL connection setup.
    ├── handlers.py               # Per-endpoint request handlers (parse, authenticate, authorise via permissions table, call service, format response). Catches `AuditUnavailable` and maps to 503.
    ├── responses.py              # Canonical response builders. `not_found_response()` returns the fixed byte-equivalent envelope (FR-014) used at every cross-team / in-team-no-rel / sharee-on-DELETE code path.
    ├── auth.py                   # `TokenIntrospector` Protocol + `StubIntrospector` (v1, seeded `tokens` table); `AuthenticatedCaller` dataclass with `(user_id, team_id, role)`. Forged-payload check happens at this boundary (FR-002a / SC-006).
    ├── permissions.py            # `relationship(caller, task)` classifier + `is_allowed(relationship, action)` table. The `change_shared_with` action is allowed only when `relationship == OWNER`.
    ├── service.py                # Business logic: create_task, get_task, update_task (the PATCH-decomposition function), delete_task, get_audit. Returns `None` for any not-authorised-to-see case (handler converts via `not_found_response()`). Contains `build_diff_summary` for the field-name-list audit format.
    ├── validation.py             # Field-level validation; reports all errors at once; explicitly rejects any `owner_id`/`team_id` in the body (FR-009); rejects non-owner `shared_with` PATCH (FR-010).
    ├── store.py                  # SQLite schema + WAL PRAGMA setup + connection (timeout=0.8 for FR-018) + all SQL. Every read query includes `team_id = ?`. No UPDATE/DELETE code path against `audit_entries`. `ON DELETE CASCADE` on `task_shares.task_id`. No FK from `audit_entries.task_id` to `tasks.id` (audit outlives task).
    ├── models.py                 # Dataclasses: User, Token, Team, Task, TaskShare, AuditEntry, AuthenticatedCaller; Role, TaskStatus, AuditOperation, Relationship enums.
    └── errors.py                 # AuthError, ValidationError, NotFound, AuditUnavailable.

tests/
└── task_sharing/
    ├── __init__.py
    ├── conftest.py               # Fixtures: in-memory DB (with WAL mode), seeded users covering every role and the cross-team outsider, seeded tasks with various sharing configurations, ephemeral-port server, write-lock contention helper for SLA tests.
    ├── test_oauth.py             # Bearer-token resolution; 401 paths; ensures no business logic runs on a 401. Forged-payload probe: send a body containing `team_id` / `role` / `owner_id` and assert they are ignored / rejected (SC-006).
    ├── test_permissions.py       # Exhaustive (relationship × action) matrix. Includes the 400-vs-404 split for `change_shared_with` attempts by non-owners.
    ├── test_validation.py        # Per-field validation; per-field error reporting; rejection of immutable fields; cross-team-share rejection (FR-012).
    ├── test_sharing.py           # Per-task share lifecycle: add/remove sharees, sharee can edit, sharee can read audit, sharee CANNOT delete (byte-equivalent 404), sharee CANNOT modify `shared_with` (400 validation_error). Admin CANNOT modify `shared_with` (Q1 = A).
    ├── test_audit.py             # Per-event audit decomposition: PATCH with field-only changes → 1 entry; PATCH with share-only changes → N entries; combined PATCH → 1 + N entries all in one transaction. `diff_summary` shape rules (created/edited/deleted/shared/unshared). Audit survives task deletion. Append-only.
    ├── test_audit_sla.py         # Holds the SQLite write lock for 1.5 s in another thread; fires PATCH; asserts (a) `503 audit_unavailable`, (b) task state unchanged, (c) zero audit entries written.
    ├── test_byte_equivalence.py  # Constructs (own-team-task, cross-team-task, fabricated-id, sharee-on-DELETE) quadruples; asserts identical `(status, content_type, content_length, body_bytes)` across every unauthorised-access endpoint (FR-014, SC-003).
    ├── test_service.py           # Business logic — create, view, edit (with PATCH-decomposition), delete, view audit — against in-memory DB.
    ├── test_store.py             # Schema, CHECK constraints, FK behaviour (incl. ON DELETE CASCADE for `task_shares`), append-only on `audit_entries` (static SQL probe).
    ├── test_handlers.py          # HTTP-level: status codes, response shapes, error envelopes. Asserts every unauthorised-access code path goes through `not_found_response()` (static probe + runtime probe).
    ├── test_performance.py       # Smoke load test: 200 req/s under the FR-021 mix; asserts p99 ≤ 300 ms on the developer machine. Skipped on CI where wall-clock measurement is unreliable. Not a substitute for production load testing.
    └── test_invariants.py        # SC-003…SC-011 catch-all probes including the forged-payload probe and the runtime audit-immutability scan.
```

**Structure Decision**: A new top-level package `src/task_sharing/` parallel to the six existing packages. The internal module shape extends 007's with three substantive additions:

- `auth.py` now carries the `TokenIntrospector` Protocol seam (from 005), not just a bearer-token stub.
- `permissions.py` carries the `Relationship` classifier as a first-class concept (sharee + admin + owner + in-team-none + outsider).
- `service.py` carries the PATCH → audit-entries decomposition function — the most semantically dense piece of code in the feature.

**Seven near-identical-shape packages now exist**. The case for a `src/_common/` extraction is overwhelming. Out of scope for *this* feature; flagged at the top of `research.md` and at the end of this section. A future cleanup feature should extract (at minimum) the HTTP dispatch, the bearer-token boundary, the canonical not-found-response helper, the field-error envelope, and the validation primitives. Of these, the not-found helper is the most copy-and-paste-divergent across features (005's pins Content-Length, 007's doesn't, 008's does) — the extraction should preserve the per-feature variants as parameters rather than collapse them.

The separation between `service.py` (business logic, returns `None` or raises `AuditUnavailable`) and `handlers.py` (HTTP-aware, applies the 400-vs-404 split + scrubbing) is what lets unit tests exercise the per-event audit decomposition and the byte-equivalent invariant without standing up a real server, while `test_byte_equivalence.py` and `test_audit_sla.py` confirm the HTTP layer reproduces the same bytes and the same fail-fast 503.

## Complexity Tracking

No violations to justify.

008 is the most complex feature in the repo, with the following dimensions stacking:

- OAuth 2.0 boundary (shared with 005).
- Multi-tenant byte-equivalent isolation (stronger than 005's GET-only; weaker than 007's no-content-length-pinning — 008's is the strictest).
- Per-task ownership + explicit sharing (unique to 008).
- Two-tier role + creator-ownership permission model (similar to 007).
- Per-event audit log with multi-event-per-PATCH semantics (unique to 008 — 005 had per-decision audit, 007 had per-edit audit but no decomposition).
- 1-second audit SLA with fail-fast 503 on breach (similar to 005's 2-second).
- 200 req/s @ p99 ≤ 300 ms performance target (unique to 008).

Each dimension is contained in one module and has a dedicated test suite. The total module count (12) and test-file count (13) is in line with the invariant count.

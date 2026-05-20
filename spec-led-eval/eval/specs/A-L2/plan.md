# Implementation Plan: Loan Application with Role-Based Workflow and Audit Trail

**Branch**: `004-loan-application-rbac` | **Date**: 2026-05-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/004-loan-application-rbac/spec.md`

## Summary

A small Python 3.11+ HTTP backend service exposing six endpoints — `POST /applications`, `GET /applications`, `GET /applications/{reference}`, `POST /applications/{reference}/claim`, `POST /applications/{reference}/decision`, `GET /applications/{reference}/audit` — that implements a retail-bank loan-application workflow with three roles (`customer`, `loan_officer`, `compliance_reviewer`), an explicit four-state status machine (`Submitted → Under Review → Approved | Rejected`), per-application loan-officer assignment via a claim/pickup model, and an append-only audit trail recording every status change with actor, timestamp, and previous/new status. Built on the Python standard library only (`http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`); no web framework, no ORM. The design is shaped around four invariants the spec is strict about (SC-004, SC-005, SC-006, SC-007, SC-008): the cross-customer no-leak rule, the only-assigned-officer-decides rule, the one-officer-claim rule, the audit-trail completeness rule, and the compliance-cannot-write rule. The first four are enforced **structurally** — cross-customer no-leak by the permission table + service-layer `WHERE customer_id = ?` filter and `404` (not `403`) on non-owner customer reads; the assignment/claim rules by two conditional `UPDATE` statements (`WHERE status='Submitted'` for claim, `WHERE status='Under Review' AND assigned_officer_id=?` for decide) whose rowcounts encode both invariants in one SQL line each; and the audit completeness rule by inserting each audit row in the same DB transaction as its corresponding status-change `UPDATE`. The compliance-cannot-write rule is enforced by the permission table consulted before any handler dispatches. FR-008 (one in-flight per customer, covering both `Submitted` and `Under Review`) is enforced at the schema layer by a SQLite *partial unique index*. Authentication is a stub bearer-token resolver (real auth is out of scope per the spec). No notification system is built (out of scope).

## Technical Context

**Language/Version**: Python 3.11+
**Primary Dependencies**: None at runtime (standard library only — `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `urllib.request` (tests only)). Dev-only: `pytest`, `ruff`.
**Storage**: SQLite via stdlib `sqlite3`. File-backed for `python -m loan_workflow.server` runs; `:memory:` for tests. One process-wide connection guarded by `threading.Lock`. Partial unique index on `loan_applications(customer_id) WHERE status IN ('Submitted','Under Review')` enforces FR-008 at the schema layer. Two conditional `UPDATE` statements encode the claim race (FR-012) and the assigned-officer-decides rule (FR-013) at the SQL layer.
**Testing**: pytest. End-to-end tests start a real `ThreadingHTTPServer` on an ephemeral port and hit it with `urllib.request`; service-layer tests bypass HTTP and call the service directly with an in-memory DB. A dedicated `test_invariants.py` exercises SC-004…SC-008 probes including concurrent-claim races and per-role write-attempt probes for compliance. `test_state_machine.py` enumerates all 4×4 status-transition attempts and asserts that exactly the three allowed transitions succeed.
**Target Platform**: Local developer machine (macOS / Linux), Python 3.11+. PoC, not a production deployment.
**Project Type**: HTTP backend service (single project), parallel to the existing `src/bank_transfer/` (002) and `src/loan_application/` (003) packages.
**Performance Goals**: Not in scope. PoC verifies correctness invariants, not throughput. Local dev-machine latency is acceptable.
**Constraints**: Standard library only (Constitution I). No web framework. Auth is a stub. Append-only on `application_events` (audit) enforced both at code level (no UPDATE/DELETE path) and structurally (no SQL writes other than INSERT). Pricing, scoring, document upload, customer withdrawal, reassignment, and notifications are out of scope per the spec's Out of Scope section.
**Scale/Scope**: PoC. ≤10 seeded users (mix of all three roles), ≤5 seeded applications. Approximately 800–1,100 LOC across `src/loan_workflow/`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Initial check (pre-Phase 0)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | No runtime dependencies planned. `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `urllib.request` (tests only) are all stdlib. |
| II. Test Every Module | PASS | Every module planned under `src/loan_workflow/` has a corresponding `tests/loan_workflow/test_*.py` (see Project Structure). Plus the integration suite `test_invariants.py` exercises the SC-004…SC-008 probes, and `test_state_machine.py` exhaustively enumerates the 4×4 transition grid. |
| III. PEP 8 and Type Hints | PASS | All public functions/methods will carry type hints with modern syntax (`str \| None`, etc.). Linted with ruff. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | The deliverable is an HTTP service. The `python -m loan_workflow.server` runner is a thin CLI wrapper exposing `--help`, `--seed`, `--json`, `--port`, `--db-path` with errors on stderr. With `--seed --json` the seeded fixture (tokens, users, applications) is emitted as JSON; without `--json` it is printed as a human-readable table. Endpoints are JSON-only by design. |
| V. Explicit Error Handling | PASS | Every failure mode in the spec maps to a typed exception in `errors.py` (`AuthError`, `PermissionDenied`, `NotAssignedOfficer`, `ValidationError`, `NotFound`, `HasInFlightApplication`, `AlreadyClaimed`, `AlreadyDecided`) and a documented HTTP status code. No bare `except`. SQLite errors propagate with context. |
| VI. Clarity Over Cleverness | PASS | Module count is small (≤9 modules). Each module has a single responsibility. Permission rules — including the `decide_if_assigned` predicate — live in a single explicit table in `permissions.py`. The state machine is encoded as three explicit conditional UPDATE statements in `store.py`, one per legal transition. No metaclasses, decorator-as-DSL, or hand-rolled framework. |

No violations. Initial gate passed.

### Post-design re-check (after Phase 1)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | Phase 1 design did not introduce any non-stdlib dependency. |
| II. Test Every Module | PASS | Every module in the Project Structure section below has a matching `tests/loan_workflow/test_*.py`. |
| III. PEP 8 and Type Hints | PASS | Data classes and enums in `data-model.md` use `StrEnum` and modern type-hint syntax (`str \| None`). |
| IV. Dual-Format CLI Output | PASS (scope-limited) | `quickstart.md` documents `--seed`, `--json`, `--help`, `--port`, `--db-path` on the `python -m loan_workflow.server` entry point. |
| V. Explicit Error Handling | PASS | The HTTP API contract (`contracts/http-api.md`) enumerates every error code and the precise condition that raises it; the `errors.py` types map 1:1 to those codes. `NotAssignedOfficer` (a 403 distinct from the generic `PermissionDenied`) was added in Phase 1 because the spec distinguishes the two failure modes — and that distinction is reflected in both the error envelope and the test matrix. |
| VI. Clarity Over Cleverness | PASS | Phase 1 added no extra layers. The six endpoints in the contract map directly to six service-layer functions; the permission matrix, the validation rules, the state-machine transitions, and the audit-row production are each in one obvious place. The `scrub_for_role` helper centralises FR-021 (officer identity hidden from customer) in one function rather than spreading it across per-endpoint serialisation. |

No violations after design. Post-design gate passed.

## Project Structure

### Documentation (this feature)

```text
specs/004-loan-application-rbac/
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
└── loan_workflow/
    ├── __init__.py
    ├── __main__.py               # Entry point: python -m loan_workflow
    ├── server.py                 # ThreadingHTTPServer wiring + request dispatch + CLI (argparse: --seed, --json, --port, --db-path)
    ├── handlers.py               # Per-endpoint request handlers (parse, authz, call service, format response); contains `scrub_for_role` (FR-021)
    ├── auth.py                   # Bearer-token parsing → User; stub auth backend
    ├── permissions.py            # Single explicit (role, action) → predicate(context) table; the only place authorisation rules live
    ├── service.py                # Business logic: submit_application, claim_application, decide_application, list_applications, get_application, get_audit
    ├── validation.py             # Field-level validation; reports all errors at once (FR-006)
    ├── store.py                  # SQLite schema, connection, all SQL (transactional). Three conditional UPDATEs encode the three legal status transitions.
    ├── models.py                 # Dataclasses: User, LoanApplication, Decision, ApplicationEvent; Role, ApplicationStatus, DecisionType enums
    └── errors.py                 # AuthError, PermissionDenied, NotAssignedOfficer, NotFound, ValidationError, HasInFlightApplication, AlreadyClaimed, AlreadyDecided

tests/
└── loan_workflow/
    ├── __init__.py
    ├── conftest.py               # Fixtures: in-memory DB, seeded users/applications, ephemeral-port server
    ├── test_auth.py
    ├── test_permissions.py       # Exhaustive (role × action × context) matrix across all three roles and all eight actions
    ├── test_validation.py        # Per-field validation, including the "report all violations at once" guarantee
    ├── test_state_machine.py     # Enumerates 4×4 transition attempts; asserts exactly the three allowed transitions succeed
    ├── test_service.py           # Business-logic unit tests against in-memory DB
    ├── test_store.py             # Schema, partial unique index for FR-008, claim/decide atomicity, no DELETE/UPDATE path on append-only tables
    ├── test_handlers.py          # HTTP-level: status codes, response shapes, error envelopes; FR-021 scrubbing on every customer-role response path
    └── test_invariants.py        # SC-004…SC-008 probes: concurrent claim race (FR-012), only-assigned-officer-decides (FR-013), append-only audit (FR-018), compliance-cannot-write across every write endpoint, customer-no-cross-leak
```

**Structure Decision**: A new top-level package `src/loan_workflow/` parallel to the existing `src/bank_transfer/` and `src/loan_application/` packages. The three features are independent and share no business logic; copying the small infra patterns (HTTP dispatch, bearer-token auth, explicit permission table, error envelope) is cheaper than promoting them to a shared `src/_common/` after only three examples — revisit if a fourth feature ships. The internal module shape mirrors 003 (and through 003, 002) so reviewers can read all three side-by-side and spot the deltas: `loan_workflow` is 003 + an extra role + an extra status + an extra endpoint (`POST .../claim`) + an extra error-code (`not_assigned_officer`), and minus a notification module.

Tests live under `tests/loan_workflow/` to avoid colliding with the existing `tests/loan_application/` (003) and `tests/test_*.py` at the `tests/` root (002).

The separation between `service.py` (business logic, DB-aware, framework-free) and `handlers.py` (HTTP-aware, plus the FR-021 scrub) is what lets unit tests exercise the permission/decision/audit invariants without standing up a real server, while `test_invariants.py` and `test_handlers.py` exercise the same rules through the wire to confirm the HTTP layer doesn't bypass them.

## Complexity Tracking

No violations to justify.

# Implementation Plan: Loan Application

**Branch**: `003-loan-application` | **Date**: 2026-05-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/003-loan-application/spec.md`

## Summary

A small Python 3.11+ HTTP backend service exposing five endpoints — `POST /applications`, `GET /applications`, `GET /applications/{reference}`, `POST /applications/{reference}/decision`, `GET /applications/{reference}/audit` — that lets authenticated **customers** submit personal loan applications (£1,000–£25,000, term ∈ {12, 24, 36, 48, 60} months) and **bank staff** approve or reject them with a mandatory reason. Built on the Python standard library only (`http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`); no web framework, no ORM. The design is shaped around two invariants the spec is strict about (SC-004 and SC-005): a customer can never see another customer's application, and an application can never have two recorded decisions. Both invariants are enforced **structurally** — the cross-customer invariant by a permission table + service-layer `WHERE customer_id = ?` filter, and the one-decision invariant by a conditional `UPDATE … WHERE status='Pending Review'` whose rowcount tells the service which concurrent caller won. FR-005 (one in-flight application per customer) is enforced at the schema layer by a SQLite *partial unique index*. Authentication is a stub bearer-token resolver (per the spec's Assumptions, real auth is out of scope), and email notifications are a logged stub via a `NotificationSink` interface.

## Technical Context

**Language/Version**: Python 3.11+
**Primary Dependencies**: None at runtime (standard library only — `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `urllib.request` (tests only)). Dev-only: `pytest`, `ruff`.
**Storage**: SQLite via stdlib `sqlite3`. File-backed for `python -m loan_application.server` runs; `:memory:` for tests. One process-wide connection guarded by `threading.Lock`. Partial unique index on `loan_applications(customer_id) WHERE status='Pending Review'` enforces FR-005 at the schema layer.
**Testing**: pytest. End-to-end tests start a real `ThreadingHTTPServer` on an ephemeral port and hit it with `urllib.request`; service-layer tests bypass HTTP and call the service directly with an in-memory DB. A dedicated `test_invariants.py` exercises SC-001…SC-006 probes including concurrent-decision races.
**Target Platform**: Local developer machine (macOS / Linux), Python 3.11+. PoC, not a production deployment.
**Project Type**: HTTP backend service (single project), parallel to the existing `src/bank_transfer/` package.
**Performance Goals**: Not in scope. PoC verifies correctness invariants, not throughput. Local dev-machine latency is acceptable.
**Constraints**: Standard library only (Constitution I). No web framework. Auth is a stub. Append-only on `application_events` (audit) enforced both at code level (no UPDATE/DELETE path) and structurally. Pricing, scoring, document upload, and customer-initiated withdrawal are out of scope per the spec's Assumptions section.
**Scale/Scope**: PoC. ≤10 seeded users, ≤5 seeded applications. Approximately 700–1,000 LOC across `src/loan_application/`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Initial check (pre-Phase 0)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | No runtime dependencies planned. `http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `urllib.request` (tests only) are all stdlib. |
| II. Test Every Module | PASS | Every module planned under `src/loan_application/` has a corresponding `tests/loan_application/test_*.py` (see Project Structure). Plus the integration suite `test_invariants.py` exercises the SC-001…SC-006 probes. |
| III. PEP 8 and Type Hints | PASS | All public functions/methods will carry type hints with modern syntax (`str \| None`, etc.). Linted with ruff. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | The deliverable is an HTTP service, not a CLI tool, so IV does not bind to endpoint responses (which are JSON anyway). The `python -m loan_application.server` runner is a thin CLI wrapper exposing `--help`, `--seed`, and `--json` (the seeded fixture is emitted as JSON when `--json` is set, human-readable otherwise) with errors on stderr per the spirit of IV. |
| V. Explicit Error Handling | PASS | Every failure mode in the spec maps to a typed exception in `errors.py` (`AuthError`, `PermissionDenied`, `ValidationError`, `NotFound`, `HasPendingApplication`, `AlreadyDecided`) and a documented HTTP status code. No bare `except`. SQLite errors propagate with context. |
| VI. Clarity Over Cleverness | PASS | Module count is small (≤9 modules). Each module has a single responsibility. Permission rules live in a single explicit table in `permissions.py`. No metaclasses, decorator-as-DSL, or hand-rolled framework. |

No violations. Initial gate passed.

### Post-design re-check (after Phase 1)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | Phase 1 design did not introduce any non-stdlib dependency. The `NotificationSink` stub prints to stdout via the standard `print()`; no SMTP / HTTP-client dependency was added. |
| II. Test Every Module | PASS | Every module in the Project Structure section below has a matching `tests/loan_application/test_*.py`. |
| III. PEP 8 and Type Hints | PASS | Data classes and enums in `data-model.md` use `StrEnum` and modern type-hint syntax. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | `quickstart.md` documents `--seed`, `--json`, `--help` on the `python -m loan_application.server` entry point. Endpoints are JSON-only by design (HTTP service). |
| V. Explicit Error Handling | PASS | The HTTP API contract (`contracts/http-api.md`) enumerates every error code and the precise condition that raises it; the `errors.py` types map 1:1 to those codes. |
| VI. Clarity Over Cleverness | PASS | Phase 1 added no extra layers. The five endpoints in the contract map directly to five service-layer functions; the permission matrix and the validation rules are each in one obvious place. |

No violations after design. Post-design gate passed.

## Project Structure

### Documentation (this feature)

```text
specs/003-loan-application/
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
└── loan_application/
    ├── __init__.py
    ├── __main__.py               # Entry point: python -m loan_application
    ├── server.py                 # ThreadingHTTPServer wiring + request dispatch + CLI (argparse: --seed, --json, --port, --db-path)
    ├── handlers.py               # Per-endpoint request handlers (parse, authz, call service, format response)
    ├── auth.py                   # Bearer-token parsing → User; stub auth backend
    ├── permissions.py            # Single explicit (role, action) → predicate(context) table
    ├── service.py                # Business logic: submit_application, list_applications, get_application, decide_application, get_audit
    ├── validation.py             # Field-level validation; reports all errors at once (FR-002)
    ├── store.py                  # SQLite schema, connection, all SQL (transactional). One process-wide connection + threading.Lock.
    ├── models.py                 # Dataclasses: User, LoanApplication, Decision, ApplicationEvent, NotificationRecord; Role, ApplicationStatus, EmploymentStatus, ContactPreference, EventType, DecisionType enums
    ├── notifications.py          # NotificationSink protocol + StdoutNotificationSink (prints structured line + writes notification_log row)
    └── errors.py                 # AuthError, PermissionDenied, NotFound, ValidationError, HasPendingApplication, AlreadyDecided

tests/
└── loan_application/
    ├── __init__.py
    ├── conftest.py               # Fixtures: in-memory DB, seeded users/applications, ephemeral-port server, RecordingNotificationSink
    ├── test_auth.py
    ├── test_permissions.py       # Exhaustive (role × action × ownership) matrix
    ├── test_validation.py        # Per-field validation, including the "report all violations at once" guarantee
    ├── test_service.py           # Business-logic unit tests against in-memory DB
    ├── test_store.py             # Schema, partial unique index for FR-005, decision atomicity, no DELETE/UPDATE path on append-only tables
    ├── test_handlers.py          # HTTP-level: status codes, response shapes, error envelopes
    └── test_invariants.py        # SC-001…SC-006 probes: concurrent decision race (FR-012), cross-customer no-leak (FR-013), append-only audit (FR-016), notification fan-out (FR-014)
```

**Structure Decision**: A new top-level package `src/loan_application/` parallel to the existing `src/bank_transfer/`. The two features are independent (different domain, different storage, different endpoints) and share no business logic; copying the small infra patterns (HTTP dispatch, bearer-token auth, explicit permission table) is cheaper than promoting them to a shared `src/_common/` package after only two examples. The internal module shape mirrors 002 so reviewers can read both side-by-side. Tests live under `tests/loan_application/` to avoid colliding with the existing 002 test files at the `tests/` root.

The separation between `service.py` (business logic, DB-aware, framework-free) and `handlers.py` (HTTP-aware) is what lets unit tests exercise the permission/decision/audit invariants without standing up a real server, while `test_invariants.py` and `test_handlers.py` exercise the same rules through the wire to confirm the HTTP layer doesn't bypass them.

## Complexity Tracking

No violations to justify.

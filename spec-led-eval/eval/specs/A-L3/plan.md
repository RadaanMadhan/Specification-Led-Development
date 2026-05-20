# Implementation Plan: FCA-Regulated Loan Application

**Branch**: `005-fca-loan-applications` | **Date**: 2026-05-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/005-fca-loan-applications/spec.md`

## Summary

A small Python 3.11+ HTTP backend service exposing exactly the four endpoints the FCA spec locks in — `POST /applications`, `GET /applications/{id}`, `PATCH /applications/{id}/status`, `GET /applications/{id}/audit` — implementing a retail-bank loan application workflow under FCA consumer-credit framing with three roles (`applicant`, `officer`, `auditor`), a four-state machine (`pending → under_review → approved | rejected`), automatic round-robin officer assignment at submission, a defence-in-depth no-self-approval rule, OAuth 2.0 bearer authentication, an immutable tamper-detectable audit log via a chained-hash structure, a 2-second audit-write SLA enforced by in-transaction commit + fail-fast `503`, and a byte-equivalent unauthorised-read response that prevents any outsider from distinguishing between "another applicant's application" and "no such application". Built on the Python standard library only (`http.server`, `sqlite3`, `hashlib`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `typing.Protocol`); no web framework, no ORM, no external crypto. The design is shaped around six invariants the spec is zero-tolerance about (SC-004 through SC-010): byte-equivalent unauthorised reads, only-assigned-officer-decides, no-self-approval, no-audit-entry-without-state-change-and-vice-versa, immutable-tamper-detectable-audit, and OAuth-401-before-business-logic. The first three are enforced **structurally**: byte-equivalence by a single `responses.not_found_response()` helper that every unauthorised-read code path is required to use; the assignment/decision rules by three conditional `UPDATE` statements (one per legal transition) whose `WHERE` clauses encode source-status + assigned-officer + not-applicant in one SQL line each; and the audit-completeness rule by inserting each audit row in the same `BEGIN IMMEDIATE … COMMIT` transaction as its corresponding state-change `UPDATE`. The 2-second SLA is enforced by the SQLite connection's `timeout=1.8` — a contended write fails with `OperationalError` which maps to `503 audit_unavailable` with the transaction rolled back. The chained-hash audit log uses stdlib `hashlib.sha256` over a length-prefixed canonical encoding of each entry plus the previous entry's hash; tamper detection runs on every audit read and surfaces a top-level `tamper_status` field. FR-008 (one in-flight per applicant) is enforced at the schema layer by a SQLite partial unique index. OAuth 2.0 token introspection is exposed as a `TokenIntrospector` Protocol whose v1 implementation is a seeded-token stub but whose interface matches RFC 7662 so a real introspection endpoint can drop in 1:1 later. No notification system is built (out of scope).

## Technical Context

**Language/Version**: Python 3.11+
**Primary Dependencies**: None at runtime (standard library only — `http.server`, `sqlite3`, `hashlib`, `hmac` (canonical encoding helpers), `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `typing.Protocol`, `urllib.request` (tests only)). Dev-only: `pytest`, `ruff`.
**Storage**: SQLite via stdlib `sqlite3`. File-backed for `python -m fca_loans.server` runs; `:memory:` for tests. One process-wide connection opened with `timeout=1.8` and guarded by `threading.Lock`. Partial unique index on `loan_applications(applicant_id) WHERE status IN ('pending','under_review')` enforces FR-008 at the schema layer. Three conditional `UPDATE` statements encode the three legal status transitions (FR-009). Schema CHECK `assigned_officer_id != applicant_id` is the structural defence for FR-011. Audit rows carry `prev_hash` and `entry_hash` columns; chain verification runs on every audit read (FR-018).
**Testing**: pytest. End-to-end tests start a real `ThreadingHTTPServer` on an ephemeral port and hit it with `urllib.request`; service-layer tests bypass HTTP and call the service directly with an in-memory DB. Dedicated suites cover byte-equivalence (`test_byte_equivalence.py`), the audit chain and tamper detection (`test_audit_chain.py`), the 2-second SLA contention path (`test_audit_sla.py`), the assignment cursor (`test_assignment.py`), and the no-self-approval defence-in-depth (`test_self_approval.py`).
**Target Platform**: Local developer machine (macOS / Linux), Python 3.11+. PoC, not a production deployment.
**Project Type**: HTTP backend service (single project), parallel to the existing `src/bank_transfer/` (002), `src/loan_application/` (003), `src/loan_workflow/` (004) packages.
**Performance Goals**: Not in scope. PoC verifies correctness invariants, not throughput. The 2-second audit SLA is a correctness constraint, not a performance target — it is satisfied by single-transaction commit, not by tuning.
**Constraints**: Standard library only (Constitution I). No web framework. Auth is OAuth 2.0 at the contract level, stub at the implementation level via the `TokenIntrospector` seam. Append-only on `audit_entries` enforced both at code level (no UPDATE/DELETE path) and detectably (chained-hash on every entry). Pricing, scoring, document upload, withdrawal, reassignment, notifications, multi-currency, and bulk audit export are out of scope per the spec.
**Scale/Scope**: PoC. ≤10 seeded users (mix of all role-set combinations including `{applicant, officer}`), ≤5 seeded applications. Approximately 1,000–1,300 LOC across `src/fca_loans/`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Initial check (pre-Phase 0)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | No runtime dependencies planned. `hashlib.sha256` (for the audit chain) is stdlib. `typing.Protocol` is stdlib. Everything else (`http.server`, `sqlite3`, `json`, `uuid`, `datetime`, `threading`, `dataclasses`, `enum`, `argparse`, `urllib.request` (tests only)) is stdlib. |
| II. Test Every Module | PASS | Every module planned under `src/fca_loans/` has a corresponding `tests/fca_loans/test_*.py` (see Project Structure). Plus six dedicated invariant suites: byte-equivalence, audit chain, audit SLA, assignment, no-self-approval, and the catch-all `test_invariants.py` with SC-001…SC-011 probes. |
| III. PEP 8 and Type Hints | PASS | All public functions/methods will carry type hints with modern syntax (`str \| None`, `frozenset[Role]`, `Protocol`, etc.). Linted with ruff. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | The deliverable is an HTTP service. The `python -m fca_loans.server` runner is a thin CLI wrapper exposing `--help`, `--seed`, `--json`, `--port`, `--db-path` with errors on stderr. With `--seed --json` the seeded fixture is emitted as JSON; without `--json` it is printed as a human-readable table. Endpoints are JSON-only by design. |
| V. Explicit Error Handling | PASS | Every failure mode in the spec maps to a typed exception in `errors.py` (`AuthError`, `PermissionDenied`, `NotAssignedOfficer`, `SelfDecisionForbidden`, `ValidationError`, `NotFound`, `HasInFlightApplication`, `InvalidTransition`, `AlreadyDecided`, `AuditUnavailable`) and a documented HTTP status code. No bare `except`. SQLite errors propagate with context. The contended-write `OperationalError` is the only SQLite-specific failure we translate, and we do so deliberately (FR-017 → `503 audit_unavailable`). |
| VI. Clarity Over Cleverness | PASS | Module count is small (≤11 modules). Each module has a single responsibility. Permission rules — including the `applicant_id != caller.user_id` predicate (FR-013) — live in a single explicit table in `permissions.py`. The state machine is three conditional UPDATEs in `store.py`, one per legal transition. The byte-equivalence helper is one function in `responses.py`. The audit chain is one function (`audit.compute_hash`) and one verifier (`audit.verify_chain`). The OAuth boundary is one Protocol (`TokenIntrospector`) with one stub implementation. No metaclasses, decorator-as-DSL, or hand-rolled framework. |

No violations. Initial gate passed.

### Post-design re-check (after Phase 1)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Python Standard Library First | PASS | Phase 1 design did not introduce any non-stdlib dependency. The audit chain uses `hashlib.sha256` (stdlib). |
| II. Test Every Module | PASS | Every module in the Project Structure below has a matching `tests/fca_loans/test_*.py`. The contract documents 17 numbered smoke-test steps in `quickstart.md` covering every endpoint × role-set × success/failure combination relevant to the spec. |
| III. PEP 8 and Type Hints | PASS | Data classes and enums in `data-model.md` use `StrEnum`, `frozenset`, `Protocol`, and modern type-hint syntax. The `AuthenticatedCaller`, `TokenIntrospector`, and `NotificationSink` (absent here — see V below) all have explicit type signatures. |
| IV. Dual-Format CLI Output | PASS (scope-limited) | `quickstart.md` documents `--seed`, `--json`, `--help`, `--port`, `--db-path` on the `python -m fca_loans.server` entry point. |
| V. Explicit Error Handling | PASS | The HTTP API contract (`contracts/http-api.md`) enumerates every error code and the precise condition that raises it; the `errors.py` types map 1:1 to those codes. `AuditUnavailable` (a 503 distinct from `internal_error`) and `SelfDecisionForbidden` (a 403 distinct from `PermissionDenied` and `NotAssignedOfficer`) were added in Phase 1 because the spec mandates the distinct semantics. The byte-equivalent not-found case is not exposed as a typed exception — it is a *response shape*, not an error condition; service-layer "not authorised to see" returns `None` from a return type of `Application | None`, which the handler converts via `not_found_response()`. |
| VI. Clarity Over Cleverness | PASS | Phase 1 added no extra layers. The four endpoints in the contract map directly to four service-layer functions (`submit_application`, `get_application`, `transition_application`, `get_audit`); the permission matrix, the validation rules, the state-machine transitions, the audit-chain encoding, the byte-equivalence helper, and the OAuth introspection seam are each in one obvious place. |

No violations after design. Post-design gate passed.

## Project Structure

### Documentation (this feature)

```text
specs/005-fca-loan-applications/
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
└── fca_loans/
    ├── __init__.py
    ├── __main__.py               # Entry point: python -m fca_loans
    ├── server.py                 # ThreadingHTTPServer wiring + request dispatch + OAuth boundary check + CLI (argparse: --seed, --json, --port, --db-path)
    ├── handlers.py               # Per-endpoint request handlers (parse, authz, call service, format response); contains officer-identity scrubbing for applicant responses (FR-021)
    ├── responses.py              # Canonical response builders. `not_found_response()` returns the fixed byte-equivalent envelope (FR-020/021/022/023); every unauthorised-read code path is required by static check to use it.
    ├── auth.py                   # OAuth 2.0 bearer parsing; `TokenIntrospector` Protocol + `StubIntrospector` (v1, seeded-token table); `AuthenticatedCaller` dataclass with `roles: frozenset[Role]`.
    ├── permissions.py            # Single explicit (role-set, action) → predicate(context) table; the only place authorisation rules live. Predicate for `patch_status_as_assigned_officer` encodes FR-013 (no self-approval) at the boundary.
    ├── service.py                # Business logic: submit_application, get_application, transition_application, get_audit. Returns `None` for any not-authorised-to-see case (handler converts to byte-equivalent not-found).
    ├── validation.py             # Field-level validation; reports all errors at once (FR-006, FR-014); validates `target_status ∈ {under_review,approved,rejected}` and `reason` length 1–1000.
    ├── store.py                  # SQLite schema, connection (timeout=1.8 for FR-017), all SQL. Three conditional UPDATEs encode the three legal status transitions. Round-robin cursor table + atomic assignment transaction. No UPDATE/DELETE code path against `audit_entries` (FR-018).
    ├── audit.py                  # Canonical length-prefixed encoding of audit-entry fields; `compute_hash(prev_hash, application_id, actor_id, actor_role, occurred_at, previous_status, new_status, reason) -> str`; `verify_chain(entries: list[AuditEntry]) -> Literal["intact","tampered"]`.
    ├── models.py                 # Dataclasses: User, AuthenticatedCaller, LoanApplication, AuditEntry; Role, ApplicationStatus, Purpose enums.
    └── errors.py                 # AuthError, PermissionDenied, NotAssignedOfficer, SelfDecisionForbidden, NotFound, ValidationError, HasInFlightApplication, InvalidTransition, AlreadyDecided, AuditUnavailable.

tests/
└── fca_loans/
    ├── __init__.py
    ├── conftest.py               # Fixtures: in-memory DB, seeded users covering every role-set combination, seeded applications, ephemeral-port server, contention helper for SLA tests.
    ├── test_auth.py              # OAuth bearer resolution; 401 paths; ensures no business logic runs on a 401 (SC-010 probe).
    ├── test_permissions.py       # Exhaustive permission matrix across all role sets × all six actions.
    ├── test_validation.py        # Per-field validation; per-field error reporting (FR-006, FR-014).
    ├── test_state_machine.py     # Enumerates all (current_status × target_status) pairs; asserts only the three allowed transitions succeed.
    ├── test_assignment.py        # Round-robin behaviour; applicant excluded (FR-011); cursor durability across simulated process restart; no-eligible-officer edge case produces system-actor audit entry.
    ├── test_self_approval.py     # Defence-in-depth: every code path that could lead to self-decision is refused (permission predicate, SQL filter, schema CHECK). Includes a test that simulates a broken state where `assigned_officer_id == applicant_id` and asserts the PATCH still fails.
    ├── test_byte_equivalence.py  # Constructs (own, other-applicant, fabricated) identifier categories and asserts byte-equivalent responses pairwise (FR-020/021).
    ├── test_audit_chain.py       # Builds an audit chain; verifies it; simulates an out-of-band UPDATE; asserts `tamper_status="tampered"` on subsequent read.
    ├── test_audit_sla.py         # Holds SQLite write lock for 2.5 s in another thread; fires PATCH; asserts (a) `503 audit_unavailable`, (b) state unchanged, (c) no audit entry written.
    ├── test_service.py           # Business-logic unit tests against in-memory DB.
    ├── test_store.py             # Schema, partial unique index for FR-008, self-assignment CHECK, append-only audit (static probe of `store.py` SQL).
    ├── test_handlers.py          # HTTP-level: status codes, response shapes, error envelopes; FR-021 scrubbing on every applicant-role response path.
    └── test_invariants.py        # SC-001…SC-011 catch-all probes including random-pair byte-equivalence sampling and auditor-cannot-write across every write endpoint.
```

**Structure Decision**: A new top-level package `src/fca_loans/` parallel to the three existing packages. The four near-identical-shaped packages are starting to argue for a shared `src/_common/` infrastructure layer (HTTP dispatch, bearer-token plumbing, error envelope, byte-equivalence helper), but extracting it now would require a careful rewrite of the three existing packages and is out of scope for this feature; Constitution VI prefers four duplications over a premature extraction. The duplications here are each ≤50 LOC; revisit after 005 ships.

The internal module shape extends the 004 layout with three new modules:

- `responses.py` — centralises the byte-equivalence helper (new in 005).
- `audit.py` — centralises the chained-hash logic (new in 005).
- The `TokenIntrospector` Protocol in `auth.py` is new; previous features used a direct seeded-token lookup.

The separation between `service.py` (business logic, DB-aware, returns `None` for not-authorised-to-see) and `handlers.py` (HTTP-aware, converts `None` → byte-equivalent not-found, applies FR-021 scrubbing) is what lets unit tests exercise the permission/decision/audit invariants without standing up a real server, while `test_byte_equivalence.py`, `test_audit_chain.py`, and `test_audit_sla.py` exercise the same rules through the wire to confirm the HTTP layer doesn't bypass them.

## Complexity Tracking

No violations to justify.

The 005 feature is materially more complex than 002/003/004 because the spec elevates four properties to first-class invariants — OAuth 2.0 boundary, byte-equivalent unauthorised response, immutable tamper-detectable audit, audit-write 2-second SLA — that the prior features either did not have or addressed informally. Each property is contained in one module and has a dedicated test suite. The total module count (11) and test-file count (14) is in line with 004 (10 + 9) given the extra properties.

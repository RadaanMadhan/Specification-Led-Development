# Research: Loan Application

**Branch**: `003-loan-application` | **Date**: 2026-05-17

The spec produced no `[NEEDS CLARIFICATION]` markers. This document records the design decisions taken during planning so reviewers can see *what* was chosen, *why*, and *what was rejected*. The pattern intentionally mirrors `specs/002-bank-transfer-audit/research.md` because the two features have the same shape (stdlib HTTP service, SQLite-backed, role-gated endpoints, structurally enforced invariants).

## HTTP server: stdlib `http.server` (ThreadingHTTPServer)

**Decision**: Build the service on `http.server.ThreadingHTTPServer` + a small dispatch in `server.py` that routes `(method, path)` to handler functions in `handlers.py`. No framework.

**Rationale**: Constitution Principle I requires the standard library unless it lacks the capability. Five JSON endpoints with simple request/response shapes do not justify a framework. `ThreadingHTTPServer` also lets us prove FR-012 (concurrent decisions on the same application produce exactly one recorded decision) without a worker pool.

**Alternatives considered**:
- **FastAPI / Flask / Starlette** — ergonomic routing and validation but dozens of transitive dependencies. Rejected by Constitution I.
- **WSGI + `wsgiref.simple_server`** — extra layer with no payoff at this size.
- **Async (`asyncio` + `aiohttp`)** — overkill for a correctness-focused PoC.

## Storage: stdlib `sqlite3`

**Decision**: SQLite via `sqlite3`. File-backed in normal runs, `:memory:` in tests. Schema and all SQL live in `store.py`. One process-wide connection guarded by a `threading.Lock`.

**Rationale**: SQLite gives us four things in-memory dicts cannot:

1. **Structural enforcement of FR-005** (one in-flight application per customer) via a *partial unique index*: `CREATE UNIQUE INDEX idx_one_pending_per_customer ON loan_applications(customer_id) WHERE status = 'Pending Review'`. The schema, not just the code, rejects a duplicate pending application. SQLite supports partial indexes since 3.8 (Python 3.11's bundled SQLite is well past that).
2. **Structural enforcement of FR-012** (no two recorded decisions on the same application) via the conditional `UPDATE loan_applications SET status=?, … WHERE id=? AND status='Pending Review'`. The `rowcount==1` post-condition tells the service whether *this* request won the race; `rowcount==0` means someone else already decided it and the request is rejected with `409 already_decided`.
3. **Atomic write semantics** for FR-009 + FR-010 + FR-016. The status update, decision insert, and audit-event insert all happen inside one `BEGIN IMMEDIATE … COMMIT` block, so we cannot end up with a decided status and no decision row, or a decision row without an audit event.
4. **Append-only audit at two layers**: at the code layer (no UPDATE/DELETE statement targets `application_events` anywhere in `store.py`) and at the integration-test layer (a probe in `test_invariants.py` proves no public path mutates an audit row).

It is a Python stdlib module so Constitution I is satisfied.

**Alternatives considered**:
- **In-memory dicts + `threading.Lock`** — loses the partial unique index and the natural atomicity. The two invariants (one-in-flight, one-decision) would rest entirely on code correctness, which the spec specifically calls out as zero-tolerance items (SC-004, SC-005).
- **PostgreSQL** — non-stdlib. Rejected on Constitution I; not justified at this scale.

## Authentication: stub bearer-token resolver

**Decision**: `Authorization: Bearer <token>` on every request. Tokens are seeded at startup from a `tokens` table mapping each token to a `User`. Missing/invalid tokens → `401 unauthenticated` *before* any handler logic.

**Rationale**: The spec puts real customer / staff auth out of scope (Assumptions: "Customers are already authenticated through the bank's existing customer identity system"). A bearer token mapped to a seeded user is the smallest construct that satisfies "the caller is identified and has a role" and reads identically to the conventional production shape, so the real auth implementation can drop in 1:1 later. This matches the precedent in 002.

**Alternatives considered**:
- **`X-User-Id` header** — simpler, but loses the "verify token → look up user" shape.
- **Real password / JWT auth** — out of scope per spec.

## Authorisation: explicit permission table

**Decision**: A single function `permissions.is_allowed(role, action, context)` consults an explicit `(Role, Action) → predicate(context)` table. Every endpoint calls it exactly once, before invoking the service layer.

**Rationale**: Constitution Principle VI (clarity over cleverness). FR-015 makes role-gating a first-class invariant (SC-004 = zero customer-sees-other-customer cases, zero customer-makes-decision cases). Centralising the rules makes `test_permissions.py` exhaustive by enumeration.

**Table summary** (full table lives in `permissions.py`):

| Role         | submit_application | list_own_applications | view_own_application | list_pending_queue | view_any_application | decide_application |
|--------------|---|---|---|---|---|---|
| `customer`   | ✅ | ✅ | ✅ (own only) | ❌ | ❌ | ❌ |
| `bank_staff` | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |

`customer` view of an application is gated by ownership (`application.customer_id == caller.id`). `bank_staff` does not need to own anything; the role itself authorises.

**Alternatives considered**:
- **Decorator-per-handler** — pushes rules across the codebase; harder to audit. Rejected by VI.
- **Calling `is_allowed` from the service layer** — works, but mixes HTTP-layer concerns into business logic. Keeping the check in the handler matches 002.

## Reference number format: `LA-YYYY-NNNNNN`

**Decision**: Every application gets a human-readable reference of the form `LA-<submission-year>-<6-digit-zero-padded-seq>` (e.g., `LA-2026-000042`). The sequence comes from an `AUTOINCREMENT` integer primary key on `loan_applications`; the year is taken from the submission timestamp. The formatted reference is stored as a `TEXT UNIQUE NOT NULL` column so customers see and quote one stable string.

**Rationale**: FR-004 requires "unique, human-readable reference number". `LA-` prefix communicates "loan application", year aids triage, six digits cover ~1M applications per year. `AUTOINCREMENT` ensures monotonic, never-reused integers, even if a row is deleted (we don't delete, but defence in depth). Storing the formatted reference avoids re-deriving it on every read.

**Alternatives considered**:
- **Raw UUID4 as reference** — unique, but not human-readable; bad to read out over the phone (which is exactly the use-case for a reference number).
- **Random short code** — collision-resistant generators add complexity; AUTOINCREMENT + format is trivially correct.

## Notifications (FR-014): in-app status + logged email stub

**Decision**: The "in-app" notification channel is the customer's own `GET /applications` and `GET /applications/{id}` responses — when an application's status changes, the customer sees it on next read. The "email" channel, when the customer's `contact_preference` is `email`, is a stub: the service writes a structured line to stdout (`[notification] to=alice@example.com app=LA-2026-000042 status=Approved …`) via a `NotificationSink` interface. Tests inject a recording sink and assert that the right notification was emitted.

**Rationale**: FR-014 requires the system to notify *via the customer's recorded contact preference*, but the Assumptions section explicitly defers the actual email transport to the bank's existing notification mechanisms (out of scope for this feature). A `NotificationSink` interface with a single stdout-printing implementation makes the integration point obvious and testable now and replaceable later. "In-app at minimum" is naturally satisfied because the status is visible on the customer's own endpoints.

**Alternatives considered**:
- **No email stub at all** — would fail FR-014 testability; we'd have no way to assert that "email customers get the email-path triggered".
- **Real SMTP via `smtplib`** — pulls in real network I/O for a PoC and fights the Assumptions section. Rejected.

## Validation strategy

**Decision**: A single function `validation.validate_application_submission(payload)` runs all field-level checks (presence, numeric type, amount in £1,000–£25,000 inclusive, term in {12, 24, 36, 48, 60}, employer_name present iff employment_status is `employed`, contact_preference in {`in_app`, `email`}) and returns either a normalised `LoanApplicationDraft` dataclass or raises `ValidationError` with the offending field and message. The handler catches `ValidationError` and serialises it to a `400 validation_error` response that lists every offending field — not just the first one.

**Rationale**: FR-002 requires field-level messages; reporting all errors at once is friendlier than fail-fast. Keeping validation in a separate module keeps `service.py` focused on business logic and lets `test_validation.py` enumerate boundary cases by table.

## Project layout

**Decision**: A new top-level package `src/loan_application/` parallel to the existing `src/bank_transfer/` package. Tests under `tests/loan_application/` to avoid colliding with the existing `tests/test_*.py` for 002.

**Rationale**: The features are independent — different domain, different storage, different endpoints. Sharing a package would entangle them. Mirroring the 002 internal structure (handlers / service / store / models / permissions / errors / auth / __main__) gives reviewers a familiar shape and lets `test_invariants.py`-style probes be written by analogy.

**Alternatives considered**:
- **One mega-package** — couples unrelated features.
- **Promote shared infra (HTTP dispatch, auth) to `src/_common/`** — premature; two packages is not enough to justify shared infra, and copy-paste-now-extract-later is cleaner per Constitution VI.

## What is intentionally NOT researched

- **Pricing, APR, monthly repayment calculation** — out of scope (Assumptions).
- **Creditworthiness scoring** — out of scope (Assumptions).
- **Document upload** — out of scope for v1.
- **Customer-initiated withdrawal** — out of scope for v1.
- **6-year retention enforcement at storage layer** — retention is a policy on top of "we don't delete"; the service has no DELETE code path for applications or decisions, which satisfies the requirement at v1 scale. Real retention scheduling is operational tooling outside this feature.

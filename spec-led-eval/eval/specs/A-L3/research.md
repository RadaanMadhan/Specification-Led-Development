# Research: FCA-Regulated Loan Application

**Branch**: `005-fca-loan-applications` | **Date**: 2026-05-17

The spec produced no `[NEEDS CLARIFICATION]` markers; the implicit choices the user description left open were resolved with documented defaults. This document records the *technical* design decisions taken during planning. The pattern intentionally mirrors `specs/004-loan-application-rbac/research.md` (the closest precedent — same three-role shape) and focuses on what is **new in 005**:

1. **OAuth 2.0 bearer** as a real interface boundary (v1 stub behind the seam).
2. **Automatic round-robin officer assignment** at submission, atomic with insert + audit.
3. **No self-approval** as a defence-in-depth SQL filter.
4. **PATCH-as-only-mutation** endpoint covering both `pending→under_review` and `under_review→approved|rejected`.
5. **Audit-write 2-second SLA** via in-transaction commit + fail-fast `503`.
6. **Tamper-detectable** audit log via a chained-hash structure (stdlib `hashlib`).
7. **Byte-equivalent unauthorised response** via a single fixed `not_found` envelope returned from a centralised helper.

## HTTP server: stdlib `http.server` (ThreadingHTTPServer)

**Decision**: As 002/003/004. `http.server.ThreadingHTTPServer` + dispatch in `server.py`. No framework.

**Rationale**: Constitution Principle I. Four JSON endpoints with simple request/response shapes do not justify a framework. `ThreadingHTTPServer` lets us prove the concurrent-PATCH and concurrent-claim invariants (FR-009, FR-012, FR-015) under real concurrency.

## Storage: stdlib `sqlite3`

**Decision**: SQLite via `sqlite3`. File-backed in production-style runs; `:memory:` in tests. Schema and all SQL in `store.py`. One process-wide connection guarded by `threading.Lock`. Connection opened with `timeout=1.8` (seconds) so a contended write fails fast within the FR-017 budget.

**Rationale**: As prior features, plus three new structural enforcements in 005:

1. **FR-009 status transitions — three conditional `UPDATE`s, one per legal transition.** Each filters on the source `status` so only the legal transitions can produce rowcount=1:
   - `UPDATE applications SET status='under_review' WHERE id=? AND status='pending' AND assigned_officer_id=? AND applicant_id != ?` (officer starts review)
   - `UPDATE applications SET status='approved' WHERE id=? AND status='under_review' AND assigned_officer_id=? AND applicant_id != ?` (officer approves)
   - `UPDATE applications SET status='rejected' WHERE id=? AND status='under_review' AND assigned_officer_id=? AND applicant_id != ?` (officer rejects)
2. **FR-013 no self-approval is in the SQL filter** (`applicant_id != ?` against the caller). The permission table also gates the action at the boundary; the SQL filter is defence-in-depth so a code-path bypass would still not produce a self-decision. SC-006 = 0 self-decisions ever.
3. **FR-008 one in-flight per applicant — partial unique index** `UNIQUE(applicant_id) WHERE status IN ('pending','under_review')`. Same shape as 004's index; new identifier names.

For each PATCH, `rowcount=0` triggers a single *informational* SELECT to discriminate the four failure modes (`404 not_found`, `403 not_assigned_officer`, `403 self_decision_forbidden`, `409 invalid_transition`, `409 already_decided`). The SELECT is purely for the error envelope and carries no TOCTOU risk (we already failed to act; we are now describing why).

**Why the 1.8 s connection timeout**: FR-017 budgets 2 s for "the audit entry is persisted". Since the audit row is inserted in the same transaction as the state change, "audit persisted" = "transaction COMMITted". Under contention, SQLite blocks waiting for the lock and raises `OperationalError("database is locked")` after the configured timeout; we catch that and return `503 audit_unavailable`. The transaction is rolled back automatically, so no half-state escapes. 1.8 s leaves ~200 ms of headroom for response serialisation and network egress before the 2 s wall budget runs out. Verifiable by a test fixture that intentionally holds the write lock for 2.5 s in another thread.

**Alternatives considered**:
- **Async audit writer (queue + worker)** — would decouple state change from audit write but introduces a window where state has changed but audit hasn't been persisted; FR-017 explicitly forbids this. Rejected.
- **PostgreSQL** — non-stdlib. Rejected on Constitution I; not justified at this scale.

## Authentication: OAuth 2.0 bearer with a stub introspector behind the seam

**Decision**: All endpoints authenticate via `Authorization: Bearer <token>`. Validation runs through a `TokenIntrospector` protocol object whose v1 implementation is a `StubIntrospector` that resolves tokens against a seeded `tokens` table (carryover from prior features). The protocol matches the shape of an RFC 7662 OAuth 2.0 Token Introspection response, so swapping in a real `OAuth2Introspector` later is a one-line wiring change.

```python
class TokenIntrospector(Protocol):
    def introspect(self, token: str) -> AuthenticatedCaller | None: ...

@dataclass(frozen=True)
class AuthenticatedCaller:
    user_id: str
    roles: frozenset[Role]   # {applicant} | {officer} | {auditor} | {applicant, officer} | {applicant, auditor}
    token_expires_at: datetime
```

**Rationale**: The spec puts the OAuth 2.0 token-issuance / refresh / revocation server out of scope (Assumptions), but is firm that:

- OAuth 2.0 bearer is the production auth (FR-001).
- 401 is returned **before any business logic** for any missing/malformed/invalid token (FR-001, SC-010).

The `TokenIntrospector` seam matches both contracts: at v1, the stub gives us deterministic seeded behaviour and an obvious extension point; for real deployment, the OAuth 2.0 introspection endpoint produces the same `AuthenticatedCaller` shape.

**Where the 401 happens**: in `server.py`'s dispatch, *before* the request is routed to a handler. The handler never sees an unauthenticated request, so business logic never runs on one. FR-001 + SC-010 testable by instrumentation.

**Role multiplicity**: FR-002 allows `applicant + officer` or `applicant + auditor` but never `officer + auditor`. `roles` is a `frozenset`, and the role check on every action is "does `roles` intersect the set required by this action"; a user with `{applicant, officer}` can submit (applicant action) *and* decide (officer action), but FR-013's no-self-approval still applies. The `frozenset` is validated at construction to forbid the `{officer, auditor}` combination.

**Alternatives considered**:
- **Plain bearer-token stub, no introspector seam** — would work for v1 but burns the seam later. Rejected; the seam is one extra protocol class for a near-zero cost.
- **JWT validation with stdlib** (`hashlib`/`hmac`) — possible but overcomplicates v1; introspection is the right OAuth 2.0 boundary for an application-level resource server.

## Authorisation: explicit (role, action, context) → predicate table

**Decision**: As 004. A single `permissions.is_allowed(roles, action, context)` function consults an explicit table. Every endpoint calls it exactly once. With three roles and the multi-role twist, the table operates on the **role set** (intersection-based), not a single role.

**Table summary** (full table lives in `permissions.py`):

| Action                              | Required role set intersection | Per-action predicate                                                    |
|-------------------------------------|--------------------------------|-------------------------------------------------------------------------|
| `submit`                            | `{applicant}`                  | none                                                                    |
| `view_own`                          | `{applicant}`                  | `application.applicant_id == caller.user_id`                            |
| `view_any`                          | `{auditor}`                    | none                                                                    |
| `view_as_assigned_officer`          | `{officer}`                    | `application.assigned_officer_id == caller.user_id`                     |
| `patch_status_as_assigned_officer`  | `{officer}`                    | `application.assigned_officer_id == caller.user_id AND application.applicant_id != caller.user_id` |
| `view_audit`                        | `{auditor}`                    | none                                                                    |

The permission table is the **only** place authorisation rules live. The predicate for `patch_status_as_assigned_officer` already encodes FR-013 (no self-approval) at the boundary; the SQL `WHERE applicant_id != ?` clause is defence-in-depth.

**Note on the byte-equivalence invariant**: the permission failure for `view_own` / `view_as_assigned_officer` / `view_audit` does not produce a `403 permission_denied` for non-auditor / non-owner callers — it produces the byte-equivalent `404 not_found` (see "Byte-equivalent unauthorised response" below).

## Automatic round-robin officer assignment (FR-010, FR-011)

**Decision**: At submission time, inside a single `BEGIN IMMEDIATE` transaction, the system:

1. `SELECT id FROM users WHERE role='officer' AND id != ? ORDER BY id` — the eligible officer pool, sorted deterministically. (Excluding the applicant satisfies FR-011 even if the applicant is also an `officer`.)
2. `SELECT next_position FROM officer_rotation WHERE id=1 FOR UPDATE` (in SQLite syntax: a row in a one-row `officer_rotation` table; the `BEGIN IMMEDIATE` lock provides the equivalent serialisation).
3. If the pool is empty: insert the application with `assigned_officer_id = NULL` and a system-actor initial audit entry recording "no eligible officer available; assignment deferred" (FR-011 edge case).
4. Otherwise: pick `officers[next_position % len(officers)]`, increment `next_position` (modulo a large value to prevent overflow), `UPDATE officer_rotation`, insert the application with that `assigned_officer_id`, and insert the initial audit entry.
5. `COMMIT`.

If any step fails, the whole transaction rolls back; the applicant sees a server error and no application exists. FR-017's SLA applies (1.8 s connection timeout); a contended write fails with `503 audit_unavailable`.

**Why a one-row `officer_rotation` table**: cleaner than a global counter in code (which doesn't survive process restart) and trivially correct under concurrency (the BEGIN IMMEDIATE makes the read-modify-write atomic).

**Deterministic ordering** of the officer pool (sorted by `id`) plus a persisted cursor gives bit-for-bit reproducibility — important for FR-010's "deterministic given the system's officer roster and prior assignment history" wording and for test fixtures.

**Alternatives considered**:
- **Random assignment** — fails FR-010's "deterministic" wording; auditors couldn't replay the assignment.
- **Load-balanced by current open queue** — Out of scope for v1 (Assumptions); the spec says round-robin.
- **In-Python cursor + load on startup** — loses durability across restart; the next first-after-restart assignment could repeat an officer. Rejected.

## Audit log: chained-hash for tamper-detection (FR-018)

**Decision**: Each audit entry stores a `entry_hash` column whose value is the SHA-256 (stdlib `hashlib`) of the canonical bytes:

```text
prev_hash || application_id || actor_id || actor_role || timestamp || previous_status || new_status || reason
```

where `prev_hash` is the `entry_hash` of the previous audit entry for the same `application_id` (chronological order), or a fixed all-zero seed for the first entry. The canonical encoding is UTF-8 with each field length-prefixed by a 4-byte big-endian unsigned integer to prevent ambiguity (no "Smith|2026" vs "Smit|h2026" collisions).

Verification (`audit.verify_chain(entries)`) walks the entries in chronological order, recomputes the chain, and asserts every stored `entry_hash` matches. Any mismatch → `tamper_status = "tampered"` is surfaced on read; integrity is what the read endpoint reports, never silently.

**Where verification runs**:

- `GET /applications/{id}/audit` runs verification on every read and includes a top-level `tamper_status: "intact" | "tampered"` field. Auditors (the only readers of this endpoint) see the status directly.
- A nightly job (operational, outside this feature) can run a system-wide verification across every chain and alert if any returns `tampered`. The current feature exposes the per-chain primitive that makes such a job trivial.

**Rationale**: FR-018 requires that out-of-band modification (e.g., a manual `UPDATE audit_entries SET reason='x' WHERE id=42`) is **detectable on subsequent read** — not prevented (we don't have RDBMS-level write protections in stdlib SQLite), but detectable. A chained-hash log is the standard primitive for that property; it requires no external library (`hashlib.sha256` is stdlib).

**What this does NOT defend against**:

- An attacker with full DB control who recomputes the entire chain after their forgery — they can produce a chain that verifies. This is the standard "trust on first write" limit of a single-writer chained log. Defending against this requires periodic publication of the chain head to an external trust root (e.g., a regulator's WORM store or a signing service); that publication is out of scope for v1 and would be added in a future feature.
- The append-only invariant at the code layer is enforced separately: no UPDATE/DELETE code path in `store.py` targets `audit_entries`, and `test_invariants.py` includes a grep-style static probe and a runtime probe.

**Alternatives considered**:
- **No tamper detection** — fails FR-018.
- **Per-row HMAC with a secret key** — needs key management (out of scope); also weaker than a chain because it doesn't detect row deletion.
- **External WORM storage / append-only ledger service** — requires a non-stdlib dependency or a third-party service; out of scope for v1.

## Audit-write 2-second SLA (FR-017)

**Decision**: The audit row is INSERTed in the same DB transaction as the state-change UPDATE (and, on submission, as the application INSERT and the rotation-cursor UPDATE). The SQLite connection is opened with `timeout=1.8` (seconds). Under contention, `BEGIN IMMEDIATE` or `COMMIT` will block waiting for the write lock and raise `sqlite3.OperationalError` after 1.8 s; the handler catches that and returns `503 audit_unavailable` with an empty audit log (the transaction was rolled back).

**Rationale**: Single-transaction commit gives us "either both visible or neither" atomicity (FR-017's "no half-state ever exposed"). 1.8 s gives 200 ms of headroom for response serialisation before the 2 s wall budget. SC-002 (≤1% of `PATCH` requests return 503; **zero** observable state changes lack a corresponding audit) is satisfied by construction.

**Measurement**: a test in `test_audit_sla.py` holds the write lock in a separate thread for 2.5 s, fires a PATCH, and asserts (a) `503 audit_unavailable` response, (b) application status unchanged, (c) no audit entry was written.

## Byte-equivalent unauthorised response (FR-020, FR-021, FR-022)

**Decision**: The system uses a **single fixed not-found response** for any `GET /applications/{id}` or `GET /applications/{id}/audit` where the caller is not authorised to read the resource:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8
Content-Length: 53

{"error":"not_found","message":"No such application."}
```

Same status line, same body bytes, same `Content-Type`, same `Content-Length` for **every** unauthorised-read case:

- `{id}` does not refer to any application.
- `{id}` refers to an application owned by a different applicant (caller is applicant).
- `{id}` refers to an application not assigned to the caller (caller is officer, not auditor).
- `{id}` is `GET …/audit` but caller is not an auditor.

A single helper `responses.not_found_response()` returns the canonical bytes. All four call sites use it; a test in `test_byte_equivalence.py` builds three categories of identifiers — owned, other-applicant, fabricated — and asserts the response tuple `(status_code, content_type_header, content_length_header, body_bytes)` is identical across every pair the spec mentions.

**Headers explicitly out of scope for byte-equivalence**: `Date` (clock-dependent), `Server` (we set it to a constant), `Connection` (transport-dependent). The test compares only headers under the application's control: `Content-Type`, `Content-Length`, and the absence of any leak-prone headers (e.g., `X-Application-Status`).

**Timing**: the spec acknowledges "response timing within reasonable jitter" — we do not implement constant-time response in v1. We do, however, guarantee that the not-found path takes the same code path regardless of whether the id exists, so the variance between "real other-applicant id" and "fabricated id" is one extra DB hit (the existence check). Documented as a known minor side channel; tightening this is out of scope for v1.

**Where the decision is made**: in `service.get_application(id, caller)` and `service.get_audit(id, caller)`. The service function returns `None` for *any* not-authorised case; the handler converts `None` to the fixed not-found response. There is no other path that produces a 404 on the application endpoints.

**Alternatives considered**:
- **Return different 4xx codes per case** — would leak existence (e.g., 403 implies "exists but not yours"). Rejected; that's exactly what FR-020 forbids.
- **Constant-time response with simulated DB hit on fabricated id** — would defend the timing side channel. Documented as future work; not v1.

## Status state machine and PATCH endpoint

**Decision**: A single `PATCH /applications/{id}/status` endpoint with body `{"status": "<target>", "reason": "<text>"}`. The handler dispatches to a single service function `service.transition_application(id, target_status, reason, caller)` that:

1. Validates `target_status ∈ {'under_review','approved','rejected'}` and `reason` is non-empty (FR-014).
2. Looks up the application; if not authorised to act on it, returns the appropriate error after the discriminating SELECT pattern.
3. Maps `target_status` to the expected source status: `under_review` ⇐ `pending`; `approved`/`rejected` ⇐ `under_review`.
4. Runs the appropriate conditional `UPDATE` with the source-status filter, the caller-is-assigned-officer filter, and the caller-is-not-applicant filter. On rowcount=1: insert audit entry in same transaction; commit; return 200.
5. On rowcount=0: SELECT the application to determine the right 4xx (`404 not_found`, `403 not_assigned_officer`, `403 self_decision_forbidden`, `409 invalid_transition`, `409 already_decided`).

Three explicit transitions; no other transitions are SQL-reachable.

## Reason field length (1–1000 characters)

**Decision**: `1 ≤ length(reason) ≤ 1000` enforced both at validation time (in `validation.py`) and by `CHECK(length(reason) BETWEEN 1 AND 1000)` on the `audit_entries` table.

## Project layout: `src/fca_loans/` package

**Decision**: New top-level package `src/fca_loans/` parallel to `src/bank_transfer/` (002), `src/loan_application/` (003), `src/loan_workflow/` (004). Tests under `tests/fca_loans/`.

**Rationale**: 005 is a distinct feature with different invariants (OAuth boundary, byte-equivalence, tamper-detectable chain, no-self-approval). Sharing a package with 003 or 004 would entangle the invariants. A fourth near-identical-shaped package is starting to argue for a shared `src/_common/` infrastructure layer (HTTP dispatch, bearer-token plumbing, error envelope) — research.md flags this as a refactor candidate after 005 ships, but Constitution VI prefers four duplications over premature extraction; the duplications here are each ≤50 LOC.

## What is intentionally NOT researched

These are out of scope per the spec's Out of Scope section and need no design here:

- OAuth 2.0 token-issuance server, refresh flow, revocation, JWKS rotation, consent UI.
- Identity governance (which user holds which role).
- Pricing, APR, monthly-repayment, creditworthiness scoring, KYC, AML, sanctions screening.
- Document upload by the applicant.
- Customer-initiated withdrawal / cancellation.
- Manager / supervisor role; in-product reassignment of `under_review`.
- Editing applicant-submitted fields after submission.
- Multi-currency support.
- Notification delivery channels.
- Bulk audit-export endpoint.
- Pagination / search across applications.

6-year retention (FR-019) is satisfied by the absence of any DELETE code path against `audit_entries`. Periodic publication of the chain head to an external trust root (to defend FR-018 against a full-DB attacker) is documented above as future work.

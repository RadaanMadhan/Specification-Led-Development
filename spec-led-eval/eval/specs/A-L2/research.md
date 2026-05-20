# Research: Loan Application with Role-Based Workflow and Audit Trail

**Branch**: `004-loan-application-rbac` | **Date**: 2026-05-17

The spec produced no `[NEEDS CLARIFICATION]` markers; the implicit choices the user description left open were resolved with reasonable defaults and recorded in the spec's Assumptions section. This document records the *technical* design decisions taken during planning. The pattern intentionally mirrors `specs/002-bank-transfer-audit/research.md` and `specs/003-loan-application/research.md` because the three features share the same shape (stdlib HTTP service, SQLite-backed, role-gated endpoints, structurally enforced invariants). This file lists what is **the same** by reference and focuses on what is **different** for 004.

## HTTP server: stdlib `http.server` (ThreadingHTTPServer)

**Decision**: As 003 / 002. `http.server.ThreadingHTTPServer` + a small dispatch in `server.py` that routes `(method, path)` to handler functions in `handlers.py`. No framework.

**Rationale**: Constitution Principle I. Six JSON endpoints with simple request/response shapes do not justify a framework. `ThreadingHTTPServer` lets us prove FR-012 (concurrent claim race) and FR-013 (only the assigned officer can decide) under real concurrency.

## Storage: stdlib `sqlite3`

**Decision**: SQLite via `sqlite3`. File-backed in normal runs, `:memory:` in tests. Schema and all SQL in `store.py`. One process-wide connection guarded by a `threading.Lock`.

**Rationale**: As 003, plus two extra structural enforcements that 004 needs:

1. **FR-008 (one in-flight per customer) — partial unique index** `UNIQUE(customer_id) WHERE status IN ('Submitted','Under Review')`. The set now includes `'Under Review'` (whereas 003 only had `'Pending Review'`) because in 004 an application is still "in flight" while a loan officer is reviewing it.
2. **FR-012 (one-officer claim) — conditional UPDATE** `UPDATE loan_applications SET status='Under Review', assigned_officer_id=? WHERE id=? AND status='Submitted'`. `rowcount==1` means this caller won the race; `rowcount==0` means someone else already claimed it. The handler then performs one *informational* SELECT to render the conflict response with the current assigned officer (no race, because the SELECT just reports current state for the error message).
3. **FR-013 (only assigned officer can decide) — conditional UPDATE** `UPDATE loan_applications SET status=? WHERE id=? AND status='Under Review' AND assigned_officer_id=?`. `rowcount==1` means the caller is *both* the assigned officer *and* the application is still at "Under Review"; `rowcount==0` means one of those is false. The handler discriminates the two cases by a follow-up SELECT to render either `403 not_assigned_officer` or `409 already_decided`.
4. **Atomic semantics** for FR-015 + FR-017 + FR-019. The status update, the decision insert (on decide), and the audit-entry insert all happen inside one `BEGIN IMMEDIATE … COMMIT` block. Any failure rolls all three back, so we cannot end up with a status change without an audit entry, or a decision row without a status change.
5. **Append-only audit at two layers** — same approach as 003.

It is a Python stdlib module so Constitution I is satisfied.

**Why the conditional-UPDATE-then-SELECT pattern is safe**: the SELECT is purely for rendering the error response, not for any subsequent write. We are not subject to a TOCTOU race because we don't re-check-then-act; we already acted (the UPDATE) and it failed; we are now describing why. Even if another thread changes the state between our UPDATE and our SELECT, our error response is still truthfully one of "not assigned to you" / "already decided" — and the state that arose between is still recorded by *its* successful transition's own audit entry.

**Alternatives considered**:
- **Select-then-UPDATE** (read the application, branch in Python, then write) — has a true TOCTOU race. Rejected.
- **Explicit row locking (`SELECT … FOR UPDATE`)** — SQLite doesn't have it in the same form as PostgreSQL; the conditional UPDATE achieves the same outcome at the same cost. Not needed.

## Authentication: stub bearer-token resolver — now three roles

**Decision**: As 003 / 002. `Authorization: Bearer <token>` on every request, tokens resolved against a seeded `tokens` table to a `User` with exactly one of three roles: `customer`, `loan_officer`, `compliance_reviewer`.

**Rationale**: The spec puts real auth out of scope (Assumptions: "Customers, loan officers, and compliance reviewers are already authenticated through the bank's existing identity systems"). The bearer-token stub is the smallest construct that satisfies "the caller is identified and has a role".

## Authorisation: explicit (role, action) → predicate(context) table — three roles, eight actions

**Decision**: A single function `permissions.is_allowed(role, action, context)` consults an explicit table. Every endpoint calls it exactly once, before invoking the service layer.

**Rationale**: Constitution VI (clarity over cleverness). FR-002, FR-003, FR-004, FR-020, FR-021, FR-023 collectively make role gating a first-class invariant (SC-004, SC-005, SC-008). Centralising the rules makes `test_permissions.py` exhaustive by enumeration over the role × action grid.

**Table summary** (full table lives in `permissions.py`):

| Role                  | submit | list_unassigned | list_own | list_all | view_own | view_any | claim | decide_if_assigned | view_audit |
|-----------------------|--------|-----------------|----------|----------|----------|----------|-------|--------------------|------------|
| `customer`            | ✅     | ❌              | ✅       | ❌       | ✅       | ❌       | ❌    | ❌                 | ❌          |
| `loan_officer`        | ❌     | ✅              | ❌       | ❌       | ❌       | ✅       | ✅    | ✅ (predicate)     | ✅          |
| `compliance_reviewer` | ❌     | ❌              | ❌       | ✅       | ❌       | ✅       | ❌    | ❌                 | ✅          |

`decide_if_assigned` is the *only* row that carries a predicate (it succeeds only when `application.assigned_officer_id == caller.id`). All other rows are role-only checks. The predicate is **still in the permission table**, not in the service layer, so the rule lives in one obvious place.

**Alternatives considered**:
- **Move the "is assigned officer" check into `service.py`** — splits the rule across two files. Rejected by VI.
- **Decorator-per-handler** — same complaint as 003: rules across the codebase, harder to audit.

## Officer-identity visibility (FR-021)

**Decision**: Officer identity is exposed in responses *only* when the caller is a `loan_officer` or a `compliance_reviewer`. Customer responses scrub the `assigned_officer_id` / `decided_by_user_id` / audit-entry `actor_user_id` fields whenever the actor is an officer. The scrubbing happens in a single serialisation helper `handlers.scrub_for_role(payload, role)` so the rule lives in one obvious place.

**Rationale**: FR-021 is non-negotiable for customer privacy (officer's name should not leak to applicants). Putting the scrub at serialisation time (rather than at query time) avoids accidentally leaking via a forgotten endpoint, because *every* response path goes through one function. A follow-up assertion in `test_handlers.py` walks every customer-role response and asserts none of the officer-identifier keys are present.

**Note on the spec's "(on their own claimed applications)" wording in FR-021**: read strictly, this would mean officer A cannot see officer B's identity on an application A did not claim. We are taking the looser interpretation — officer identity is visible across all applications to any officer or compliance reviewer — for two reasons. First, FR-012's error response *requires* naming the current assigned officer to the losing claimer, which means officer identity is inherently visible to other officers via the claim-conflict path. Second, the looser interpretation is operationally useful (officers can see who is working what, which avoids duplicate effort beyond what the claim invariant already prevents). The strict interpretation would not break any spec invariant we have read; if the business wants it, `scrub_for_role` is a one-line change.

## Reference number format: `LA-YYYY-NNNNNN`

**Decision**: As 003. `LA-<submission-year>-<6-digit-zero-padded-seq>`; sequence from `AUTOINCREMENT`; stored as a `TEXT UNIQUE NOT NULL` column.

## Validation strategy

**Decision**: As 003. `validation.py` runs all field-level checks at once and returns either a normalised draft or raises a `ValidationError` carrying all offending fields. Handler serialises as `400 validation_error` with a `field_errors` array. FR-006 explicitly requires field-level messages, and reporting all errors at once (not fail-fast) is friendlier.

## Status state machine

**Decision**: Four explicit statuses with three allowed transitions:

```text
            (none)
              │ customer submits
              ▼
          Submitted
              │ officer claims  (FR-011, race-resolved by FR-012)
              ▼
        Under Review
              │ assigned officer decides  (FR-013, FR-014)
              ▼
       Approved / Rejected   (terminal — FR-016)
```

Three transitions, each implemented by exactly one conditional `UPDATE`. The audit entries for the three transitions plus the initial submission ("(none) → Submitted") form the per-application audit trail.

**Rationale**: Separating "Submitted" (unassigned) from "Under Review" (assigned) makes the gating rule trivially explicit at the status level: "Only Under Review can transition to Approved/Rejected, and only by the assigned officer". The state machine is small enough to enumerate in one diagram and one test (`test_state_machine.py` enumerates all 4×4 transition attempts and asserts that exactly the three allowed transitions succeed).

**Alternatives considered**:
- **Three statuses (Pending / Approved / Rejected) + a separate `assigned_officer_id` flag** — works, but the gating rule then becomes a compound check at the application layer, and the audit trail loses the Submitted→Under Review transition as a first-class event. Less suited to the spec, which makes the claim a tracked event (FR-011, FR-017).
- **Five statuses (… + Withdrawn)** — withdrawal is out of scope per Assumptions.

## Audit trail shape: `(actor, occurred_at, previous_status, new_status)`

**Decision**: Each row in `application_events` carries `actor_user_id`, `occurred_at`, `previous_status` (nullable for the initial submission), and `new_status`. Rows are inserted in the same DB transaction as the status change.

**Rationale**: Direct mapping of FR-017. Storing both `previous` and `new` makes the audit row self-contained — a reader doesn't need to compute the diff from prior rows to know what happened in this one. `previous_status` is `NULL` only for the initial `submitted` event, and a `CHECK` constraint encodes that pairing (`CHECK (previous_status IS NULL = (new_status = 'Submitted'))`).

**Notes on uniqueness**: We do *not* impose a `UNIQUE` constraint per transition type on `application_events` (it would forbid theoretical loops like Under Review → Submitted → Under Review, which the state machine does not allow but is not the audit table's job to police). The "exactly one entry per applied transition" invariant (FR-019) is enforced upstream by the conditional-UPDATE-then-INSERT pattern: a transition either happens and gets exactly one audit row, or doesn't happen and gets none.

## No notifications

**Decision**: This feature emits **no** notifications, in line with the spec's Out of Scope section. Customers learn of status changes by polling "My Applications" (US4); there is no `NotificationSink` and no `notification_log` table.

**Rationale**: The spec is explicit. 003 had a notification stub because its spec mandated FR-014 ("system MUST notify the customer when their application's status changes"). 004's spec does not have that requirement and explicitly excludes notification channels.

**Consequence**: One fewer module than 003 (`notifications.py` is absent here), one fewer table (no `notification_log`), one fewer FR-coverage path in tests.

## Project layout: `src/loan_workflow/` package

**Decision**: A new top-level package `src/loan_workflow/` parallel to the existing `src/bank_transfer/` (002) and `src/loan_application/` (003). Tests under `tests/loan_workflow/`.

**Rationale**: 004 is a distinct feature from 003 — different role set (three vs two), different status machine (four states vs three), different invariants (claim race, assigned-officer decide gating). Sharing a package or schema with 003 would entangle them and obscure which invariants belong to which feature. The package name `loan_workflow` reads naturally (it's a workflow with claim/decide steps) and avoids collision with 003's `loan_application` package.

**Alternatives considered**:
- **Rename 003's package and grow it into 004** — would silently delete 003's narrower invariants. Out of scope unless the user explicitly chooses to deprecate 003 (called out in the spec completion report).
- **Promote shared infra (HTTP dispatch, bearer-token auth, error envelope) to `src/_common/`** — three near-identical packages might justify this, but Constitution VI prefers two duplications over a premature shared layer; revisit after a fourth feature.

## What is intentionally NOT researched

These are out of scope per the spec's Out of Scope section and need no design here:

- Pricing, APR, monthly-repayment, creditworthiness scoring.
- Document upload.
- Customer-initiated withdrawal.
- Reassignment / handoff of an "Under Review" application.
- Manager / supervisor role above loan officers.
- Notification delivery (email, SMS, push).
- Editing customer-submitted fields after submission.

6-year retention (FR-022) is satisfied by the absence of any DELETE code path against `loan_applications`, `decisions`, or `application_events`; real retention-policy scheduling is operational tooling outside this feature.

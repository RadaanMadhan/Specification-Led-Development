# Quickstart: FCA-Regulated Loan Application

**Branch**: `005-fca-loan-applications` | **Date**: 2026-05-17

## Prerequisites

- Python 3.11 or later
- macOS or Linux
- No third-party packages are required at runtime (Constitution Principle I). `hashlib` (for the audit chain) and `sqlite3` are stdlib.

## Install (development)

From the repository root:

```bash
pip install -e .[dev]
```

`[dev]` only pulls in `pytest` and `ruff` for testing and linting; the runtime is stdlib-only.

## Run the server

```bash
python -m fca_loans.server --seed --port 8083 --db-path ./fca_loans.db
```

Flags:

| Flag        | Default              | Meaning                                                                                                                                                       |
|-------------|----------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--port`    | `8083`               | TCP port to bind on `127.0.0.1`. Differs from 002 (`8080`), 003 (`8081`), 004 (`8082`) so all four services can run side by side locally.                       |
| `--db-path` | `./fca_loans.db`     | SQLite file. Use `:memory:` for an ephemeral run.                                                                                                              |
| `--seed`    | off                  | If set, seed three applicants, three officers, one auditor, eight bearer tokens, and one already-submitted application. Idempotent — safe on a populated DB. |
| `--json`    | off                  | When combined with `--seed`, emit the seeded fixture as JSON on stdout instead of the human-readable table (Constitution IV — dual-format output).            |
| `--help`    | —                    | Human-readable usage on stdout.                                                                                                                                |

Errors print to stderr. The audit-write SLA is governed by the SQLite connection `timeout=1.8` (seconds); under contention, contended writes return `503 audit_unavailable` rather than block past the spec's 2-second budget.

## Seeded fixture

`--seed` produces a deterministic fixture (same UUIDs, same tokens every run) so the smoke commands below work verbatim:

| Role set                   | Username           | Token                | Notes                                                              |
|----------------------------|--------------------|----------------------|--------------------------------------------------------------------|
| `{applicant}`              | `alice`            | `tkn-alice`          |                                                                    |
| `{applicant}`              | `bob`              | `tkn-bob`            | Has the seeded in-flight application below.                        |
| `{applicant}`              | `carol`            | `tkn-carol`          |                                                                    |
| `{officer}`                | `officer_dan`      | `tkn-dan`            |                                                                    |
| `{officer}`                | `officer_emma`     | `tkn-emma`           |                                                                    |
| `{applicant, officer}`     | `officer_frank`    | `tkn-frank-officer`  | Dual-role: can submit (as applicant) and decide others' applications (as officer). |
| `{applicant, officer}`     | `officer_frank`    | `tkn-frank-applicant`| Same user, different token (token-issuance is out of scope). For tests; not strictly required. |
| `{auditor}`                | `auditor_gina`     | `tkn-gina`           | Read-only across the entire system.                                |

Seeded application:

| Application id (UUID-shaped) | Applicant | Amount   | Purpose             | Status   | Assigned officer  |
|------------------------------|-----------|----------|---------------------|----------|-------------------|
| `app-bob-001`                | `bob`     | £6,000   | `vehicle`           | pending  | `officer_dan`     |

(Identifiers are nominally UUID4-shaped strings; the seed uses readable placeholders for the quickstart only.)

The corresponding audit trail has one entry: `(none) → pending` by `bob`.

## Smoke test — end-to-end happy path

These commands assume the seeded server is running on `:8083`.

### 1. Alice submits an application (US1)

```bash
curl -sS -X POST http://127.0.0.1:8083/applications \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "amount_minor": 750000, "purpose": "home_improvement" }'
```

Expected: `201 Created`, fresh `id`, `status: "pending"`, `assigned_officer_id` **absent** (Alice is an applicant; FR-021). The audit chain now has one entry for this application: `(none) → pending` by `alice`.

### 2. Alice tries to submit again while in flight (FR-008)

Replay step 1. Expected: `409 has_in_flight_application`, `existing_application_id` = the id from step 1.

### 3. Alice cannot see Bob's application (FR-020, SC-004)

```bash
curl -sS -i http://127.0.0.1:8083/applications/app-bob-001 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: `404 Not Found`, `Content-Length: 53`, body `{"error":"not_found","message":"No such application."}`. This response is byte-identical to:

```bash
curl -sS -i http://127.0.0.1:8083/applications/fabricated-id-that-never-existed \
  -H 'Authorization: Bearer tkn-alice'
```

### 4. Officer Dan views his assigned application (US2)

```bash
curl -sS http://127.0.0.1:8083/applications/app-bob-001 \
  -H 'Authorization: Bearer tkn-dan'
```

Expected: `200 OK`, full record including `applicant_id: <bob's uuid>`, `assigned_officer_id: <dan's uuid>`, `status: "pending"`.

### 5. Officer Emma tries to view the same application (FR-012)

```bash
curl -sS -i http://127.0.0.1:8083/applications/app-bob-001 \
  -H 'Authorization: Bearer tkn-emma'
```

Expected: byte-equivalent `404 not_found` (same body as step 3) — Emma is not the assigned officer and not an auditor, so the read is byte-equivalent unauthorised.

### 6. Officer Dan starts review (`pending` → `under_review`)

```bash
curl -sS -X PATCH http://127.0.0.1:8083/applications/app-bob-001/status \
  -H 'Authorization: Bearer tkn-dan' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "under_review", "reason": "Picked up for review" }'
```

Expected: `200 OK`, `status: "under_review"`. Audit chain now has two entries.

### 7. Officer Emma tries to PATCH the application Dan owns (FR-012, SC-005)

```bash
curl -sS -X PATCH http://127.0.0.1:8083/applications/app-bob-001/status \
  -H 'Authorization: Bearer tkn-emma' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "approved", "reason": "Override" }'
```

Expected: `403 not_assigned_officer`, `assigned_officer_id` echoed. Application state and audit log unchanged.

### 8. Officer Dan tries an empty reason (FR-014)

```bash
curl -sS -X PATCH http://127.0.0.1:8083/applications/app-bob-001/status \
  -H 'Authorization: Bearer tkn-dan' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "approved", "reason": "" }'
```

Expected: `400 validation_error`, `field_errors` lists `reason`. Application state and audit log unchanged.

### 9. Officer Dan tries to skip a stage (FR-009)

```bash
curl -sS -X PATCH http://127.0.0.1:8083/applications/app-bob-001/status \
  -H 'Authorization: Bearer tkn-dan' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "pending", "reason": "go back" }'
```

Expected: `400 validation_error` (target `pending` is not a legal PATCH target; only `under_review`, `approved`, `rejected`).

Alternative: replay step 6 (target `under_review` again) — expected `409 invalid_transition` because the current status is now `under_review` (the source for `under_review` is `pending`).

### 10. Officer Dan approves (FR-015)

```bash
curl -sS -X PATCH http://127.0.0.1:8083/applications/app-bob-001/status \
  -H 'Authorization: Bearer tkn-dan' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "approved", "reason": "Income comfortably covers requested amount." }'
```

Expected: `200 OK`, `status: "approved"`, `decision_status: "approved"`, `decided_at`, `decision_reason` populated. Audit chain now has three entries.

### 11. Officer Dan tries to re-decide (FR-015)

Replay step 10 with `{"status":"rejected","reason":"changed mind"}`. Expected: `409 already_decided`, `current_status: "approved"`. State unchanged.

### 12. Bob sees his own decision (US4)

```bash
curl -sS http://127.0.0.1:8083/applications/app-bob-001 \
  -H 'Authorization: Bearer tkn-bob'
```

Expected: `200 OK`, `status: "approved"`, `decision_reason` populated. `assigned_officer_id`, `applicant_id`, and `decided_by_user_id` are **absent** from Bob's response (FR-021).

### 13. Auditor Gina inspects the audit trail (US3, FR-018)

```bash
curl -sS http://127.0.0.1:8083/applications/app-bob-001/audit \
  -H 'Authorization: Bearer tkn-gina'
```

Expected: `200 OK`, `tamper_status: "intact"`, `events` array of length 3 in chronological order. Each event has `actor_id`, `actor_role`, `occurred_at`, `previous_status`, `new_status`, `reason`, `prev_hash`, `entry_hash`.

### 14. Auditor Gina tries to write — every action is refused (FR-005, FR-023, SC-007)

```bash
# Submit as auditor
curl -sS -X POST http://127.0.0.1:8083/applications \
  -H 'Authorization: Bearer tkn-gina' -H 'Content-Type: application/json' \
  -d '{ "amount_minor": 100000, "purpose": "other" }'

# PATCH as auditor
curl -sS -X PATCH http://127.0.0.1:8083/applications/app-bob-001/status \
  -H 'Authorization: Bearer tkn-gina' -H 'Content-Type: application/json' \
  -d '{ "status": "rejected", "reason": "x" }'
```

Expected for both: `403 permission_denied`. No state changes anywhere.

### 15. Officer Frank submits his own application (dual-role) and gets a different officer assigned (FR-011)

```bash
curl -sS -X POST http://127.0.0.1:8083/applications \
  -H 'Authorization: Bearer tkn-frank-applicant' \
  -H 'Content-Type: application/json' \
  -d '{ "amount_minor": 500000, "purpose": "debt_consolidation" }'
```

Expected: `201 Created`, `assigned_officer_id` is either `officer_dan` or `officer_emma` — **never** Frank (FR-011, even though Frank holds `officer`).

### 16. Officer Frank tries to PATCH his own application (FR-013, SC-006)

If somehow Frank were the assigned officer (which the auto-assignment prevents), he must still not be able to decide it:

```bash
# Hypothetical: assume the auto-assignment broke and assigned Frank to himself.
# Test infrastructure can simulate this by directly setting assigned_officer_id in the DB.
curl -sS -X PATCH http://127.0.0.1:8083/applications/<frank-app-id>/status \
  -H 'Authorization: Bearer tkn-frank-officer' \
  -H 'Content-Type: application/json' \
  -d '{ "status": "approved", "reason": "self" }'
```

Expected: `403 self_decision_forbidden`. Even with Frank set as the assigned officer (via test-only DB tampering), the SQL filter `applicant_id != ?` plus the permission predicate prevent self-decision (defence-in-depth). Production code paths cannot reach this state, but the test exists.

### 17. Auditor Gina verifies the tamper detector (FR-018)

```bash
# 1. Read the audit; observe tamper_status: "intact".
curl -sS http://127.0.0.1:8083/applications/app-bob-001/audit \
  -H 'Authorization: Bearer tkn-gina' | jq -r '.tamper_status'

# 2. The test harness tampers with the DB out-of-band:
sqlite3 ./fca_loans.db "UPDATE audit_entries SET reason='altered' WHERE application_id='app-bob-001' AND new_status='approved';"

# 3. Read the audit again; observe tamper_status: "tampered".
curl -sS http://127.0.0.1:8083/applications/app-bob-001/audit \
  -H 'Authorization: Bearer tkn-gina' | jq -r '.tamper_status'
```

Expected: `intact` on step 1, `tampered` on step 3. The events are still returned so the auditor can see what was altered.

## Smoke test — auth boundary and byte-equivalence probes

| What to do                                                                       | Expected response                                  | Why it matters                                    |
|----------------------------------------------------------------------------------|----------------------------------------------------|---------------------------------------------------|
| Any request with `Authorization: Bearer not-a-real-token`                        | `401 unauthenticated`                              | FR-001, SC-010 (OAuth boundary).                  |
| Any request with no `Authorization` header                                       | `401 unauthenticated`                              | FR-001 (missing header).                          |
| `GET /applications/{any-id}` from Bob (whose only app is `app-bob-001`) where `{any-id}` is fabricated | `404 not_found`, body bytes identical to step 3 | FR-020 (byte-equivalence to non-existent).        |
| `GET /applications/{alice-app-id}` from Bob                                      | `404 not_found`, body bytes identical to above    | FR-021 (byte-equivalence across other-applicant). |
| `GET /applications/{app-bob-001}/audit` from Bob, Dan, or Frank-officer (non-auditor) | `404 not_found`, body bytes identical to above | FR-023 (audit endpoint exists only for auditors).  |
| `GET /applications/{app-bob-001}/audit` from Gina (auditor)                      | `200 OK` with audit chain                          | FR-018.                                            |

## Run the tests

```bash
pytest tests/fca_loans -q
```

Test groupings:

| File                                            | What it covers                                                                                                                       |
|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| `tests/fca_loans/test_auth.py`                  | OAuth bearer resolution; 401 paths; ensures no business logic runs on a 401 (SC-010 probe).                                          |
| `tests/fca_loans/test_permissions.py`           | Exhaustive permission matrix across all role sets and all six actions.                                                                |
| `tests/fca_loans/test_validation.py`            | Per-field validation; per-field error reporting (FR-006, FR-014).                                                                    |
| `tests/fca_loans/test_state_machine.py`         | Enumerates all (current_status, target_status) pairs and asserts only the three allowed transitions succeed.                          |
| `tests/fca_loans/test_assignment.py`            | Round-robin assignment; exclusion of applicant from pool (FR-011); cursor durability across simulated process restart; "no eligible officer" edge case. |
| `tests/fca_loans/test_self_approval.py`         | Officer-as-applicant defence-in-depth: every code path that could lead to self-decision is refused (permission predicate, SQL filter, schema CHECK). |
| `tests/fca_loans/test_byte_equivalence.py`      | Constructs three categories of identifiers (own, other-applicant, fabricated) and asserts byte-equivalent responses across pairs (FR-020/021). |
| `tests/fca_loans/test_audit_chain.py`           | Builds an application's audit chain, verifies it, simulates a tampered entry, asserts `tamper_status="tampered"` on read.            |
| `tests/fca_loans/test_audit_sla.py`             | Holds the SQLite write lock in another thread for 2.5 s, fires a PATCH, asserts (a) `503 audit_unavailable`, (b) state unchanged, (c) no audit entry written. |
| `tests/fca_loans/test_service.py`               | Business logic — submit, transition, list, view — against in-memory DB.                                                              |
| `tests/fca_loans/test_store.py`                 | Schema, partial unique index for FR-008, self-assignment CHECK, append-only audit (static probe of `store.py` SQL).                   |
| `tests/fca_loans/test_handlers.py`              | HTTP-level: status codes, response shapes, error envelopes; officer-identity scrubbing on every applicant-role response (FR-021).     |
| `tests/fca_loans/test_invariants.py`            | SC-001…SC-011 probes including the byte-equivalence probe across random pairs and the auditor-cannot-write probe across every write endpoint. |

## Style and lint

```bash
ruff check src/fca_loans tests/fca_loans
```

Type hints on all public functions; `str | None` syntax (Constitution III); Protocol classes for `TokenIntrospector` and `NotificationSink` (though notifications are out of scope, the introspector seam is real).

## When you're done

Stop the server with `Ctrl+C`. The `./fca_loans.db` file persists; delete it before re-seeding from scratch.

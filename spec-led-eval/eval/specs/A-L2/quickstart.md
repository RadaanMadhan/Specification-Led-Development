# Quickstart: Loan Application with Role-Based Workflow and Audit Trail

**Branch**: `004-loan-application-rbac` | **Date**: 2026-05-17

## Prerequisites

- Python 3.11 or later
- macOS or Linux
- No third-party packages are required at runtime (Constitution Principle I).

## Install (development)

From the repository root:

```bash
pip install -e .[dev]
```

`[dev]` only pulls in `pytest` and `ruff` for testing and linting; the runtime is stdlib-only.

## Run the server

```bash
python -m loan_workflow.server --seed --port 8082 --db-path ./loan_workflow.db
```

Flags:

| Flag         | Default                | Meaning                                                                                                                          |
|--------------|------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| `--port`     | `8082`                 | TCP port to bind on `127.0.0.1`. Differs from 002 (`8080`) and 003 (`8081`) so all three services can run side by side locally. |
| `--db-path`  | `./loan_workflow.db`   | SQLite file. Use `:memory:` for an ephemeral run.                                                                                |
| `--seed`     | off                    | If set, seed three customers, two loan officers, one compliance reviewer, six bearer tokens, and one already-submitted application. Idempotent — safe on a populated DB. |
| `--json`     | off                    | When combined with `--seed`, emit the seeded fixture as JSON on stdout instead of the human-readable table (Constitution IV — dual-format output for the CLI entry point). |
| `--help`     | —                      | Human-readable usage on stdout.                                                                                                  |

Errors print to stderr.

## Seeded fixture

`--seed` produces a deterministic fixture (same UUIDs, same tokens every run) so the smoke commands below work verbatim:

| Role                  | Username           | Token              | Notes                                          |
|-----------------------|--------------------|--------------------|------------------------------------------------|
| `customer`            | `alice`            | `tkn-alice`        |                                                |
| `customer`            | `bob`              | `tkn-bob`          | Has the seeded in-flight application below.    |
| `customer`            | `carol`            | `tkn-carol`        |                                                |
| `loan_officer`        | `officer_brenda`   | `tkn-brenda`       |                                                |
| `loan_officer`        | `officer_dan`      | `tkn-dan`          |                                                |
| `compliance_reviewer` | `compliance_evan`  | `tkn-evan`         | Read-only across the entire system.            |

Seeded application:

| Reference        | Customer | Amount  | Purpose                | Status    | Assigned officer |
|------------------|----------|---------|------------------------|-----------|------------------|
| `LA-2026-000001` | `bob`    | £6,000  | "Used-car purchase"    | Submitted | — (unassigned)   |

The corresponding audit trail has one entry: `(none) → Submitted` by `bob`.

## Smoke test — end-to-end happy path

These commands assume the seeded server is running on `:8082`.

### 1. Alice submits an application (US1)

```bash
curl -sS -X POST http://127.0.0.1:8082/applications \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "requested_amount_minor": 750000, "purpose": "Kitchen renovation" }'
```

Expected: `201 Created`, fresh `reference` (e.g., `LA-2026-000002`), `status: "Submitted"`.

### 2. Bob tries to submit a second application (FR-008)

```bash
curl -sS -X POST http://127.0.0.1:8082/applications \
  -H 'Authorization: Bearer tkn-bob' \
  -H 'Content-Type: application/json' \
  -d '{ "requested_amount_minor": 500000, "purpose": "Holiday" }'
```

Expected: `409 has_in_flight_application` with `existing_reference: "LA-2026-000001"`, `existing_status: "Submitted"`.

### 3. Alice cannot see Bob's application (FR-020, SC-004)

```bash
curl -sS http://127.0.0.1:8082/applications/LA-2026-000001 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: `404 not_found` (no existence leak — *not* `403`).

### 4. Brenda views the unassigned queue (US2, FR-010)

```bash
curl -sS http://127.0.0.1:8082/applications \
  -H 'Authorization: Bearer tkn-brenda'
```

Expected: `200 OK`, two applications (`LA-2026-000001` and Alice's new one from step 1) at `status: "Submitted"`, oldest first.

### 5. Brenda claims Bob's application (US2, FR-011)

```bash
curl -sS -X POST http://127.0.0.1:8082/applications/LA-2026-000001/claim \
  -H 'Authorization: Bearer tkn-brenda'
```

Expected: `200 OK`, `status: "Under Review"`, `assigned_officer_name: "Officer Brenda"`. A new audit entry `Submitted → Under Review` is now visible to officers and compliance.

### 6. Dan races to claim the same application (FR-012, SC-006)

```bash
curl -sS -X POST http://127.0.0.1:8082/applications/LA-2026-000001/claim \
  -H 'Authorization: Bearer tkn-dan'
```

Expected: `409 already_claimed`, body names `assigned_officer_name: "Officer Brenda"`.

### 7. Dan tries to decide Bob's application anyway (FR-013, SC-005)

```bash
curl -sS -X POST http://127.0.0.1:8082/applications/LA-2026-000001/decision \
  -H 'Authorization: Bearer tkn-dan' \
  -H 'Content-Type: application/json' \
  -d '{ "decision_type": "Approved", "reason": "Override." }'
```

Expected: `403 not_assigned_officer`. The application's status and audit trail are unchanged.

### 8. Brenda approves Bob's application (FR-015)

```bash
curl -sS -X POST http://127.0.0.1:8082/applications/LA-2026-000001/decision \
  -H 'Authorization: Bearer tkn-brenda' \
  -H 'Content-Type: application/json' \
  -d '{ "decision_type": "Approved", "reason": "Income comfortably covers requested amount." }'
```

Expected: `200 OK`, `status: "Approved"`, decision fields populated. Audit trail now has three entries: submitted, claimed, approved.

### 9. Brenda tries to re-decide (FR-016)

Replay step 8. Expected: `409 already_decided` with `current_status: "Approved"`.

### 10. Bob sees his own decision (US4)

```bash
curl -sS http://127.0.0.1:8082/applications/LA-2026-000001 \
  -H 'Authorization: Bearer tkn-bob'
```

Expected: `200 OK`, `status: "Approved"`, `decision_reason: "Income comfortably covers requested amount."`. Officer-identifier fields (`assigned_officer_id`, `assigned_officer_name`, `decided_by_user_id`, `decided_by_username`) are **absent** in Bob's response (FR-021).

### 11. Evan (compliance) views the full audit trail (US3, FR-018)

```bash
curl -sS http://127.0.0.1:8082/applications/LA-2026-000001/audit \
  -H 'Authorization: Bearer tkn-evan'
```

Expected: `200 OK`, `events` array of length 3 in chronological order:

| # | previous_status | new_status   | actor                |
|---|-----------------|--------------|----------------------|
| 1 | `null`          | Submitted    | `bob` (customer)     |
| 2 | Submitted       | Under Review | `officer_brenda`     |
| 3 | Under Review    | Approved     | `officer_brenda`     |

Each event has `actor_user_id`, `actor_username`, `occurred_at`, `previous_status`, `new_status` (FR-017).

### 12. Evan (compliance) tries to write — every action is refused (US3, FR-023, SC-008)

```bash
# Submit as compliance
curl -sS -X POST http://127.0.0.1:8082/applications \
  -H 'Authorization: Bearer tkn-evan' -H 'Content-Type: application/json' \
  -d '{ "requested_amount_minor": 100000, "purpose": "test" }'

# Claim as compliance
curl -sS -X POST http://127.0.0.1:8082/applications/LA-2026-000002/claim \
  -H 'Authorization: Bearer tkn-evan'

# Decide as compliance
curl -sS -X POST http://127.0.0.1:8082/applications/LA-2026-000001/decision \
  -H 'Authorization: Bearer tkn-evan' -H 'Content-Type: application/json' \
  -d '{ "decision_type": "Approved", "reason": "x" }'
```

Expected for all three: `403 permission_denied`. No state changes anywhere.

## Smoke test — failure paths to inspect by hand

| What to do                                                                     | Expected response                              | Why it matters                |
|--------------------------------------------------------------------------------|------------------------------------------------|-------------------------------|
| `POST /applications` with `Authorization: Bearer not-a-real-token`             | `401 unauthenticated`                          | Auth boundary (FR-001).       |
| `POST /applications` with `requested_amount_minor: 50000` (below £1,000 min)   | `400 validation_error`, `field_errors` lists `requested_amount_minor` | FR-006, FR-007.               |
| `POST /applications` with `requested_amount_minor: 50000` **and** empty `purpose` | `400 validation_error`, `field_errors` lists **both** fields | FR-006 explicitly: per-field, not fail-fast. |
| `POST /applications/{ref}/decision` with `reason: ""` as the assigned officer  | `400 validation_error`, `field_errors` lists `reason` | FR-014.                       |
| `POST /applications/{ref}/claim` as a customer                                 | `403 permission_denied`                        | FR-002, SC-004.               |
| `POST /applications` as a loan officer                                         | `403 permission_denied`                        | FR-003.                       |
| `POST /applications/{ref}/decision` as a loan officer who didn't claim it      | `403 not_assigned_officer`                     | FR-013, SC-005.               |
| `POST /applications/LA-9999-999999/claim` as a loan officer                    | `404 not_found`                                | Standard not-found.           |
| `GET /applications/LA-2026-000001/audit` as a customer                         | `403 permission_denied`                        | FR-002, FR-021.               |

## Run the tests

```bash
pytest tests/loan_workflow -q
```

Test groupings:

| File                                          | What it covers                                                                                          |
|-----------------------------------------------|---------------------------------------------------------------------------------------------------------|
| `tests/loan_workflow/test_auth.py`            | Bearer-token resolution; 401 paths.                                                                     |
| `tests/loan_workflow/test_permissions.py`     | Exhaustive (role × action × context) matrix across all three roles and all eight actions.               |
| `tests/loan_workflow/test_validation.py`      | Field-level validation; per-field error reporting (FR-006).                                             |
| `tests/loan_workflow/test_state_machine.py`   | Enumerates all 4×4 status-transition attempts and asserts that exactly the three allowed ones succeed.   |
| `tests/loan_workflow/test_service.py`         | Business logic — submit, claim, decide, list, view — against in-memory DB.                              |
| `tests/loan_workflow/test_store.py`           | Schema, partial unique index for FR-008, claim/decide atomicity, no DELETE path on append-only tables.   |
| `tests/loan_workflow/test_handlers.py`        | HTTP-level: status codes, response shapes, error envelopes; officer-identity scrubbing on customer responses (FR-021). |
| `tests/loan_workflow/test_invariants.py`      | SC-004…SC-008 probes: concurrent claim race (FR-012), only-assigned-officer-decides (FR-013), append-only audit (FR-018), compliance-cannot-write probe across every write endpoint, no-cross-customer-leak. |

## Style and lint

```bash
ruff check src/loan_workflow tests/loan_workflow
```

Type hints on all public functions; `str | None` syntax (Constitution III).

## When you're done

Stop the server with `Ctrl+C`. The `./loan_workflow.db` file persists; delete it before re-seeding from scratch.

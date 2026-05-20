# Quickstart: Loan Application

**Branch**: `003-loan-application` | **Date**: 2026-05-17

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
python -m loan_application.server --seed --port 8081 --db-path ./loan_application.db
```

Flags:

| Flag         | Default                  | Meaning                                                                                                |
|--------------|--------------------------|--------------------------------------------------------------------------------------------------------|
| `--port`     | `8081`                   | TCP port to bind on `127.0.0.1`. Differs from 002's `8080` so both services can run side by side locally. |
| `--db-path`  | `./loan_application.db`  | SQLite file. Use `:memory:` for an ephemeral run.                                                       |
| `--seed`     | off                      | If set, seed two customers, two staff users, four bearer tokens, and one already-pending application. Idempotent — safe on a populated DB. |
| `--help`     | —                        | Human-readable usage on stdout.                                                                         |

Errors print to stderr; the server prints the seeded tokens (when `--seed` is given) to stdout so you can paste them into `curl`. The same `--seed` run also supports `--json` to emit the seeded fixture in JSON form (Constitution IV — dual-format output for the CLI entry point).

## Seeded fixture

`--seed` produces a deterministic fixture (same UUIDs, same tokens every run) so the smoke commands below work verbatim:

| Role         | Username       | Token                | Notes                                                                  |
|--------------|----------------|----------------------|------------------------------------------------------------------------|
| `customer`   | `alice`        | `tkn-alice-in_app`   | `contact_preference = in_app`.                                         |
| `customer`   | `bob`          | `tkn-bob-email`      | `contact_preference = email`; receives a notification stub on decision. |
| `bank_staff` | `staff_brenda` | `tkn-brenda`         |                                                                        |
| `bank_staff` | `staff_carl`   | `tkn-carl`           |                                                                        |

Seeded application:

| Reference        | Customer | Amount   | Term | Status         |
|------------------|----------|----------|------|----------------|
| `LA-2026-000001` | `alice`  | £5,000   | 36   | Pending Review |

## Smoke test — end-to-end happy path

These commands assume the seeded server is running on `:8081`.

### 1. Bob submits an application (US1 happy path)

```bash
curl -sS -X POST http://127.0.0.1:8081/applications \
  -H 'Authorization: Bearer tkn-bob-email' \
  -H 'Content-Type: application/json' \
  -d '{
    "requested_amount_minor": 750000,
    "term_months": 24,
    "purpose": "Debt consolidation",
    "employment_status": "self_employed",
    "gross_annual_income_minor": 3800000
  }'
```

Expected: `201 Created`, response body containing a fresh `reference` like `LA-2026-000002` and `status: "Pending Review"`.

### 2. Bob tries to submit a second one (FR-005)

Replay the same `curl`. Expected: `409 has_pending_application` with `existing_reference: "LA-2026-000002"`.

### 3. Alice cannot see Bob's application (FR-013, SC-004)

```bash
curl -sS http://127.0.0.1:8081/applications/LA-2026-000002 \
  -H 'Authorization: Bearer tkn-alice-in_app'
```

Expected: `404 not_found` — *not* `403`. We do not leak the existence of other customers' applications.

### 4. Brenda views the pending queue (US2, FR-007)

```bash
curl -sS http://127.0.0.1:8081/applications \
  -H 'Authorization: Bearer tkn-brenda'
```

Expected: `200 OK`, two pending applications (`LA-2026-000001` and `LA-2026-000002`), oldest first.

### 5. Brenda approves Bob's application (US2)

```bash
curl -sS -X POST http://127.0.0.1:8081/applications/LA-2026-000002/decision \
  -H 'Authorization: Bearer tkn-brenda' \
  -H 'Content-Type: application/json' \
  -d '{
    "decision_type": "Approved",
    "reason": "Income covers requested term comfortably."
  }'
```

Expected: `200 OK`, body shows `status: "Approved"`, `decision_type: "Approved"`, `decided_by_user_id: <brenda-uuid>`. The server stdout shows a `[notification] to=bob@example.com app=LA-2026-000002 status=Approved …` line because Bob's `contact_preference` is `email`.

### 6. Carl tries to approve the same application a second later (FR-012, SC-005)

```bash
curl -sS -X POST http://127.0.0.1:8081/applications/LA-2026-000002/decision \
  -H 'Authorization: Bearer tkn-carl' \
  -H 'Content-Type: application/json' \
  -d '{ "decision_type": "Rejected", "reason": "Disagree." }'
```

Expected: `409 already_decided`, body shows `current_status: "Approved"`. Carl's decision is **not** recorded — the DB still has exactly one row in `decisions` for `LA-2026-000002`.

### 7. Bob sees his own decision (US3)

```bash
curl -sS http://127.0.0.1:8081/applications/LA-2026-000002 \
  -H 'Authorization: Bearer tkn-bob-email'
```

Expected: `200 OK`, `status: "Approved"`, `decision_reason: "Income covers requested term comfortably."`. `decided_by_user_id` is **not** in the response (staff identity is not exposed to customers).

### 8. Staff audit trail (FR-016)

```bash
curl -sS http://127.0.0.1:8081/applications/LA-2026-000002/audit \
  -H 'Authorization: Bearer tkn-brenda'
```

Expected: `200 OK`, `events` array of length 2 (`submitted`, then `approved`), oldest first.

## Smoke test — failure paths to inspect by hand

| What to do                                                                 | Expected response                              | Why it matters                |
|----------------------------------------------------------------------------|------------------------------------------------|-------------------------------|
| `POST /applications` with `Authorization: Bearer not-a-real-token`         | `401 unauthenticated`                          | Auth boundary (FR-015).       |
| `POST /applications` with `requested_amount_minor: 50000` (£500, below min) | `400 validation_error`, `field_errors` lists `requested_amount_minor` | FR-002, FR-003.               |
| `POST /applications` with both `requested_amount_minor: 50000` and `term_months: 18` | `400 validation_error`, `field_errors` lists **both** fields | FR-002 explicitly: per-field, not fail-fast. |
| `POST /applications/{ref}/decision` with `reason: ""` as staff             | `400 validation_error`, `field_errors` lists `reason` | FR-009.                       |
| `POST /applications/{ref}/decision` as a customer                          | `403 permission_denied`                        | FR-015, SC-004.               |
| `POST /applications` as staff                                              | `403 permission_denied`                        | FR-015, SC-004.               |
| `GET /applications/LA-9999-999999` as anyone                               | `404 not_found`                                | Standard not-found.           |

## Run the tests

```bash
pytest tests/loan_application -q
```

Test groupings:

| File                              | What it covers                                                                |
|-----------------------------------|-------------------------------------------------------------------------------|
| `tests/loan_application/test_auth.py`        | Bearer-token resolution, 401 paths.                            |
| `tests/loan_application/test_permissions.py` | Exhaustive (role × action) matrix.                              |
| `tests/loan_application/test_validation.py`  | Field-level validation, per-field error reporting (FR-002).    |
| `tests/loan_application/test_service.py`     | Business logic — submit, decide, list, view — against in-memory DB. |
| `tests/loan_application/test_store.py`       | Schema, partial unique index, decision atomicity, no DELETE path. |
| `tests/loan_application/test_handlers.py`    | HTTP-level: status codes, response shapes, error envelopes.    |
| `tests/loan_application/test_invariants.py`  | SC-001…SC-006 probes (incl. concurrency for FR-012, no cross-customer leak for FR-013, append-only audit for FR-016). |

## Style and lint

```bash
ruff check src/loan_application tests/loan_application
```

Type hints on all public functions; `str | None` syntax (Constitution III).

## When you're done with the smoke test

Stop the server with `Ctrl+C`. The `./loan_application.db` file persists; delete it before re-seeding from scratch.

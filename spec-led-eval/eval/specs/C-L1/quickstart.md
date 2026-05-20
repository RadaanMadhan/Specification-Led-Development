# Quickstart: Clinician Access to Patient Medical Records (v1)

**Branch**: `009-clinician-record-access` | **Date**: 2026-05-17

> **Trial-context note**: this is a teaching/research trial of speckit, not a real clinical deployment. The PoC seed data is fictional. Do not use this PoC against real patient data.

## Prerequisites

- Python 3.11 or later
- macOS or Linux
- No third-party packages are required at runtime (Constitution Principle I).

## Install (development)

From the repository root:

```bash
pip install -e .[dev]
```

## Run the server

```bash
python -m clinician_record_access.server --seed --port 8087 --db-path ./clinician_record_access.db
```

Flags:

| Flag        | Default                          | Meaning                                                                                                                                                  |
|-------------|----------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--port`    | `8087`                           | TCP port to bind on `127.0.0.1`. Differs from 002–008 so all packages can run side by side locally.                                                       |
| `--db-path` | `./clinician_record_access.db`   | SQLite file. Use `:memory:` for an ephemeral run. WAL mode is enabled at startup.                                                                         |
| `--seed`    | off                              | If set, seed users (one of each clinician role), patients, patient summaries, encounters, care-team memberships, and bearer tokens.                       |
| `--json`    | off                              | When combined with `--seed`, emit the seeded fixture as JSON on stdout.                                                                                  |
| `--help`    | —                                | Human-readable usage on stdout.                                                                                                                           |

Errors print to stderr.

## Seeded fixture

`--seed` produces a deterministic fixture:

**Users**:

| Username   | Token            | Display name        | Role            |
|------------|------------------|---------------------|-----------------|
| `alice`    | `tkn-alice`      | Dr Alice Carter     | `doctor`        |
| `barbara`  | `tkn-barbara`    | Nurse Barbara Lee   | `nurse`         |
| `colin`    | `tkn-colin`      | Pharmacist Colin Hu | `pharmacist`    |
| `diana`    | `tkn-diana`      | IG Officer Diana M. | `audit_officer` |
| `evan`     | `tkn-evan`       | Dr Evan Outsider    | `doctor`        |

`evan` is a doctor with no care-team memberships — used for the cross-care-team probes.

**Patients** (all fictional):

| Patient id    | Name              | DoB         | Allergies            | Key warnings              |
|---------------|-------------------|-------------|----------------------|---------------------------|
| `pat-001`     | Patient One       | 1972-04-19  | Penicillin (severe)  | Fall risk                 |
| `pat-002`     | Patient Two       | 1985-11-02  | (none)               | (none)                    |

**Care-team memberships** (active):

| Clinician  | Patient   | Episode      | Status   |
|------------|-----------|--------------|----------|
| `alice`    | `pat-001` | `ep-a-001`   | `active` |
| `alice`    | `pat-002` | `ep-a-002`   | `active` |
| `barbara`  | `pat-001` | `ep-b-001`   | `active` |
| `colin`    | `pat-002` | `ep-c-002`   | `active` |

(So: Alice can see both patients; Barbara sees pat-001; Colin sees pat-002; Diana sees no patients but can audit; Evan sees nothing.)

## Smoke test — end-to-end happy path

These commands assume the seeded server is running on `:8087`.

### 1. Dr Alice looks up her patient pat-001 (FR-006, US1)

```bash
curl -sS -X POST http://127.0.0.1:8087/records/lookup \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: `200 OK`. Body has the keys in exactly this order:
`patient_id`, `date_of_birth`, `name`, `allergies`, `key_warnings`, `current_medications`, `recent_encounters` (FR-014, FR-015). The `allergies` array contains the Penicillin entry. The audit log now has one new entry with `outcome = "permitted"`, `authorisation_basis = "care_team_member"`, `clinician_role = "doctor"`.

### 2. Dr Evan tries to look up pat-001 (no care-team-membership) (FR-006, FR-007, SC-010)

```bash
curl -sS -i -X POST http://127.0.0.1:8087/records/lookup \
  -H 'Authorization: Bearer tkn-evan' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: `404 Not Found`, `Content-Length: 48`, body `{"error":"not_found","message":"No such record."}`. The audit log gets a new entry with `outcome = "denied"`, `authorisation_basis = "not_care_team_member"`.

### 3. Dr Evan tries to look up a nonexistent patient (byte-equivalent 404, FR-007)

```bash
curl -sS -i -X POST http://127.0.0.1:8087/records/lookup \
  -H 'Authorization: Bearer tkn-evan' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "fabricated-pat-999" }'
```

Expected: byte-identical response to step 2 (same status, same body, same `Content-Length`). The audit log gets a new entry with `outcome = "not_found_or_denied"`, `authorisation_basis = "patient_not_found"`. **The clinician cannot tell from the response whether pat-001 exists or not** — that's the FR-007 invariant.

### 4. URL-path-PII probe (FR-004, SC-005)

Attempt a `GET` with the patient_id in the URL path:

```bash
curl -sS -i http://127.0.0.1:8087/records/pat-001 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: `404 Not Found` byte-equivalent (the route doesn't exist; FR-004 forbids it). The `server.py` routing table has no path containing `{patient_id}` or `{id}`; the only ways to look up a record are POST `/records/lookup` and POST `/audit/search` with the identifier in the body.

### 5. Clinical-safety field order probe (FR-014, FR-015, SC-008)

Using the JSON from step 1:

```bash
curl -sS -X POST http://127.0.0.1:8087/records/lookup \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }' | python -c 'import sys, json; print(list(json.load(sys.stdin).keys())[:5])'
```

Expected: `['patient_id', 'date_of_birth', 'name', 'allergies', 'key_warnings']`. The first five keys are always exactly these, in this order, regardless of the patient's data (FR-014, FR-015).

### 6. IG Officer Diana audits pat-001's access history (US2, FR-011)

```bash
curl -sS -X POST http://127.0.0.1:8087/audit/search \
  -H 'Authorization: Bearer tkn-diana' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: `200 OK`. `events` array contains three entries by now: Alice's permitted access (step 1), Evan's denied access (step 2). Each entry has `clinician_id`, `clinician_display_name` (snapshot), `clinician_role` (snapshot), `occurred_at`, `access_type: "read"`, `outcome`, `authorisation_basis`.

### 7. A clinician tries the IG endpoint (FR-011, SC-011 — endpoint hidden from non-IG)

```bash
curl -sS -i -X POST http://127.0.0.1:8087/audit/search \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: byte-equivalent `404 not_found`. Alice cannot tell from this response that `/audit/search` exists (the system returns the same byte-equivalent 404 it would for any non-existent path).

### 8. Dr Alice loses care-team membership and re-tries (FR-006 evaluated on every request)

(Simulate by directly removing the membership row via SQLite while the server is running.)

```bash
sqlite3 ./clinician_record_access.db "UPDATE care_team_memberships SET status='ended', end_date='2026-05-17T12:00:00.000Z' WHERE clinician_id='alice-uuid' AND patient_id='pat-001';"

curl -sS -i -X POST http://127.0.0.1:8087/records/lookup \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: byte-equivalent `404 not_found` on the very next request. Membership-revocation takes effect immediately because the predicate runs on every request (no caching). The audit log captures Alice's now-denied access.

### 9. Audit-write SLA breach (FR-013, SC-007)

(In `test_audit_sla.py`: hold the SQLite write lock for 2.5 s in another thread; fire a `POST /records/lookup`.) Expected: `503 service_unavailable`. No audit entry written. No record content returned.

### 10. Audit immutability probe (FR-010, SC-006)

There is no API path that mutates an audit entry. Attempt:

```bash
sqlite3 ./clinician_record_access.db "UPDATE audit_entries SET outcome='permitted' WHERE outcome='denied' LIMIT 1;"
```

This is an *out-of-band* tampering attempt (not through the API). v1 does **not** defend against out-of-band tampering — the FR-010 immutability invariant is enforced by code-path absence (no API path mutates), and the runtime probe `test_invariants.py` will catch the tampered row by hashing snapshots — but it will not prevent a hostile DBA. (Tamper detection / chained-hash, as in feature 005, is out of scope for 009.)

## Smoke test — auth boundary and 400 paths

| What to do                                                                       | Expected response                  | Why it matters         |
|----------------------------------------------------------------------------------|------------------------------------|------------------------|
| Any request with `Authorization: Bearer not-a-real-token`                        | `401 unauthenticated`              | FR-001, SC-004.        |
| Any request with no `Authorization` header                                       | `401 unauthenticated`              | FR-001.                |
| `POST /records/lookup` with body `{}` (missing patient_id)                       | `400 validation_error`             | Body validation.       |
| `POST /audit/search` with body `{}` as `audit_officer`                           | `400 validation_error`             | Body validation.       |
| `GET /records/pat-001` (PII in URL path)                                         | `404 not_found` byte-equivalent    | FR-004; no such route. |

## Run the tests

```bash
pytest tests/clinician_record_access -q
```

Test groupings:

| File                                                       | What it covers                                                                                                                |
|------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `tests/clinician_record_access/test_auth.py`               | Bearer-token resolution; 401 paths; ensures no business logic runs on a 401 and no audit entry is written.                    |
| `tests/clinician_record_access/test_permissions.py`        | Care-team-membership matrix: every (clinical role × care-team relation × patient existence) combination.                       |
| `tests/clinician_record_access/test_validation.py`         | Per-field validation; `400 validation_error` shape; absence of write-field validation (Q2 = A means no write fields exist).    |
| `tests/clinician_record_access/test_byte_equivalence.py`   | Constructs (own-patient, other-team-patient, nonexistent-patient, IG-endpoint-by-clinician, missing-audit) tuples; asserts identical `(status, content_type, content_length, body)` across every cross-access endpoint. |
| `tests/clinician_record_access/test_audit.py`              | Always-on audit (`permitted` / `denied` / `not_found_or_denied` all produce one entry); snapshot semantics on display_name and role; immutability (static + runtime probes). |
| `tests/clinician_record_access/test_audit_sla.py`          | Holds SQLite write lock for 2.5 s; fires lookup; asserts `503 service_unavailable` + zero audit entries + no content returned. |
| `tests/clinician_record_access/test_no_url_pii.py`         | Static probe: grep `server.py` routing for any path containing `{patient_id}` or `{id}` — fail if found.                      |
| `tests/clinician_record_access/test_clinical_safety.py`    | The response key order test: walks `response.keys()` and asserts the first five keys are exactly `["patient_id","date_of_birth","name","allergies","key_warnings"]` for every successful lookup, across seeded patients with and without allergies/warnings. |
| `tests/clinician_record_access/test_service.py`            | Business logic — lookup_patient, list_audit — against in-memory DB.                                                            |
| `tests/clinician_record_access/test_store.py`              | Schema, CHECK constraints, indexes, append-only on `audit_entries` (static SQL probe).                                         |
| `tests/clinician_record_access/test_handlers.py`           | HTTP-level: status codes, response shapes, error envelopes, `Content-Length` consistency.                                      |
| `tests/clinician_record_access/test_invariants.py`         | SC-001…SC-011 catch-all probes: random-pair byte-equivalence sampling, audit-immutability runtime scan.                        |

## Style and lint

```bash
ruff check src/clinician_record_access tests/clinician_record_access
```

Type hints on all public functions; `str | None` syntax (Constitution III).

## When you're done

Stop the server with `Ctrl+C`. The `./clinician_record_access.db` file persists (with WAL sidecars `.db-wal`, `.db-shm`).

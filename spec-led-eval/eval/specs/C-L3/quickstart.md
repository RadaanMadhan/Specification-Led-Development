# Quickstart: HIPAA Hospital Clinical Record Access

**Branch**: `013-hipaa-clinical-records` | **Date**: 2026-05-17

> **Trial-context note**: this is a development PoC. The seed data below is fictional. Do not use this PoC against real patient data without the governance review described in `spec.md`.

## Prerequisites

- Python 3.11 or later
- macOS or Linux
- No third-party packages are required at runtime.

## Install (development)

```bash
pip install -e .[dev]
```

## Run the server

```bash
python -m hipaa_clinical_records.server --seed --port 8091 --db-path ./hipaa_clinical_records.db
```

Flags:

| Flag        | Default                          | Meaning                                                                                                                                                  |
|-------------|----------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--port`    | `8091`                           | TCP port to bind on `127.0.0.1`.                                                                                                                          |
| `--db-path` | `./hipaa_clinical_records.db`    | SQLite file (`:memory:` for ephemeral). WAL mode enabled at startup. Connection `timeout=0.15s` to satisfy both the 200ms 403 SLA and the 1s audit SLA.   |
| `--seed`    | off                              | Seed: a clinician on the care team, a clinician outside it, a patient on the seed record, a patient on another record, a compliance officer, two records, one seeded note. |
| `--json`    | off                              | With `--seed`, emit the fixture as JSON.                                                                                                                  |
| `--help`    | —                                | Usage.                                                                                                                                                    |

## Seeded fixture

**Users**:

| Username   | Token            | Display name             | Role                  | `assigned_record_id` |
|------------|------------------|--------------------------|-----------------------|----------------------|
| `alice`    | `tkn-alice`      | Dr Alice Carter          | `clinician`           | —                    |
| `bob`      | `tkn-bob`        | Dr Bob Outsider          | `clinician`           | —                    |
| `patty`    | `tkn-patty`      | Patient Patty Lee        | `patient`             | `rec-001`            |
| `quincy`   | `tkn-quincy`     | Patient Quincy Ng        | `patient`             | `rec-002`            |
| `carla`    | `tkn-carla`      | Compliance Carla Yu      | `compliance_officer`  | —                    |

`bob` has no care-team memberships → used for the 200ms 403 latency probe.

**Records**:

| Record id | `patient_name` | `date_of_birth` |
|-----------|----------------|-----------------|
| `rec-001` | Patty Lee      | 1972-04-19      |
| `rec-002` | Quincy Ng      | 1985-11-02      |

**Care-team memberships**:

| Clinician | Record    | Episode    |
|-----------|-----------|------------|
| `alice`   | `rec-001` | `ep-a-001` |

So Alice is on `rec-001`'s care team only. Bob is on no team. Patty owns `rec-001`. Quincy owns `rec-002`. Carla audits.

**Seeded note**:

| Note id    | Record    | Author  | Type        |
|------------|-----------|---------|-------------|
| `note-001` | `rec-001` | `alice` | `progress`  |

## Smoke test — happy paths

Server on `:8091`.

### 1. Alice reads rec-001 (US1)

```bash
curl -sS -X GET http://127.0.0.1:8091/records/rec-001 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: `200 OK`. Body in fixed key order (`record_id`, `date_of_birth`, `patient_name`, `allergies`, `key_warnings`, `current_medications`, `recent_encounters`, `notes_count`, `notes`). Audit log gains an entry: `operation=read`, `outcome=permitted`, `accessor_role=clinician`, `originating_ip_address=127.0.0.1`, `record_id=rec-001`.

### 2. Alice appends a clinical note (US2)

```bash
curl -sS -X POST http://127.0.0.1:8091/records/rec-001/notes \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "body": "Reviewed today; pain improving.", "note_type": "progress" }'
```

Expected: `201 Created`, new note's `id` returned. Audit entry: `operation=append`, `outcome=permitted`, `note_id=<new>`, `originating_ip_address=127.0.0.1`.

### 3. Patty reads her own record rec-001 (US3)

```bash
curl -sS -X GET http://127.0.0.1:8091/records/rec-001 \
  -H 'Authorization: Bearer tkn-patty'
```

Expected: `200 OK`. Patty sees her own record (including Alice's notes). Audit entry: `accessor_role=patient`, `outcome=permitted`, `authorisation_basis=patient_own`.

### 4. Patty reads her own audit log (US3)

```bash
curl -sS -X GET http://127.0.0.1:8091/records/rec-001/audit \
  -H 'Authorization: Bearer tkn-patty'
```

Expected: `200 OK`, chronological events. Each event has `record_id`, `accessor_user_id`, `accessor_user_display_name`, `accessor_role`, `timestamp`, `operation`, `outcome`, `originating_ip_address`, `note_id`.

### 5. Carla (compliance) reads the system-wide access log (US4)

```bash
curl -sS http://127.0.0.1:8091/access-log \
  -H 'Authorization: Bearer tkn-carla'
```

Expected: `200 OK`, every audit entry system-wide so far. Most-recent first. No clinical content.

### 6. Filtered access-log read

```bash
curl -sS "http://127.0.0.1:8091/access-log?record_id=rec-001&limit=10" \
  -H 'Authorization: Bearer tkn-carla'
```

Expected: `200 OK`, only events for `rec-001`, at most 10 most-recent.

## Smoke test — refused paths (byte-equivalent 403)

### 7. Dr Bob (outsider) gets the byte-equivalent 403 within 200ms (US1, FR-009)

```bash
time curl -sS -i -X GET http://127.0.0.1:8091/records/rec-001 \
  -H 'Authorization: Bearer tkn-bob'
```

Expected: `403 Forbidden`, body `{"error":"forbidden","message":"Access denied."}`, `Content-Length: 47`. Wall-clock latency well under 200ms on a dev machine. Audit entry: `outcome=denied`, `authorisation_basis=not_care_team_member`.

### 8. Bob asks for a fabricated id (US5)

```bash
curl -sS -i -X GET http://127.0.0.1:8091/records/rec-fabricated-9999 \
  -H 'Authorization: Bearer tkn-bob'
```

Expected: byte-identical to step 7 — same status, body, `Content-Length`. Audit entry with `authorisation_basis=record_not_found`. **Bob cannot tell whether rec-001 exists.**

### 9. Patty tries to read rec-002 (not her record)

```bash
curl -sS -i -X GET http://127.0.0.1:8091/records/rec-002 \
  -H 'Authorization: Bearer tkn-patty'
```

Expected: byte-equivalent `403 forbidden`. Audit entry: `accessor_role=patient`, `outcome=denied`, `authorisation_basis=patient_other`.

### 10. Patty tries to append a note (US3, FR-006)

```bash
curl -sS -i -X POST http://127.0.0.1:8091/records/rec-001/notes \
  -H 'Authorization: Bearer tkn-patty' \
  -H 'Content-Type: application/json' \
  -d '{ "body": "Patient self-edit", "note_type": "progress" }'
```

Expected: byte-equivalent `403 forbidden`. No note created. Audit entry: `operation=append`, `outcome=denied`, `accessor_role=patient`.

### 11. Carla tries to read clinical content (US4, FR-007)

```bash
curl -sS -i -X GET http://127.0.0.1:8091/records/rec-001 \
  -H 'Authorization: Bearer tkn-carla'
```

Expected: byte-equivalent `403 forbidden`. Compliance officers cannot read clinical content. Audit entry: `outcome=denied`, `authorisation_basis=compliance_role`.

### 12. Alice tries `GET /access-log` (clinician on the compliance endpoint)

```bash
curl -sS -i http://127.0.0.1:8091/access-log \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: byte-equivalent `403 forbidden`. The endpoint's existence is not revealed to non-compliance callers.

## Smoke test — invariants

### 13. Compliance content-blindness probe (FR-019, SC-006)

```bash
curl -sS http://127.0.0.1:8091/access-log \
  -H 'Authorization: Bearer tkn-carla' | python -c '
import sys, json
FORBIDDEN = {"body","note_body","content","note_content","allergies","key_warnings",
             "current_medications","recent_encounters","encounters","summary",
             "patient_name","name","date_of_birth","dob"}
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            assert k not in FORBIDDEN, f"forbidden key found: {k}"
            walk(v)
    elif isinstance(o, list):
        for x in o: walk(x)
walk(json.load(sys.stdin))
print("content-blindness OK")
'
```

Expected: `content-blindness OK`. No clinical-content key appears at any depth.

### 14. Note append-only (FR-012)

```bash
curl -sS -i -X PATCH http://127.0.0.1:8091/records/rec-001/notes/note-001 \
  -H 'Authorization: Bearer tkn-alice'

curl -sS -i -X DELETE http://127.0.0.1:8091/records/rec-001/notes/note-001 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: both return `405 method_not_allowed` or byte-equivalent `403` — no such routes exist.

### 15. Care-team revocation takes effect immediately (FR-004)

```bash
sqlite3 ./hipaa_clinical_records.db "UPDATE care_team_memberships SET status='ended', end_date='2026-05-17T12:00:00.000Z' WHERE clinician_id='alice' AND record_id='rec-001';"

curl -sS -i -X GET http://127.0.0.1:8091/records/rec-001 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: byte-equivalent `403 forbidden` on the next request. Audit entry: `outcome=denied`, `authorisation_basis=not_care_team_member`.

### 16. Audit-write SLA breach (FR-016, SC-005)

Hold the SQLite write lock for 300ms in a separate process; fire a request. Expected: `503 service_unavailable`. No state change, no audit entry. (Implemented in `test_audit_sla.py`.)

### 17. 200ms 403 latency probe (FR-009, SC-004)

Conceptually (run by `test_perf_403_latency.py`):

```bash
for i in $(seq 1 1000); do
  ( /usr/bin/time -f '%e' curl -sS -o /dev/null -X GET http://127.0.0.1:8091/records/rec-001 \
    -H 'Authorization: Bearer tkn-bob' ) 2>&1 | tail -1
done | sort -n | awk 'NR == 990 { print "p99 = " $1 "s" }'
```

Expected: p99 latency well under 200ms (typically 30–80ms on a dev machine).

### 18. URL-path-PII probe (FR-020)

The static probe in `test_no_url_pii.py` greps `server.py` routing for any path placeholder named `{patient_id}`, `{patient_name}`, `{nhs_number}`, `{mrn}`, `{ssn}`, etc., and fails if any is found. The only path placeholder allowed is `{id}` (which refers to `record_id`, an opaque internal handle).

## Auth boundary

| Request                                                                     | Expected response                  |
|-----------------------------------------------------------------------------|------------------------------------|
| Any request with `Authorization: Bearer not-a-real-token`                   | `401 unauthenticated`              |
| Any request with no `Authorization` header                                  | `401 unauthenticated`              |
| `Authorization: Bearer <expired-token>`                                     | `401 unauthenticated`              |
| `POST /records/rec-001/notes` with body `{}`                                | `400 validation_error`             |
| `POST /records/rec-001/notes` with body `note_type: "smoke_signal"`         | `400 validation_error` on `note_type` |
| `POST /records/rec-001/notes` with body `encounter_date: "2099-01-01"`      | `400 validation_error` on `encounter_date` |
| `GET /access-log?limit=99999`                                               | `400 validation_error` on `limit`  |

## Run the tests

```bash
pytest tests/hipaa_clinical_records -q
```

| File                                                              | What it covers                                                                                                                |
|-------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `tests/hipaa_clinical_records/test_auth.py`                       | Bearer-token resolution; 401 paths; no audit on 401.                                                                          |
| `tests/hipaa_clinical_records/test_permissions.py`                | Full (relationship × action) matrix across all five caller archetypes (outsider, care-team clinician, patient-own-record, patient-other-record, compliance-officer) and all four endpoints. |
| `tests/hipaa_clinical_records/test_validation.py`                 | Per-field validation; per-field error envelope; future-date rejection on encounter_date; `note_type` enum; `limit`/`from`/`to` validation. |
| `tests/hipaa_clinical_records/test_byte_equivalence.py`           | Constructs (real-unauthorised, fabricated-id) pairs for every caller archetype; asserts identical `(status, content_type, content_length, body)` across every refused code path. |
| `tests/hipaa_clinical_records/test_audit.py`                      | Always-on audit; snapshot semantics; `originating_ip_address` captured; immutability (static SQL probe + runtime snapshot-hash probe); CHECK pairings on `(operation, outcome, note_id)` and `(operation, record_id)`. |
| `tests/hipaa_clinical_records/test_audit_sla.py`                  | Holds SQLite write lock for 300ms; asserts `503` within budget; no state change; no audit entry persisted.                    |
| `tests/hipaa_clinical_records/test_perf_403_latency.py`           | The 200ms p99 probe (FR-009, SC-004). Fires 1000 non-care-team-clinician GETs; asserts p99 ≤ 200ms. Skipped on CI where wall-clock measurement is unreliable. |
| `tests/hipaa_clinical_records/test_no_url_pii.py`                 | Static probe: greps `server.py` routing for any path placeholder that would be a patient demographic; asserts the only path placeholder is `{id}` (= record_id). |
| `tests/hipaa_clinical_records/test_clinical_safety.py`            | Walks `GET /records/{id}` response keys; asserts the first five are `["record_id","date_of_birth","patient_name","allergies","key_warnings"]`. |
| `tests/hipaa_clinical_records/test_compliance_content_blindness.py` | Walks every compliance response (`/access-log` and per-record audit for compliance caller) across seeded scenarios; recursively asserts no forbidden clinical-content key appears at any depth. |
| `tests/hipaa_clinical_records/test_notes.py`                      | Append-only enforcement: PATCH/DELETE return 405 or byte-equivalent 403; non-clinician authorship rejected (schema CHECK).      |
| `tests/hipaa_clinical_records/test_patient_self_access.py`        | Patient reads own record + own audit; refused on others; refused on writes; refused on `/access-log`.                          |
| `tests/hipaa_clinical_records/test_access_log_endpoint.py`        | System-wide audit retrieval; all four filters; content-blindness; non-compliance callers refused.                              |
| `tests/hipaa_clinical_records/test_service.py`                    | Business logic against in-memory DB.                                                                                          |
| `tests/hipaa_clinical_records/test_store.py`                      | Schema; all CHECK constraints (incl. `users.role ↔ assigned_record_id` pairing, `clinical_notes.author_role = 'clinician'`, audit `(operation, outcome, note_id)` pairing); append-only static SQL probe. |
| `tests/hipaa_clinical_records/test_handlers.py`                   | HTTP-level: status codes, response shapes, error envelopes, `Content-Length=47` consistency on the 403 envelope, IP captured correctly under various trusted-proxy configurations. |
| `tests/hipaa_clinical_records/test_invariants.py`                 | SC-001…SC-011 catch-all probes; static grep of `compliance_response.py` for forbidden clinical-table accesses; audit-immutability runtime scan. |

## Style and lint

```bash
ruff check src/hipaa_clinical_records tests/hipaa_clinical_records
```

Type hints on all public functions; modern type-hint syntax.

## When you're done

Stop with `Ctrl+C`. The `./hipaa_clinical_records.db` file persists (with WAL sidecars `.db-wal`, `.db-shm`).

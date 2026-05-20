# Quickstart: Hospital Clinical Record Access

**Branch**: `012-hospital-clinical-records` | **Date**: 2026-05-17

> **Trial-context note**: this is a development PoC. Seed data below is fictional. Do not use this PoC against real patient data without the governance review described in `spec.md`.

## Prerequisites

- Python 3.11 or later
- macOS or Linux
- No third-party packages are required at runtime.

## Install (development)

From the repository root:

```bash
pip install -e .[dev]
```

`[dev]` pulls in only `pytest` and `ruff` for testing and linting; the runtime is stdlib-only.

## Run the server

```bash
python -m hospital_clinical_records.server --seed --port 8090 --db-path ./hospital_clinical_records.db
```

Flags:

| Flag        | Default                                | Meaning                                                                                                                                       |
|-------------|----------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| `--port`    | `8090`                                 | TCP port to bind on `127.0.0.1`.                                                                                                              |
| `--db-path` | `./hospital_clinical_records.db`       | SQLite file. Use `:memory:` for an ephemeral run. WAL mode is enabled at startup.                                                              |
| `--seed`    | off                                    | Seed users (one of each clinical role + a hospital_administrator), patients, patient summaries, encounters, care-team memberships, bearer tokens. |
| `--json`    | off                                    | With `--seed`, emit the fixture as JSON on stdout instead of the human-readable table.                                                         |
| `--help`    | —                                      | Usage.                                                                                                                                         |

Errors print to stderr. The SQLite connection is opened with `timeout=1.8` seconds for the FR-015 audit-write budget; contended commits raise `OperationalError` and the handler maps to `503 service_unavailable`.

## Seeded fixture

`--seed` produces a deterministic fixture:

**Users**:

| Username   | Token            | Display name           | Role                       |
|------------|------------------|------------------------|----------------------------|
| `alice`    | `tkn-alice`      | Dr Alice Carter        | `doctor`                   |
| `barbara`  | `tkn-barbara`    | Nurse Barbara Lee      | `nurse`                    |
| `colin`    | `tkn-colin`      | Pharmacist Colin Hu    | `pharmacist`               |
| `dora`     | `tkn-dora`       | Admin Dora Marsh       | `hospital_administrator`   |
| `evan`     | `tkn-evan`       | Dr Evan Outsider       | `doctor`                   |
| `frank`    | `tkn-frank`      | Clinical Admin Frank   | `clinical_admin`           |

`evan` has no care-team memberships and is used in the cross-care-team isolation probes.

**Patients** (fictional):

| Patient id | Name            | Date of birth |
|------------|-----------------|---------------|
| `pat-001`  | Patient One     | 1972-04-19    |
| `pat-002`  | Patient Two     | 1985-11-02    |

**Care-team memberships** (active):

| Clinician | Patient   | Episode      |
|-----------|-----------|--------------|
| `alice`   | `pat-001` | `ep-a-001`   |
| `alice`   | `pat-002` | `ep-a-002`   |
| `barbara` | `pat-001` | `ep-b-001`   |
| `colin`   | `pat-002` | `ep-c-002`   |
| `frank`   | `pat-001` | `ep-f-001`   |

**Seeded note**: one note already exists against `pat-001`, authored by `alice`:

| Note id    | Patient   | Author    | Type        | Body (truncated)                              |
|------------|-----------|-----------|-------------|-----------------------------------------------|
| `note-001` | `pat-001` | `alice`   | `progress`  | "Routine review; stable; continuing meds."    |

## Smoke test — happy paths

Server is running on `:8090`.

### 1. Dr Alice reads `pat-001`

```bash
curl -sS -X POST http://127.0.0.1:8090/records/lookup \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: `200 OK`. Response body has keys in exactly the order:
`patient_id`, `date_of_birth`, `name`, `allergies`, `key_warnings`, `current_medications`, `recent_encounters`, `notes_count`, `notes`. The audit log gains one entry: `access_type: read`, `outcome: permitted`, `authorisation_basis: care_team_member`.

### 2. Dr Alice adds a clinical note

```bash
curl -sS -X POST http://127.0.0.1:8090/records/notes \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{
    "patient_id": "pat-001",
    "body": "Reviewed today; pain improving; continuing physiotherapy plan.",
    "note_type": "progress",
    "encounter_date": "2026-05-17"
  }'
```

Expected: `201 Created`. Response body has the new note's `id`, `author_user_id`, `author_display_name: "Dr Alice Carter"`, `author_role: "doctor"`, `created_at`, `note_type`, `encounter_date`, `body`. Audit log gains an entry with `access_type: add_note`, `note_id: <new>`, `outcome: permitted`.

### 3. The new note is visible to other care-team members

```bash
curl -sS -X POST http://127.0.0.1:8090/records/lookup \
  -H 'Authorization: Bearer tkn-barbara' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }' | python -c 'import sys, json; r=json.load(sys.stdin); print(r["notes_count"], len(r["notes"]))'
```

Expected: `2 2` (the seeded `note-001` + the just-added note). Nurse Barbara is on `pat-001`'s care team and sees Alice's note.

### 4. Hospital administrator Dora views the access log for `pat-001`

```bash
curl -sS -X POST http://127.0.0.1:8090/audit/search \
  -H 'Authorization: Bearer tkn-dora' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: `200 OK`. `events` array containing the entries from steps 1, 2, 3, plus the current request (audit-of-the-administrator's-list-call). Each event has only the fields: `user_id`, `user_display_name`, `user_role`, `occurred_at`, `access_type`, `note_id`, `outcome`, `authorisation_basis`. No clinical-content field appears.

## Smoke test — refused paths (byte-equivalent 404)

### 5. Dr Evan (no care-team membership) tries to read `pat-001`

```bash
curl -sS -i -X POST http://127.0.0.1:8090/records/lookup \
  -H 'Authorization: Bearer tkn-evan' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: `404 Not Found` with body `{"error":"not_found","message":"No such record."}` and `Content-Length: 48`. Audit log gains an entry with `outcome: denied`, `authorisation_basis: not_care_team_member`. No clinical content returned.

### 6. Dr Evan tries to read a fabricated patient identifier

```bash
curl -sS -i -X POST http://127.0.0.1:8090/records/lookup \
  -H 'Authorization: Bearer tkn-evan' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "fabricated-pat-9999" }'
```

Expected: response byte-identical to step 5 (same status, body, Content-Length). Audit log gains an entry with `outcome: not_found_or_denied`, `authorisation_basis: patient_not_found`. **Evan cannot tell from the response whether `pat-001` exists or not** — the FR-006 invariant.

### 7. Dr Evan tries to add a note to `pat-001`

```bash
curl -sS -i -X POST http://127.0.0.1:8090/records/notes \
  -H 'Authorization: Bearer tkn-evan' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001", "body": "Override note", "note_type": "progress" }'
```

Expected: byte-equivalent `404 not_found`. Audit log gains an entry with `access_type: add_note`, `outcome: denied`. **No note is created.**

### 8. Administrator Dora tries to read `pat-001`'s record (not the audit log)

```bash
curl -sS -i -X POST http://127.0.0.1:8090/records/lookup \
  -H 'Authorization: Bearer tkn-dora' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: byte-equivalent `404 not_found`. Dora is not on any care team (she's an administrator). She cannot access clinical content through the record-read endpoint. Audit log gains an entry with `outcome: denied`, `authorisation_basis: not_care_team_member`.

### 9. Administrator Dora tries to add a note

```bash
curl -sS -i -X POST http://127.0.0.1:8090/records/notes \
  -H 'Authorization: Bearer tkn-dora' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001", "body": "Admin note", "note_type": "progress" }'
```

Expected: byte-equivalent `404 not_found`. Administrators cannot add notes. Even if the auth-layer check were somehow bypassed, the `clinical_notes.author_role` schema CHECK would reject `hospital_administrator` at the database layer.

### 10. Clinician tries the administrator endpoint

```bash
curl -sS -i -X POST http://127.0.0.1:8090/audit/search \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: byte-equivalent `404 not_found`. The endpoint's existence is not signalled to non-administrators (FR-017).

## Smoke test — invariants

### 11. URL-path-PII probe (FR-003)

```bash
curl -sS -i http://127.0.0.1:8090/records/pat-001 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: byte-equivalent `404 not_found` (no such route — patient identifiers are never in URL paths).

### 12. Field-order probe (FR-019)

```bash
curl -sS -X POST http://127.0.0.1:8090/records/lookup \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }' | python -c 'import sys, json; print(list(json.load(sys.stdin).keys())[:5])'
```

Expected: `['patient_id', 'date_of_birth', 'name', 'allergies', 'key_warnings']`. The first five keys are always exactly these, in this order, regardless of the patient's data.

### 13. Administrator content-blindness probe (FR-018)

```bash
curl -sS -X POST http://127.0.0.1:8090/audit/search \
  -H 'Authorization: Bearer tkn-dora' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }' | python -c '
import sys, json
FORBIDDEN = {"body","note_body","content","note_content","allergies","key_warnings",
             "current_medications","recent_encounters","encounters","summary",
             "name","patient_name","date_of_birth","dob"}
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

Expected: prints `content-blindness OK`. No clinical-content key appears at any depth.

### 14. Notes append-only (FR-011)

```bash
curl -sS -i -X PATCH http://127.0.0.1:8090/records/notes/note-001 \
  -H 'Authorization: Bearer tkn-alice'

curl -sS -i -X DELETE http://127.0.0.1:8090/records/notes/note-001 \
  -H 'Authorization: Bearer tkn-alice'
```

Expected: both return `405 Method Not Allowed` or the byte-equivalent `404 not_found` (no such routes exist). `note-001` is unchanged.

### 15. Care-team revocation takes effect immediately (FR-004 evaluated on every request)

```bash
sqlite3 ./hospital_clinical_records.db \
  "UPDATE care_team_memberships SET status='ended', end_date='2026-05-17T12:00:00.000Z' \
   WHERE clinician_id='alice' AND patient_id='pat-001';"

curl -sS -i -X POST http://127.0.0.1:8090/records/lookup \
  -H 'Authorization: Bearer tkn-alice' \
  -H 'Content-Type: application/json' \
  -d '{ "patient_id": "pat-001" }'
```

Expected: byte-equivalent `404 not_found` on the next request. Membership-revocation takes immediate effect; the predicate runs on every request. Audit log gains a `denied` entry.

### 16. Audit-write SLA breach (FR-015, SC-009)

In a separate process, hold the SQLite write lock for 2.5 seconds; fire any clinical-endpoint request. Expected: `503 service_unavailable`. No state change, no audit entry written for the failed attempt.

Tested in `test_audit_sla.py`.

### 17. Auth boundary

| What to do                                                                  | Expected response                                  |
|-----------------------------------------------------------------------------|----------------------------------------------------|
| `Authorization: Bearer not-a-real-token`                                    | `401 unauthenticated`                              |
| No `Authorization` header                                                   | `401 unauthenticated`                              |
| `Authorization: Bearer <expired-token>`                                     | `401 unauthenticated`                              |
| `POST /records/lookup` with body `{}` (missing `patient_id`)                | `400 validation_error`                             |
| `POST /records/notes` with body containing `note_type: "smoke_signal"`      | `400 validation_error` listing `note_type`         |
| `POST /records/notes` with body `encounter_date: "2099-01-01"` (future)     | `400 validation_error` listing `encounter_date`    |

## Run the tests

```bash
pytest tests/hospital_clinical_records -q
```

Test groupings:

| File                                                              | What it covers                                                                                                                |
|-------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `tests/hospital_clinical_records/test_auth.py`                    | Bearer-token resolution; 401 paths; no audit on 401.                                                                          |
| `tests/hospital_clinical_records/test_permissions.py`             | (role × care-team relationship × patient existence) matrix for read and add_note; administrator probe for `/audit/search`.    |
| `tests/hospital_clinical_records/test_validation.py`              | Per-field validation; per-field error envelope; whitespace-trimming on `body`; future-date rejection; note-type enum.          |
| `tests/hospital_clinical_records/test_byte_equivalence.py`        | Constructs (own-care-team, other-care-team, fabricated-id, admin-on-clinical, clinician-on-admin) tuples; asserts identical `(status, content_type, content_length, body)`. |
| `tests/hospital_clinical_records/test_audit.py`                   | Always-on audit (read, add_note, list_audit); snapshot semantics on user_display_name/user_role; immutability (static + runtime probes); the `note_id ↔ access_type` CHECK pairing. |
| `tests/hospital_clinical_records/test_audit_sla.py`               | Holds SQLite write lock for 2.5s; asserts `503 service_unavailable` + zero audit entries + no clinical content/note returned. |
| `tests/hospital_clinical_records/test_no_url_pii.py`              | Static probe: grep `server.py` routing for any `{patient_id}`/`{id}`/`{patient}` path placeholders; fail if any found.        |
| `tests/hospital_clinical_records/test_clinical_safety.py`         | Walks `list(response.keys())` of a successful read response; asserts the first five keys are `["patient_id","date_of_birth","name","allergies","key_warnings"]` and `notes_count` precedes `notes`. |
| `tests/hospital_clinical_records/test_admin_content_blindness.py` | Walks every administrator response across seeded scenarios; recursively asserts no forbidden clinical-content key appears at any depth. |
| `tests/hospital_clinical_records/test_notes.py`                   | Note creation; admin-cannot-author (schema CHECK); append-only (PATCH/DELETE return 405 or byte-equivalent 404); concurrent additions both succeed; encounter-date defaults to today; future-date rejection. |
| `tests/hospital_clinical_records/test_service.py`                 | Business logic against in-memory DB.                                                                                          |
| `tests/hospital_clinical_records/test_store.py`                   | Schema; all CHECK constraints (incl. `clinical_notes.author_role`, audit `(access_type, note_id, outcome)` pairing); append-only static SQL probe. |
| `tests/hospital_clinical_records/test_handlers.py`                | HTTP-level: status codes, response shapes, error envelopes, `Content-Length=48` consistency on the unauthorised envelope.     |
| `tests/hospital_clinical_records/test_invariants.py`              | SC-001…SC-009 catch-all probes; static grep of `admin_response.py` for forbidden clinical-table accesses; audit-immutability runtime scan. |

## Style and lint

```bash
ruff check src/hospital_clinical_records tests/hospital_clinical_records
```

Type hints on all public functions; modern type-hint syntax (`str | None`).

## When you're done

Stop the server with `Ctrl+C`. The `./hospital_clinical_records.db` file persists with WAL sidecars (`.db-wal`, `.db-shm`). Delete all three before re-seeding from scratch.

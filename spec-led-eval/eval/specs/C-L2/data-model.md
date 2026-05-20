# Data Model: Hospital Clinical Record Access

**Branch**: `012-hospital-clinical-records` | **Date**: 2026-05-17

All entities are persisted in SQLite (`sqlite3` stdlib) in WAL mode. All identifiers are UUID4 strings unless otherwise noted (patient identifiers are opaque strings supplied by the host product — typically an NHS number, MRN, or equivalent — and the feature treats them as strings without format validation). All timestamps are UTC ISO 8601 with millisecond precision and `Z` suffix. Dates are date-only `YYYY-MM-DD`.

## Enums

### UserRole

```python
class UserRole(StrEnum):
    DOCTOR = "doctor"
    NURSE = "nurse"
    PHARMACIST = "pharmacist"
    CLINICAL_ADMIN = "clinical_admin"
    HOSPITAL_ADMINISTRATOR = "hospital_administrator"
```

The first four are *clinical* roles — they can read patient records and add clinical notes, subject to care-team membership. `hospital_administrator` is the audit-only role; it can read access logs system-wide but receives no clinical content.

### NoteType

```python
class NoteType(StrEnum):
    PROGRESS = "progress"
    ASSESSMENT = "assessment"
    PLAN = "plan"
    OBSERVATION = "observation"
    DISCHARGE_SUMMARY = "discharge_summary"
```

The fixed v1 catalogue.

### AccessType

```python
class AccessType(StrEnum):
    READ = "read"          # POST /records/lookup
    ADD_NOTE = "add_note"  # POST /records/notes
    LIST_AUDIT = "list_audit"  # POST /audit/search (administrator only)
```

### AccessOutcome

```python
class AccessOutcome(StrEnum):
    PERMITTED = "permitted"
    DENIED = "denied"
    NOT_FOUND_OR_DENIED = "not_found_or_denied"
```

### AuthorisationBasis

```python
class AuthorisationBasis(StrEnum):
    CARE_TEAM_MEMBER = "care_team_member"
    NOT_CARE_TEAM_MEMBER = "not_care_team_member"
    PATIENT_NOT_FOUND = "patient_not_found"
    ADMINISTRATOR_ROLE = "administrator_role"
```

### MembershipStatus

```python
class MembershipStatus(StrEnum):
    ACTIVE = "active"
    ENDED = "ended"
```

## Entities

### User

A signed-in person. May be a clinician (one of the four clinical roles) or a hospital administrator.

| Field         | Type     | Storage                                                                                                                                                | Notes |
|---------------|----------|--------------------------------------------------------------------------------------------------------------------------------------------------------|-------|
| id            | str      | TEXT PK                                                                                                                                                | Opaque user identifier supplied by the host product. |
| display_name  | str      | TEXT NOT NULL                                                                                                                                          | Shown in audit-entry rendering. |
| user_role     | UserRole | TEXT NOT NULL CHECK(user_role IN ('doctor','nurse','pharmacist','clinical_admin','hospital_administrator'))                                            | Exactly one role per user. Read from the host product's identity context on every request; the v1 seed mirrors it here for offline testing convenience. |

No password field; authentication is the bearer-token stub.

### Token (auth stub)

| Field      | Type | Storage                              | Notes |
|------------|------|--------------------------------------|-------|
| token      | str  | TEXT PK                              | Opaque bearer-token presented in `Authorization: Bearer <token>`. |
| user_id    | str  | TEXT NOT NULL FK→users.id            | Resolves the token to a user. |
| expires_at | str  | TEXT NOT NULL                        | UTC ISO 8601. Tokens past `expires_at` resolve to no user. |

In a real deployment this table is replaced by the host product's identity-provider integration; the `auth.py` module documents the swap point.

### Patient

| Field         | Type | Storage                  | Notes |
|---------------|------|--------------------------|-------|
| id            | str  | TEXT PK                  | Opaque patient identifier (NHS number, MRN, or equivalent — treated as an opaque string). |
| name          | str  | TEXT NOT NULL            | The patient's name; appears at the top of the record-read response (FR-007). |
| date_of_birth | str  | TEXT NOT NULL            | `YYYY-MM-DD`. Used at the top of the record-read response for patient verification (FR-019). |

### PatientSummary

A per-patient denormalised snapshot of the safety-relevant fields. Read-only in this feature; modifications are out of scope.

| Field                        | Type | Storage                              | Notes |
|------------------------------|------|--------------------------------------|-------|
| patient_id                   | str  | TEXT PK FK→patients.id               | One row per patient. |
| allergies_json               | str  | TEXT NOT NULL DEFAULT '[]'           | JSON array of `{"substance": str, "severity": str, "notes": str}` objects. Surfaced at the top of every record-read response (FR-019). |
| key_warnings_json            | str  | TEXT NOT NULL DEFAULT '[]'           | JSON array of `{"category": str, "text": str}` objects. Surfaced at the top of every record-read response. |
| current_medications_json     | str  | TEXT NOT NULL DEFAULT '[]'           | JSON array of `{"name": str, "dose": str, "frequency": str}` objects. |

### Encounter

A chronological clinical-encounter brief.

| Field          | Type | Storage                              | Notes |
|----------------|------|--------------------------------------|-------|
| id             | str  | TEXT PK                              | UUID4. |
| patient_id     | str  | TEXT NOT NULL FK→patients.id         | |
| encounter_date | str  | TEXT NOT NULL                        | `YYYY-MM-DD`. |
| encounter_type | str  | TEXT NOT NULL                        | E.g., `"GP visit"`, `"A&E"`, `"outpatient"`. |
| summary        | str  | TEXT NOT NULL                        | Short summary line. Full clinical-encounter narratives are out of scope (FR-008). |

**Index**:
- `CREATE INDEX idx_encounters_by_patient ON encounters(patient_id, encounter_date DESC);` — supports the recent-encounters list (most-recent first) in the patient-record response.

### CareTeamMembership

The authoritative source of clinician-patient care-team relationships, populated by an out-of-scope feed from the host product's care-team-management system.

| Field              | Type             | Storage                                                                                   | Notes |
|--------------------|------------------|-------------------------------------------------------------------------------------------|-------|
| clinician_id       | str              | TEXT NOT NULL FK→users.id                                                                  | |
| patient_id         | str              | TEXT NOT NULL FK→patients.id                                                               | |
| episode_of_care_id | str              | TEXT NOT NULL                                                                              | Host product's episode-of-care identifier; opaque here. |
| status             | MembershipStatus | TEXT NOT NULL CHECK(status IN ('active','ended'))                                          | Only `active` rows authorise access. |
| start_date         | str              | TEXT NOT NULL                                                                              | UTC ISO 8601. |
| end_date           | str \| None      | TEXT NULL                                                                                  | UTC ISO 8601. NULL while active. |

**Composite PK**: `(clinician_id, patient_id, episode_of_care_id)`.

**Index**:
- `CREATE INDEX idx_care_team_by_clinician_patient ON care_team_memberships(clinician_id, patient_id, status);` — supports the FR-004 lookup (the hottest query path).

### ClinicalNote

Append-only clinical note attached to a patient.

| Field                | Type     | Storage                                                                                          | Notes |
|----------------------|----------|--------------------------------------------------------------------------------------------------|-------|
| id                   | str      | TEXT PK                                                                                          | UUID4. Returned on successful create. |
| patient_id           | str      | TEXT NOT NULL FK→patients.id                                                                     | |
| author_user_id       | str      | TEXT NOT NULL FK→users.id                                                                        | The clinician who added the note. |
| author_display_name  | str      | TEXT NOT NULL                                                                                    | Snapshotted from `users.display_name` at the time of add. Renames in the host product do not retroactively change historical notes. |
| author_role          | UserRole | TEXT NOT NULL CHECK(author_role IN ('doctor','nurse','pharmacist','clinical_admin'))             | Snapshot. `hospital_administrator` is **not** a valid author role; FR-005 prevents administrators from adding notes, and this CHECK enforces it structurally. |
| created_at           | str      | TEXT NOT NULL                                                                                    | UTC ISO 8601 with `Z` suffix. |
| note_type            | NoteType | TEXT NOT NULL CHECK(note_type IN ('progress','assessment','plan','observation','discharge_summary')) | |
| body                 | str      | TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 8000)                                              | Free text; trimmed at submission; 1–8000 chars after trimming. |
| encounter_date       | str      | TEXT NOT NULL CHECK(date(encounter_date) <= date(created_at))                                     | Defaults to the date portion of `created_at` if not supplied. Future dates rejected by the CHECK and at validation time. |

**Index**:
- `CREATE INDEX idx_notes_by_patient_chrono ON clinical_notes(patient_id, created_at, id);` — supports the chronological note list (oldest first) in the patient-record response.

**Append-only enforcement** (FR-011):
- No `UPDATE clinical_notes` or `DELETE FROM clinical_notes` SQL exists anywhere in `store.py`. A static probe in `test_invariants.py` greps for these strings and fails if found.
- A runtime probe in `test_invariants.py` snapshot-hashes existing note rows, runs arbitrary endpoint activity, and asserts no row's hash has changed.
- The schema CHECK on `author_role` (excluding `hospital_administrator`) makes administrator authorship structurally impossible even if the service layer were bypassed.

### AuditEntry

Immutable append-only record of one access attempt.

| Field                | Type                | Storage                                                                                            | Notes |
|----------------------|---------------------|----------------------------------------------------------------------------------------------------|-------|
| id                   | int                 | INTEGER PRIMARY KEY AUTOINCREMENT                                                                  | Monotonic. |
| user_id              | str                 | TEXT NOT NULL FK→users.id                                                                          | The accessor. |
| user_display_name    | str                 | TEXT NOT NULL                                                                                       | Snapshot at access time. |
| user_role            | UserRole            | TEXT NOT NULL CHECK(user_role IN ('doctor','nurse','pharmacist','clinical_admin','hospital_administrator')) | Snapshot at access time. |
| patient_id           | str                 | TEXT NOT NULL                                                                                       | The patient identifier as presented in the request. **Not FK-constrained** — audit entries are written even for nonexistent patient identifiers (FR-012). |
| occurred_at          | str                 | TEXT NOT NULL                                                                                       | UTC ISO 8601 with `Z` suffix. |
| access_type          | AccessType          | TEXT NOT NULL CHECK(access_type IN ('read','add_note','list_audit'))                               | |
| note_id              | str \| None         | TEXT NULL                                                                                           | Set only when `access_type = "add_note"` AND `outcome = "permitted"`; opaque identifier of the note that was added. Reveals no clinical content. CHECK constraint enforces the pairing. |
| outcome              | AccessOutcome       | TEXT NOT NULL CHECK(outcome IN ('permitted','denied','not_found_or_denied'))                       | |
| authorisation_basis  | AuthorisationBasis  | TEXT NOT NULL CHECK(authorisation_basis IN ('care_team_member','not_care_team_member','patient_not_found','administrator_role')) | |

**Structural CHECK linking `note_id` to `access_type` and `outcome`**:

```sql
CHECK (
    (access_type = 'add_note' AND outcome = 'permitted' AND note_id IS NOT NULL)
 OR (access_type = 'add_note' AND outcome != 'permitted' AND note_id IS NULL)
 OR (access_type IN ('read','list_audit') AND note_id IS NULL)
)
```

**Indexes**:
- `CREATE INDEX idx_audit_by_patient_chrono ON audit_entries(patient_id, occurred_at, id);` — supports the per-patient audit listing on `POST /audit/search` (administrator endpoint).
- `CREATE INDEX idx_audit_by_user_chrono ON audit_entries(user_id, occurred_at, id);` — supports operational queries by user (not exposed in v1 endpoints but useful for offline analysis).

**Append-only enforcement** (FR-014): same pattern as for `clinical_notes` — no UPDATE/DELETE SQL exists in `store.py`; static + runtime probes verify.

**7-year retention floor** (FR-016, SC-008): satisfied by the absence of any DELETE code path against `audit_entries`. Operational retention scheduling beyond 7 years is out of scope.

## Entity-relationship diagram

```text
users (1) ─< tokens                                       (auth stub)
   │
   │ (clinician — many memberships; administrators have none)
   │
   └─< care_team_memberships >─ patients
                                   │
                                   ├── patient_summaries   (1:1; safety-relevant snapshot)
                                   ├──< encounters         (1:many; chronological)
                                   ├──< clinical_notes     (1:many; append-only)
                                   │
                                   │  (audit_entries.patient_id NOT FK'd to patients.id —
                                   │   audit entries can exist for nonexistent patient ids)
                                   │
   users (1) ────────────────────< audit_entries
```

The audit-entries table has no foreign-key constraint on `patient_id` — this is deliberate, so the audit log can capture access attempts against patient identifiers that turn out not to correspond to any real patient (FR-012's "every attempt is audited, regardless of outcome").

## SQL schema (illustrative)

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 134217728;

CREATE TABLE users (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    user_role TEXT NOT NULL
        CHECK (user_role IN ('doctor','nurse','pharmacist','clinical_admin','hospital_administrator'))
);

CREATE TABLE tokens (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    expires_at TEXT NOT NULL
);

CREATE TABLE patients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    date_of_birth TEXT NOT NULL
);

CREATE TABLE patient_summaries (
    patient_id TEXT PRIMARY KEY REFERENCES patients(id),
    allergies_json TEXT NOT NULL DEFAULT '[]',
    key_warnings_json TEXT NOT NULL DEFAULT '[]',
    current_medications_json TEXT NOT NULL DEFAULT '[]'
);

CREATE TABLE encounters (
    id TEXT PRIMARY KEY,
    patient_id TEXT NOT NULL REFERENCES patients(id),
    encounter_date TEXT NOT NULL,
    encounter_type TEXT NOT NULL,
    summary TEXT NOT NULL
);

CREATE INDEX idx_encounters_by_patient ON encounters(patient_id, encounter_date DESC);

CREATE TABLE care_team_memberships (
    clinician_id TEXT NOT NULL REFERENCES users(id),
    patient_id TEXT NOT NULL REFERENCES patients(id),
    episode_of_care_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active','ended')),
    start_date TEXT NOT NULL,
    end_date TEXT,
    PRIMARY KEY (clinician_id, patient_id, episode_of_care_id)
);

CREATE INDEX idx_care_team_by_clinician_patient
    ON care_team_memberships(clinician_id, patient_id, status);

CREATE TABLE clinical_notes (
    id TEXT PRIMARY KEY,
    patient_id TEXT NOT NULL REFERENCES patients(id),
    author_user_id TEXT NOT NULL REFERENCES users(id),
    author_display_name TEXT NOT NULL,
    author_role TEXT NOT NULL
        CHECK (author_role IN ('doctor','nurse','pharmacist','clinical_admin')),
    created_at TEXT NOT NULL,
    note_type TEXT NOT NULL
        CHECK (note_type IN ('progress','assessment','plan','observation','discharge_summary')),
    body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 8000),
    encounter_date TEXT NOT NULL CHECK (date(encounter_date) <= date(created_at))
);

CREATE INDEX idx_notes_by_patient_chrono ON clinical_notes(patient_id, created_at, id);

CREATE TABLE audit_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id),
    user_display_name TEXT NOT NULL,
    user_role TEXT NOT NULL
        CHECK (user_role IN ('doctor','nurse','pharmacist','clinical_admin','hospital_administrator')),
    patient_id TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    access_type TEXT NOT NULL CHECK (access_type IN ('read','add_note','list_audit')),
    note_id TEXT,
    outcome TEXT NOT NULL
        CHECK (outcome IN ('permitted','denied','not_found_or_denied')),
    authorisation_basis TEXT NOT NULL
        CHECK (authorisation_basis IN ('care_team_member','not_care_team_member','patient_not_found','administrator_role')),
    CHECK (
        (access_type = 'add_note' AND outcome = 'permitted' AND note_id IS NOT NULL)
     OR (access_type = 'add_note' AND outcome != 'permitted' AND note_id IS NULL)
     OR (access_type IN ('read','list_audit') AND note_id IS NULL)
    )
);

CREATE INDEX idx_audit_by_patient_chrono ON audit_entries(patient_id, occurred_at, id);
CREATE INDEX idx_audit_by_user_chrono ON audit_entries(user_id, occurred_at, id);
```

## How invariants map to storage

| Invariant (from spec)                                                       | Where enforced                                                                                                                                       |
|-----------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| FR-001 / SC-004 authentication boundary                                      | `server.py` boundary: bearer-token resolution via `tokens` table before dispatch.                                                                     |
| FR-003 / SC-005 no patient_id in URL paths                                   | All three endpoints are `POST` with `patient_id` in the body. Static probe in `test_no_url_pii.py`.                                                    |
| FR-004 / SC-010 care-team-membership gating (clinicians)                     | `permissions.can_access` runs the indexed SQL probe on every clinical-endpoint request. Fail-closed on missing membership.                            |
| FR-005 / FR-017 administrator-only audit endpoint                            | `permissions.is_administrator` check on `POST /audit/search`; non-administrator callers receive the byte-equivalent 404.                              |
| FR-005 / FR-018 / SC-006 administrator content-blindness                     | `admin_response.py` module is the sole code path for administrator responses; static probe + runtime walk probe enforce absence of clinical-content keys. |
| FR-006 / SC-003 byte-equivalent unauthorised response                        | Single `responses.not_found_response()` helper at every refused code path. Pinned `(status=404, content_type, content_length=48, body)`.              |
| FR-007 / FR-019 / FR-020 fixed response field order                          | `clinical_safety.build_patient_record()` is the sole code path that builds a successful read response; `test_clinical_safety.py` walks response keys. |
| FR-009 note submission validation                                            | `validation.validate_note_payload()` + column CHECKs (`length(body) BETWEEN 1 AND 8000`, enum CHECKs).                                                |
| FR-011 / SC-007 notes append-only                                            | No UPDATE/DELETE SQL on `clinical_notes`; schema CHECK `author_role` excludes administrator; static + runtime probes.                                  |
| FR-012 / SC-001 / SC-002 always-on audit                                     | Audit INSERT happens for every clinical-endpoint code path regardless of outcome (atomic with any state change).                                       |
| FR-013 audit-entry shape                                                     | Schema enumerates every required column with NOT NULL or CHECK; the snapshot fields (`user_display_name`, `user_role`) are populated at INSERT time.   |
| FR-014 / SC-008 audit immutability                                           | No UPDATE/DELETE SQL on `audit_entries`. Static + runtime probes.                                                                                     |
| FR-015 / SC-009 2-second audit SLA                                           | Audit INSERT in same transaction as the state change. SQLite connection `timeout=1.8`; `OperationalError` → `503 service_unavailable`.                |
| FR-016 audit retention ≥ 7 years                                             | No DELETE code path against `audit_entries`. Operational scheduling out of scope.                                                                     |

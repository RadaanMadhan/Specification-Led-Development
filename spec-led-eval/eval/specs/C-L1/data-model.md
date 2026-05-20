# Data Model: Clinician Access to Patient Medical Records (v1)

**Branch**: `009-clinician-record-access` | **Date**: 2026-05-17

All entities persisted in SQLite (`sqlite3` stdlib) in WAL mode. All identifiers are opaque strings. All timestamps are UTC ISO 8601 with millisecond precision and `Z` suffix. Dates are date-only `YYYY-MM-DD`.

## Enums

### ClinicianRole

```python
class ClinicianRole(StrEnum):
    DOCTOR = "doctor"
    NURSE = "nurse"
    PHARMACIST = "pharmacist"
    AUDIT_OFFICER = "audit_officer"
    CLINICAL_ADMIN = "clinical_admin"
```

Read from the host product's identity context on every request (FR-002). v1's catalogue.

### AccessOutcome

```python
class AccessOutcome(StrEnum):
    PERMITTED = "permitted"
    DENIED = "denied"
    NOT_FOUND_OR_DENIED = "not_found_or_denied"
```

Recorded on every audit entry. Note: "denied" and "not_found_or_denied" produce identical responses to the caller (FR-007); they are distinguished only in the audit log so IG can spot patterns.

### AuthorisationBasis

```python
class AuthorisationBasis(StrEnum):
    CARE_TEAM_MEMBER = "care_team_member"
    NOT_CARE_TEAM_MEMBER = "not_care_team_member"
    PATIENT_NOT_FOUND = "patient_not_found"
    # No break-glass basis in v1 (Q3 = A).
```

### MembershipStatus

```python
class MembershipStatus(StrEnum):
    ACTIVE = "active"
    ENDED = "ended"
```

Membership in a patient's care team. Only `active` rows authorise access.

## Entities

### User (clinician or IG officer)

| Field         | Type           | Storage                                                                                    | Notes |
|---------------|----------------|--------------------------------------------------------------------------------------------|-------|
| id            | str            | TEXT PK                                                                                    | Opaque clinician_id from the host product. |
| display_name  | str            | TEXT NOT NULL                                                                              | For audit-entry rendering. |
| clinician_role| ClinicianRole  | TEXT CHECK IN ('doctor','nurse','pharmacist','audit_officer','clinical_admin') NOT NULL    | One per user. The IG role (`audit_officer`) is a User row too. |

### Token (auth stub for v1)

| Field      | Type | Storage                              | Notes |
|------------|------|--------------------------------------|-------|
| token      | str  | TEXT PK                              | Opaque bearer. |
| user_id    | str  | TEXT NOT NULL FK→users.id            | Resolves to a User. |
| expires_at | str  | TEXT NOT NULL                        | UTC ISO 8601. |

In a real deployment this is replaced by the host's identity provider (NHS smartcard / OIDC). The `auth.py` module documents the swap point.

### Patient

| Field         | Type | Storage                  | Notes |
|---------------|------|--------------------------|-------|
| id            | str  | TEXT PK                  | Opaque `patient_id` (NHS number / MRN). |
| name          | str  | TEXT NOT NULL            | Displayed in the patient summary. |
| date_of_birth | str  | TEXT NOT NULL            | `YYYY-MM-DD`. Used for the patient-verification block at the top of the response (FR-015). |

### PatientSummary (a per-patient denormalised view of the safety-relevant fields)

| Field              | Type | Storage                              | Notes |
|--------------------|------|--------------------------------------|-------|
| patient_id         | str  | TEXT PK FK→patients.id               | One row per patient. |
| allergies_json     | str  | TEXT NOT NULL DEFAULT '[]'           | JSON array of `{"substance": str, "severity": str, "notes": str}` objects. Surfaced at the top of every read response (FR-014). |
| key_warnings_json  | str  | TEXT NOT NULL DEFAULT '[]'           | JSON array of `{"category": str, "text": str}` objects. Surfaced at the top of every read response (FR-014). |
| current_medications_json | str | TEXT NOT NULL DEFAULT '[]'      | JSON array of `{"name": str, "dose": str, "frequency": str}` objects. |

This is a *snapshot* table for v1 — in a real EHR these fields come from the live clinical record. For the PoC, the `--seed` step populates them; there is no write surface to modify them in v1.

### Encounter

| Field         | Type | Storage                              | Notes |
|---------------|------|--------------------------------------|-------|
| id            | str  | TEXT PK                              | UUID4. |
| patient_id    | str  | TEXT NOT NULL FK→patients.id         | |
| encounter_date| str  | TEXT NOT NULL                        | `YYYY-MM-DD`. |
| encounter_type| str  | TEXT NOT NULL                        | E.g., `"GP visit"`, `"A&E"`, `"outpatient"`. |
| summary       | str  | TEXT NOT NULL                        | Short text — the "recent encounters" summary line. v1 does NOT expose full notes. |

**Index**: `CREATE INDEX idx_encounters_by_patient ON encounters(patient_id, encounter_date DESC);` — supports the "recent encounters" list ordered most-recent-first in the patient summary.

### CareTeamMembership

The authoritative source of care-team relationships within this feature. Populated by the host product's care-team-management feed (out of scope of 009 to define).

| Field               | Type             | Storage                                                                                   | Notes |
|---------------------|------------------|-------------------------------------------------------------------------------------------|-------|
| clinician_id        | str              | TEXT NOT NULL FK→users.id                                                                  | |
| patient_id          | str              | TEXT NOT NULL FK→patients.id                                                               | |
| episode_of_care_id  | str              | TEXT NOT NULL                                                                              | The host product's episode-of-care identifier. Opaque here. |
| status              | MembershipStatus | TEXT CHECK IN ('active','ended') NOT NULL                                                  | |
| start_date          | str              | TEXT NOT NULL                                                                              | UTC ISO 8601. |
| end_date            | str \| None      | TEXT NULL                                                                                  | UTC ISO 8601. NULL while active. |

**Composite PK**: `(clinician_id, patient_id, episode_of_care_id)` — one membership per clinician-patient-episode triple.

**Index**: `CREATE INDEX idx_care_team_by_clinician_patient ON care_team_memberships(clinician_id, patient_id, status);` — supports the FR-006 lookup (the hottest query path in the system).

### AuditEntry

Append-only per-access record (FR-009, FR-010, FR-012).

| Field                  | Type              | Storage                                                                                            | Notes |
|------------------------|-------------------|----------------------------------------------------------------------------------------------------|-------|
| id                     | int               | INTEGER PRIMARY KEY AUTOINCREMENT                                                                  | Monotonic; chronological ordering within a patient. |
| clinician_id           | str               | TEXT NOT NULL FK→users.id                                                                          | |
| clinician_display_name | str               | TEXT NOT NULL                                                                                       | Snapshotted from `users.display_name` at the time of the access. Renames in the host do not retroactively change the audit. |
| clinician_role         | ClinicianRole     | TEXT NOT NULL CHECK(clinician_role IN ('doctor','nurse','pharmacist','audit_officer','clinical_admin')) | Snapshotted at the time of the access. |
| patient_id             | str               | TEXT NOT NULL                                                                                       | **Not** FK-constrained: we still log an audit entry when the patient_id doesn't exist (FR-008). |
| occurred_at            | str               | TEXT NOT NULL                                                                                       | UTC ISO 8601 with millisecond precision and `Z` suffix. |
| access_type            | str               | TEXT NOT NULL CHECK(access_type IN ('read'))                                                       | v1: always `'read'`. Future write features (Q2 ≠ A) would add `'amend'`, `'prescribe'`. |
| outcome                | AccessOutcome     | TEXT NOT NULL CHECK(outcome IN ('permitted','denied','not_found_or_denied'))                       | |
| authorisation_basis    | AuthorisationBasis| TEXT NOT NULL CHECK(authorisation_basis IN ('care_team_member','not_care_team_member','patient_not_found')) | |

**Indexes**:

- `CREATE INDEX idx_audit_by_patient_chrono ON audit_entries(patient_id, occurred_at, id);` — chronological retrieval per patient (FR-011 `POST /audit/search`).
- `CREATE INDEX idx_audit_by_clinician_chrono ON audit_entries(clinician_id, occurred_at, id);` — supports an operational "what has clinician X accessed today" query for IG, even though that query isn't exposed via an endpoint in v1.

**Append-only**: no UPDATE/DELETE SQL targets `audit_entries` in `store.py`. Static probe in `test_invariants.py` greps for forbidden statements; runtime probe samples row hashes across snapshots.

**8-year retention floor** (FR-012, SC-006): satisfied by the absence of any DELETE path. No automatic age-out within the retention period. Paediatric-records-until-25th-birthday is handled by the same "no DELETE" mechanism — the floor is at least 8 years, and the system never deletes.

## Entity-relationship diagram

```text
users (1) ─< tokens                                            (auth stub)
   │
   │ (clinician — many memberships)
   │
   └─< care_team_memberships >─ patients
                                   │
                                   ├── patient_summaries   (1:1; the safety-relevant view)
                                   ├──< encounters         (1:many; chronological)
                                   │
                                   │ (audit not FK'd; we log even non-existent patient_id)
                                   │
   users (1) ────────────────────< audit_entries  >── patient_id (string, not FK)
```

## SQL schema (illustrative)

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 134217728;

CREATE TABLE users (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    clinician_role TEXT NOT NULL
        CHECK (clinician_role IN ('doctor','nurse','pharmacist','audit_officer','clinical_admin'))
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

CREATE TABLE audit_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    clinician_id TEXT NOT NULL REFERENCES users(id),
    clinician_display_name TEXT NOT NULL,
    clinician_role TEXT NOT NULL
        CHECK (clinician_role IN ('doctor','nurse','pharmacist','audit_officer','clinical_admin')),
    patient_id TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    access_type TEXT NOT NULL CHECK (access_type IN ('read')),
    outcome TEXT NOT NULL
        CHECK (outcome IN ('permitted','denied','not_found_or_denied')),
    authorisation_basis TEXT NOT NULL
        CHECK (authorisation_basis IN ('care_team_member','not_care_team_member','patient_not_found'))
);

CREATE INDEX idx_audit_by_patient_chrono ON audit_entries(patient_id, occurred_at, id);
CREATE INDEX idx_audit_by_clinician_chrono ON audit_entries(clinician_id, occurred_at, id);
```

## How invariants map to storage

| Invariant (from spec)                                                       | Where enforced                                                                                                              |
|-----------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| FR-001 / SC-004 authentication boundary                                      | `server.py` boundary: bearer-token resolution via `tokens` table before dispatch.                                            |
| FR-004 / SC-005 no patient_id in URL paths                                   | All endpoints are `POST` with patient_id in the body. Static probe `test_no_url_pii.py` greps `server.py` routing.            |
| FR-006 / SC-010 care-team-membership gating                                  | `permissions.can_access` runs the indexed SQL probe on every request. Fail-closed on missing membership row.                  |
| FR-007 / SC-003 byte-equivalent denied / not-found                           | Single `responses.not_found_response()` helper. Pinned `(status, content_type, content_length, body)`.                       |
| FR-008 / SC-001 / SC-002 always-on audit                                     | Audit INSERT happens for every code path that reaches the service layer (`permitted` / `denied` / `not_found_or_denied`).    |
| FR-009 audit-entry shape                                                     | Schema enumerates every required column; service layer populates from the `AuthenticatedCaller` (snapshot semantics).         |
| FR-010 / SC-006 audit immutability                                           | No UPDATE/DELETE SQL targets `audit_entries`. Static + runtime probes.                                                       |
| FR-011 audit readable by IG only                                             | Permission predicate `clinician_role == 'audit_officer'` on `POST /audit/search`. Non-IG callers get the byte-equivalent 404. |
| FR-012 / SC-006 8-year retention floor                                       | No DELETE code path. Operational retention scheduling out of scope.                                                          |
| FR-013 / SC-007 2-second audit SLA                                           | INSERT in same transaction as the access decision. SQLite connection `timeout=1.8`. `OperationalError` → `503`.              |
| FR-014 / SC-008 allergies and warnings at top of response                    | `clinical_safety.build_patient_summary` enforces the JSON key order. `test_clinical_safety.py` walks the response key order.  |
| FR-015 identifier + DoB at top of response                                   | Same as FR-014 — key order enforced in one place, tested in one place.                                                       |
| SC-011 IG endpoint hidden from non-IG roles                                  | Non-IG calls to `/audit/search` return the byte-equivalent 404 — no `403 forbidden` that would leak the endpoint's existence. |

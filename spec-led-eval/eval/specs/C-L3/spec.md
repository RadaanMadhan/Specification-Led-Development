# Feature Specification: HIPAA Hospital Clinical Record Access

**Feature Branch**: `013-hipaa-clinical-records`
**Created**: 2026-05-17
**Status**: Draft — pending governance review (see notice below)
**Input**: User description: "Build a clinical record access feature for a hospital information system under HIPAA. Authenticated users carry one of three roles: clinician, patient, or compliance_officer. Clinicians can read a patient's medical record only if they are listed in that patient's current care team (a many-to-many relationship); clinicians outside the care team must be rejected with HTTP 403 within 200ms. Clinicians who are in the care team can append clinical notes (a write-only operation) but cannot modify or delete existing notes. Patients (role: patient) can read their own records and their own access logs but no one else's, and cannot write any clinical content. Compliance officers can read all access logs system-wide but cannot read the clinical content of records, and cannot write to any record. The system must enforce that the response to GET /records/{id} is byte-equivalent for any caller without permission, regardless of whether the record exists — preventing information leakage about which patient identifiers exist. Every record-access event (read, append, list) must be written to an append-only audit log within 1 second, capturing record_id, accessor_user_id, accessor_role, timestamp (UTC ISO 8601), operation type, and originating IP address. Audit entries cannot be updated or deleted, and must be retained for at least 7 years to satisfy HIPAA §164.530(j). Endpoints: GET /records/{id}, POST /records/{id}/notes, GET /records/{id}/audit, GET /access-log."

> ## ⚠ Governance notice (read before planning)
>
> This spec describes a record-access feature handling patient health information under HIPAA, in a regulated domain. Before implementation begins, the spec should be reviewed by:
>
> - The product owner (to confirm scope).
> - A HIPAA Privacy Officer and a HIPAA Security Officer (to confirm the access-control model, the audit fields and retention period, and the byte-equivalent response strategy meet HIPAA §164.308 and §164.312 expectations).
> - A clinical-safety officer or equivalent (to confirm the care-team-only authorisation model and the absence of an emergency-access path are appropriate for the host hospital's clinical workflows).
> - A performance engineer (to confirm the 200ms 403-rejection latency target is achievable in the production deployment topology).
>
> The Assumptions section commits to conservative defaults. The governance review should validate that these defaults match the host organisation's policies and infrastructure or flag where they need to be tightened.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Clinician on the Care Team Reads a Patient's Record (Priority: P1)

A signed-in clinician who is currently listed on a patient's care team requests that patient's record. The system returns the record content and writes one entry to an immutable audit log within 1 second of the operation. The audit entry captures who accessed the record, when, what operation, the originating IP address, and the outcome.

**Why this priority**: Indispensable first slice; the primary clinical workflow.

**Independent Test**: A test clinician with an active care-team-membership row for a test patient can request that patient's record by record identifier and receive a `200 OK` response with the record content. The audit log gains exactly one new entry recording the clinician's identity, role (`clinician`), the record identifier, the timestamp (UTC ISO 8601), the operation type `read`, the originating IP address, and outcome `permitted`.

**Acceptance Scenarios**:

1. **Given** an authenticated user with role `clinician` and an active care-team-membership row for record `R`, **When** they call `GET /records/R`, **Then** the system returns `200 OK` with the record content; writes one audit entry within 1 second with `record_id=R`, `accessor_user_id=<clinician's id>`, `accessor_role=clinician`, `timestamp=<UTC ISO 8601>`, `operation=read`, `originating_ip_address=<request's client IP>`, and `outcome=permitted`.
2. **Given** an authenticated user with role `clinician` and **no** active care-team-membership row for record `R`, **When** they call `GET /records/R`, **Then** the system returns **HTTP 403 within 200 milliseconds** of receiving the request, with a response body byte-identical to the response for a record identifier that does not exist; writes one audit entry with `outcome=denied`.
3. **Given** an authenticated user with role `clinician`, **When** they call `GET /records/{id}` for a record identifier `{id}` that does not correspond to any record, **Then** the system returns the same byte-equivalent HTTP 403 response as scenario 2; writes one audit entry with `outcome=denied` (or an equivalent `not_found_or_denied` value if the system distinguishes internally; the wire response is byte-equivalent).
4. **Given** an unauthenticated request, **When** it reaches the system, **Then** the system rejects it at the authentication boundary with `401 unauthenticated` before any record identifier is dereferenced; no audit entry is written for that attempt.

---

### User Story 2 - Clinician on the Care Team Appends a Clinical Note (Priority: P1)

A clinician on a patient's care team submits a new clinical note against the patient's record. The note is persisted; the audit log records the append event within 1 second. Notes are **append-only** — once submitted, no clinician (including the author) can edit or delete the note through this feature.

**Why this priority**: The append surface is the only write operation in the feature and is explicit in the user description.

**Independent Test**: A test clinician on a patient's care team can submit a clinical note (non-empty body within the allowed length, valid note type) via `POST /records/{id}/notes` and receive `201 Created` with the new note's identifier. The audit log gains one new entry with `operation=append`. Any attempt to edit or delete a previously-appended note through any endpoint of this feature fails (no such endpoint exists).

**Acceptance Scenarios**:

1. **Given** an authenticated user with role `clinician` and an active care-team-membership row for record `R`, **When** they call `POST /records/R/notes` with a valid request body (non-empty `body` ≤ 8000 characters, a valid `note_type`, optionally an `encounter_date` that is not in the future), **Then** the system stores the note (with the author's identity and role snapshotted at the time of writing) and returns `201 Created` with the new note's identifier. The system writes one audit entry within 1 second with `record_id=R`, `accessor_user_id=<clinician's id>`, `accessor_role=clinician`, `operation=append`, `originating_ip_address=<request's client IP>`, outcome `permitted`, and the new note's id.
2. **Given** an authenticated user with role `clinician` and **no** active care-team-membership row for record `R`, **When** they call `POST /records/R/notes`, **Then** the system rejects with the same byte-equivalent HTTP 403 response as scenario 2 of US1; writes one audit entry with `operation=append`, `outcome=denied`; no note is created.
3. **Given** an authenticated user with role `patient` (any patient), **When** they call `POST /records/{id}/notes` for any record id, **Then** the system rejects with the byte-equivalent HTTP 403 response; writes one audit entry with `accessor_role=patient`, `operation=append`, `outcome=denied`; no note is created.
4. **Given** an authenticated user with role `compliance_officer`, **When** they call `POST /records/{id}/notes` for any record id, **Then** the system rejects with the byte-equivalent HTTP 403 response; writes one audit entry with `accessor_role=compliance_officer`, `operation=append`, `outcome=denied`; no note is created.
5. **Given** any previously-appended note, **When** any caller attempts to modify or delete it through any endpoint of this feature, **Then** the operation is refused (no edit or delete endpoint exists for notes); the note is unchanged.

---

### User Story 3 - Patient Reads Their Own Record and Their Own Access Log (Priority: P1)

A patient (role: `patient`) reads their own record and their own access log. They cannot read any other record, any other patient's access log, or write any clinical content.

**Why this priority**: Patient right-of-access is a core HIPAA Privacy Rule expectation (45 CFR §164.524) and the user description explicitly grants patients read access to their own records and their own audit logs.

**Independent Test**: A test patient with their own record identifier `R_P` can call `GET /records/R_P` and receive `200 OK`, and can call `GET /records/R_P/audit` and receive `200 OK` with the access log for their record. Any other record id returns the byte-equivalent HTTP 403. Any `POST /records/{id}/notes` returns the byte-equivalent HTTP 403.

**Acceptance Scenarios**:

1. **Given** an authenticated user with role `patient` whose own record identifier is `R_P`, **When** they call `GET /records/R_P`, **Then** the system returns `200 OK` with the record content; writes one audit entry with `accessor_role=patient`, `operation=read`, `outcome=permitted`, `originating_ip_address=<request's IP>`.
2. **Given** the same patient, **When** they call `GET /records/R_P/audit`, **Then** the system returns `200 OK` with the chronological list of audit entries recorded against their record; writes one audit entry with `operation=list`, `outcome=permitted`.
3. **Given** the same patient, **When** they call `GET /records/R_OTHER` for any record identifier other than `R_P` (whether real or fabricated), **Then** the system returns the byte-equivalent HTTP 403 response; writes one audit entry with `outcome=denied`.
4. **Given** an authenticated patient, **When** they call `POST /records/{id}/notes` for any record id, **Then** the response is byte-equivalent HTTP 403 (FR-007); no note is created.

---

### User Story 4 - Compliance Officer Reads the System-Wide Access Log (Priority: P1)

A compliance officer (role: `compliance_officer`) reads access logs across all patients to investigate access patterns, fulfil audit requests, or run routine compliance reviews. The response contains **no clinical content** of any record — only audit-event metadata: who accessed what record, when, with what outcome. Compliance officers cannot read clinical content through any endpoint of this feature and cannot write to any record.

**Why this priority**: Auditability of access is a core HIPAA Security Rule requirement (§164.312(b) Audit Controls). Compliance officers are the role that does that inspection.

**Independent Test**: A test compliance officer can call `GET /access-log` (optionally with filters) and receive the audit entries system-wide; the response is verified to contain no clinical-content field. Any `GET /records/{id}` returns the byte-equivalent HTTP 403; any `POST /records/{id}/notes` returns the byte-equivalent HTTP 403.

**Acceptance Scenarios**:

1. **Given** an authenticated user with role `compliance_officer`, **When** they call `GET /access-log` (with no filters), **Then** the system returns `200 OK` with the chronological list of audit entries system-wide. Each event in the response contains: `record_id`, `accessor_user_id`, `accessor_user_display_name`, `accessor_role`, `timestamp`, `operation`, `outcome`, `originating_ip_address`. The response contains **no** field carrying clinical record content (no record body, no note text, no allergies, no warnings, no medication names, no encounter narratives, no patient name, no patient date of birth).
2. **Given** an authenticated compliance officer, **When** they call `GET /records/{id}` for any record id, **Then** the system returns the byte-equivalent HTTP 403 response; writes one audit entry with `accessor_role=compliance_officer`, `operation=read`, `outcome=denied`.
3. **Given** an authenticated compliance officer, **When** they call `POST /records/{id}/notes` for any record id, **Then** the system returns the byte-equivalent HTTP 403; writes one audit entry with `operation=append`, `outcome=denied`; no note is created.
4. **Given** an authenticated user with role `clinician` or `patient`, **When** they call `GET /access-log`, **Then** the system returns the byte-equivalent HTTP 403 response: the system-wide access log is compliance-officer-only, and its existence is not signalled to other roles.

---

### User Story 5 - Cross-Caller Byte-Equivalent Unauthorised Response (Priority: P1)

For any caller without permission to access a given record, the response to `GET /records/{id}` is byte-equivalent regardless of whether the record exists. No information about the existence of any record identifier leaks to anyone without permission.

**Why this priority**: This is the explicit privacy-of-existence guarantee in the user description. Multi-tenant existence leaks undermine HIPAA's minimum-necessary rule (45 CFR §164.502(b)) and patient trust.

**Independent Test**: With a known real record id `R_real` (that the caller is not authorised to access) and a fabricated id `R_fake` (that has never existed), the caller's `GET /records/R_real` and `GET /records/R_fake` produce byte-identical responses: same HTTP status code, same response body bytes, same `Content-Type` header, same `Content-Length` header. The same byte-equivalence property holds for `POST /records/{id}/notes` and `GET /records/{id}/audit` when called by unauthorised callers.

**Acceptance Scenarios**:

1. **Given** any authenticated caller without permission for record `R` (a real record), and a fabricated id `R_fake` that has never existed, **When** they call `GET /records/R` and `GET /records/R_fake`, **Then** the two responses have the same HTTP status code, the same response body bytes, the same `Content-Type` header, and the same `Content-Length` header.
2. **Given** the byte-equivalence requirement extended to the other record-scoped endpoints (`POST /records/{id}/notes` and `GET /records/{id}/audit`), **When** the caller hits each endpoint with `R` and with `R_fake`, **Then** the unauthorised responses are byte-identical across the (real, fake) pair for each endpoint.

---

### Edge Cases

- **The 200ms HTTP 403 latency target on the unhappy path (FR-009)**: The non-care-team-clinician rejection must complete within 200 milliseconds end-to-end, including authentication, role resolution, the care-team-membership predicate, the audit-entry write, and response serialisation. Tested by a performance probe that fires many concurrent requests by a non-care-team clinician and asserts p99 latency at or below 200ms.
- **Audit-write SLA at 1 second (FR-016)**: The audit entry must be durably persisted within 1 second of the access operation completing. If the audit write cannot complete in time (under storage contention or transient failure), the access is rolled back and the system returns a service-unavailable response; no record content is returned, no note is persisted, and no audit entry exists for that attempt.
- **Concurrent reads or note additions on the same record**: each access produces its own audit entry; ordering follows recorded timestamps. Two notes appended at near-simultaneous times both succeed and both appear in the chronological list.
- **Care-team membership revocation mid-session**: the membership predicate runs on every request; a revoked clinician's subsequent access produces a denied audit entry.
- **A compliance officer's `GET /access-log` returning many entries**: the response is paginated by default (`limit` query parameter; default 1000, maximum 10000). Filters by `accessor_user_id`, `record_id`, `from`/`to` (ISO 8601 datetimes) narrow the result set.
- **Originating IP address capture**: read from the HTTP request's remote address. If the system is behind a configured trusted reverse proxy, the right-most trusted IP in the `X-Forwarded-For` header is used. The captured IP is stored verbatim in the audit log; it is not anonymised or hashed.
- **A note's body contains markdown, HTML-like text, or line breaks**: stored verbatim and rendered as plain text on subsequent reads. The system never interprets markup.
- **A note's `encounter_date` is in the future**: rejected with a field-level validation error (no clinical meaning for a future encounter date).
- **The record identifier in URL paths**: `{id}` is an opaque record identifier (an internal system handle that is not itself a patient demographic — not a name, date of birth, or social security number). It is generated by this feature when a record is created (creation is out of scope of v1 — see Assumptions). The use of `record_id` in URL paths is acceptable; identifiers that are personally identifying patient demographics must not appear in URL paths.
- **Notes are append-only by design**: no edit or delete endpoint exists in this feature's surface; any such request to a hypothetical PATCH/DELETE on a note returns either `405 Method Not Allowed` or the byte-equivalent HTTP 403, both of which communicate "no such operation".
- **An unauthenticated request reaches the system**: rejected at the authentication boundary; no audit entry written.
- **No emergency-access (break-glass) path**: a clinician who needs to access a record they are not on the care team for must use the host product's operational fallback (re-assignment to the care team by clinical leadership; paper records; information-governance-mediated manual review). The audit log still captures any denied attempts.

## Requirements *(mandatory)*

### Functional Requirements

#### Authentication, identity, and roles

- **FR-001**: All requests to this feature MUST be made by an authenticated user. Unauthenticated requests MUST be rejected at the authentication boundary with `401 unauthenticated` before any record identifier is dereferenced and **without writing an audit entry** for that attempt. The authentication-failure log lives outside this feature, in the host product's identity-provider stack.
- **FR-002**: The system MUST resolve every authenticated request to (a) a `user_id` (an opaque identifier from the host product's identity system), (b) a `display_name`, and (c) a `role` from the catalogue `{clinician, patient, compliance_officer}`. A user holds exactly one role at a time. These three pieces of identity MUST be taken from the host product's authenticated identity context, never from the request payload.
- **FR-003**: A user with role `patient` additionally has an `assigned_record_id` — the one record identifier they are authorised to read. This relationship is established by the host product and read on each request; this feature does not modify it.

#### Authorisation matrix

The authorisation rules below are normative. The four endpoints exposed by this feature are: `GET /records/{id}`, `POST /records/{id}/notes`, `GET /records/{id}/audit`, `GET /access-log`.

| Endpoint                            | Caller `clinician`, in care team for `{id}` | Caller `clinician`, not in care team | Caller `patient`, `{id} = assigned_record_id` | Caller `patient`, other `{id}` | Caller `compliance_officer` |
|-------------------------------------|---------------------------------------------|--------------------------------------|------------------------------------------------|--------------------------------|------------------------------|
| `GET /records/{id}`                 | `200 OK`                                    | `HTTP 403` byte-equivalent within 200ms | `200 OK`                                       | `HTTP 403` byte-equivalent     | `HTTP 403` byte-equivalent   |
| `POST /records/{id}/notes`          | `201 Created`                               | `HTTP 403` byte-equivalent           | `HTTP 403` byte-equivalent                     | `HTTP 403` byte-equivalent     | `HTTP 403` byte-equivalent   |
| `GET /records/{id}/audit`           | `200 OK`                                    | `HTTP 403` byte-equivalent           | `200 OK` (own record only)                     | `HTTP 403` byte-equivalent     | `200 OK`                     |
| `GET /access-log`                   | `HTTP 403` byte-equivalent                  | `HTTP 403` byte-equivalent           | `HTTP 403` byte-equivalent                     | (not applicable)               | `200 OK`                     |

- **FR-004**: A user with role `clinician` MAY call `GET /records/{id}` and `POST /records/{id}/notes` **if and only if** there exists an active care-team-membership record linking `(clinician.user_id, {id}, episode_of_care_id)` with status `active` and a date range that includes the current moment. This is a many-to-many relationship: a clinician may be on many records' care teams; a record may have many clinicians on its care team. The membership predicate MUST be evaluated on every request, before any clinical content is returned or any note persisted.
- **FR-005**: A user with role `clinician` MAY call `GET /records/{id}/audit` for any record where they are an active care-team member. They MAY NOT call `GET /access-log` (the system-wide audit endpoint is compliance-officer-only).
- **FR-006**: A user with role `patient` MAY call `GET /records/{id}` and `GET /records/{id}/audit` if and only if `{id} = user.assigned_record_id`. They MUST NOT be able to call `POST /records/{id}/notes` for any record, and MUST NOT be able to call `GET /access-log`.
- **FR-007**: A user with role `compliance_officer` MAY call `GET /records/{id}/audit` for any record and `GET /access-log` system-wide. They MUST NOT be able to call `GET /records/{id}` (which returns clinical content) or `POST /records/{id}/notes`. The compliance-officer's responses MUST NOT contain any field carrying clinical record content.

#### Byte-equivalent unauthorised response (existence-leak prevention)

- **FR-008**: For every endpoint that takes a `{id}` path parameter (`GET /records/{id}`, `POST /records/{id}/notes`, `GET /records/{id}/audit`), if the caller does not have permission for the action under the matrix above, the system MUST return a response whose HTTP status code, response body bytes, `Content-Type` header, and `Content-Length` header are **byte-identical** to the response for the same endpoint and method with a `{id}` that does not exist anywhere in the system. The canonical unauthorised response is **HTTP 403 Forbidden** with body `{"error":"forbidden","message":"Access denied."}` (a body of fixed length and content). This byte-equivalence applies whether the record exists and the caller is unauthorised, or the record does not exist at all.
- **FR-009**: For a caller with role `clinician` calling `GET /records/{id}` where they are **not** in the record's care team, the system MUST return the byte-equivalent HTTP 403 response (FR-008) within **200 milliseconds** at the 99th percentile of a representative load. The 200ms budget covers authentication, role resolution, the care-team-membership predicate, the audit-entry write, and the response serialisation.

#### Append-only clinical notes

- **FR-010**: A `POST /records/{id}/notes` request body MUST contain: a `body` field (non-empty after trimming surrounding whitespace; length between 1 and 8000 characters), a `note_type` field (one of `progress`, `assessment`, `plan`, `observation`, `discharge_summary`), and optionally an `encounter_date` field (date-only `YYYY-MM-DD`, must not be in the future; defaults to today's date in UTC if absent). Submissions violating any of these constraints MUST be rejected with a `400 validation_error` response that lists every offending field.
- **FR-011**: On a permitted note submission, the system MUST persist the note with: an opaque `note_id`, the `record_id` (taken from the URL path), the `author_user_id` (the caller's id), the `author_display_name` snapshotted at the time of writing (so subsequent renames in the host product do not retroactively change historical notes), the `author_role` snapshotted at the time of writing, `created_at` set to the current UTC ISO 8601 timestamp with millisecond precision and explicit `Z` suffix, the `note_type` and `body` from the request, and the `encounter_date` (defaulting to the date portion of `created_at` if not supplied). The response MUST include the new `note_id`.
- **FR-012**: Clinical notes MUST be **append-only**: there MUST be no endpoint, no role, and no code path in this feature that can update or delete an existing clinical note. Subsequent reads return the note exactly as written. Amendments are achieved by adding a new note (the "addendum" practice); no in-product addendum linkage between notes is built in v1.

#### Audit log (always-on, 1-second SLA, immutable, ≥7-year retention)

- **FR-013**: For every record-access event — `read` on `GET /records/{id}`, `append` on `POST /records/{id}/notes`, `list` on `GET /records/{id}/audit` and `GET /access-log` — and regardless of outcome (`permitted` or `denied`), the system MUST write **exactly one** new audit entry. There MUST NOT be any successful state change without a matching audit entry, and there MUST NOT be any audit entry without a matching attempted access.
- **FR-014**: Each audit entry MUST contain at minimum the following fields: `record_id` (or null for `GET /access-log` events where no specific record is named), `accessor_user_id` (the caller's `user_id`), `accessor_user_display_name` (snapshotted at the time of access), `accessor_role` (`clinician`, `patient`, or `compliance_officer`, snapshotted at the time of access), `timestamp` (UTC ISO 8601 with millisecond precision and explicit `Z` suffix), `operation` (one of `read`, `append`, `list`), `outcome` (one of `permitted`, `denied`), `originating_ip_address` (the originating IP per the rules in the Edge Cases section), and — when `operation=append` and `outcome=permitted` — the `note_id` of the newly created note.
- **FR-015**: Audit entries MUST be **immutable**: there MUST be no API endpoint, no role (including `compliance_officer`), and no code path of this feature that can update or delete an existing audit entry.
- **FR-016**: Every audit entry MUST be durably persisted within **1 second** of the access operation completing. If the audit write would exceed 1 second, the access itself MUST be rolled back and the request MUST return `503 service_unavailable`; no record content returned, no note persisted, and no partial audit entry visible to any reader. Under no circumstances may a record be read by a caller, or a note appended, without a matching audit entry.
- **FR-017**: Audit entries MUST be retained for at least **7 years** from the date of the entry, satisfying HIPAA §164.530(j) (which mandates retention of "policies and procedures … communications … actions, activities, or designations" for a minimum of 6 years; this feature applies a 7-year floor as a defensive margin). There MUST be no code path in this feature that deletes audit entries within the retention window.

#### Compliance-officer endpoint and content-blindness

- **FR-018**: The system MUST expose `GET /access-log` accessible only to callers with role `compliance_officer`. Non-compliance callers MUST receive the byte-equivalent HTTP 403 response (FR-008). The endpoint MUST accept optional query parameters: `accessor_user_id` (filter by accessor), `record_id` (filter by record), `from` (inclusive lower bound on `timestamp`, ISO 8601), `to` (exclusive upper bound on `timestamp`, ISO 8601), and `limit` (default 1000, maximum 10000). All filters combine as a logical AND. Results are ordered by `timestamp` descending (most recent first).
- **FR-019**: The `GET /access-log` response and the `GET /records/{id}/audit` response when called by a compliance officer MUST NOT contain any field carrying clinical content. Specifically, the response MUST NOT contain any field named (or carrying the data of) `body`, `note_body`, `content`, `note_content`, `allergies`, `key_warnings`, `current_medications`, `recent_encounters`, `encounters`, `summary`, `patient_name`, `name`, `date_of_birth`, or `dob`. The response-builder for these endpoints, when invoked by a compliance officer, MUST be structurally separated from any code path that constructs clinical-content responses, so the invariant is enforceable by static inspection of the response-builder module.

#### URL handling — record identifiers only in URL paths

- **FR-020**: URL paths MUST use opaque `record_id` values only (the `{id}` in `/records/{id}` and `/records/{id}/notes` and `/records/{id}/audit`). The `record_id` is an internal system handle separate from any patient demographic identifier; it is not itself a personally identifying field. Patient demographics (name, date of birth, social security number) MUST NOT appear in URL paths under any circumstances; if such data needs to be transmitted, it goes in the request body or in headers redacted from web-server access logs.

### Key Entities *(include if feature involves data)*

- **User**: A signed-in person, with `user_id`, `display_name`, and exactly one `role` from `{clinician, patient, compliance_officer}`. A user with role `patient` additionally carries an `assigned_record_id`.
- **Record**: A patient medical record. Identified by an opaque `record_id`. Carries patient-demographic fields (`patient_name`, `date_of_birth`) and references to the patient summary, encounters, and clinical notes. The actual creation and lifecycle management of records is out of scope of this feature.
- **Patient Summary**: A per-record denormalised view including allergies, key warnings, and current medications. Snapshot for v1; modifications are out of scope.
- **Encounter**: A chronological clinical encounter brief (date, type, short summary).
- **Care-Team Membership**: An assertion by the host product that clinician `C` is on record `R`'s care team for an active episode of care. Identified by the tuple `(clinician_user_id, record_id, episode_of_care_id)`. Carries `status` (`active` or `ended`) and a date range. Many-to-many: a clinician may have many memberships; a record may have many clinicians.
- **Clinical Note**: An append-only note appended to a record by a care-team clinician. Carries `note_id`, `record_id`, `author_user_id`, `author_display_name` snapshot, `author_role` snapshot, `created_at`, `note_type`, `body`, `encounter_date`.
- **Audit Entry**: An immutable append-only record of one access event, with the fields enumerated in FR-014.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of record-access attempts (record reads, note appends, audit-listing reads) have a corresponding audit entry, whether the outcome was permitted or denied.
- **SC-002**: **Zero** occurrences in production where a record access succeeds without a matching audit entry, or where an audit entry exists without a matching attempted access.
- **SC-003**: **Zero** occurrences in production where the response to `GET /records/{id}` distinguishes — at the level of HTTP status code, response body bytes, `Content-Type`, or `Content-Length` — between "this record does not exist" and "you are not authorised to read this record" for any unauthorised caller. Verified by automated probes that compare responses across (real-unauthorised, fabricated-id) pairs for every role.
- **SC-004**: At least 99% of non-care-team-clinician `GET /records/{id}` rejections complete within **200 milliseconds** at the 99th percentile, measured at the API edge under a representative load.
- **SC-005**: At least 99% of audit entries are durably persisted within **1 second** of the access operation completing; the remaining ≤1% of attempts are refused with `503 service_unavailable` rather than served without an audit.
- **SC-006**: **Zero** occurrences in production where a `compliance_officer` response (`GET /access-log` or `GET /records/{id}/audit`) contains any clinical-content field (per the explicit forbidden-keys list in FR-019). Verified by an automated probe that walks every compliance-officer response across seeded scenarios and asserts the absence of every forbidden key.
- **SC-007**: **Zero** occurrences in production where a previously-appended clinical note is observed to have been edited or deleted (FR-012 append-only invariant).
- **SC-008**: **Zero** occurrences in production where an audit entry, once written, is observed to have been updated or deleted within its 7-year retention window (FR-015 and FR-017 invariants).
- **SC-009**: **Zero** occurrences in production where an unauthenticated request returns any record content, any clinical-note body, or any audit content.
- **SC-010**: **Zero** occurrences in production where a clinician reads or appends to a record they are not on the care team for; **zero** where a patient reads any record other than their own `assigned_record_id`; **zero** where a compliance officer reads any record's clinical content.
- **SC-011**: 100% of audit entries contain a valid `originating_ip_address` (IPv4 dotted-decimal or IPv6 hex notation).

## Assumptions

- **Authentication**: Users are authenticated by the host product's existing identity system (a HIPAA-compliant identity provider). This feature consumes an authenticated identity (the `user_id`, `display_name`, and `role`). Sign-up, sign-in, token issuance and refresh, password management, and all related flows are out of scope.
- **Role catalogue**: Exactly three roles in v1: `clinician`, `patient`, `compliance_officer`. A user holds exactly one role at a time.
- **Patient-record relationship**: Each user with role `patient` has a single `assigned_record_id` — the only record they are authorised to read. Guardian / delegate / minor-patient / advanced-directive flows are out of scope of v1.
- **Care-team data**: Care-team-membership data is supplied by the host product's care-team-management system, which is out of scope of this feature. The feature reads from a `care_team_memberships` table; on missing/stale rows, the system fails-closed (denies access).
- **Record creation**: Creating new patient records, deleting them, or modifying their core patient-demographic fields is out of scope of this feature. Records are populated by the host product's clinical-record-management system.
- **Append-only notes**: The user description's "append … cannot modify or delete existing notes" wording is normative. Once submitted, a clinical note cannot be edited or deleted through this feature. Amendments are by new note (the "addendum" practice).
- **Note structure**: Free-text `body` (1–8000 characters) plus a fixed `note_type` enum and an optional `encounter_date`. No templates, no structured fields, no terminology codes in v1.
- **Originating IP address capture**: Read from the HTTP request's remote address by default. If the system is behind a configured trusted reverse proxy, the right-most trusted IP in the `X-Forwarded-For` header is used. The trusted-proxy configuration is set at server startup; in v1 the PoC default is "no trusted proxies", meaning `X-Forwarded-For` is ignored unless explicitly enabled.
- **Audit retention floor**: 7 years (HIPAA §164.530(j)'s 6-year mandate plus a 1-year defensive margin). Enforcement is by code-path absence — no DELETE statement exists against the audit table.
- **Audit-write SLA**: 1 second (FR-016, SC-005). A synchronous-write design is implied; the audit entry is persisted in the same atomic operation as the access decision.
- **200ms 403 latency budget**: 200 milliseconds p99 for the non-care-team-clinician rejection path (FR-009, SC-004). Achieved by tight storage-layer write timeouts and indexed-lookup care-team-membership predicates.
- **Byte-equivalent unauthorised envelope**: A single fixed envelope used at every "you cannot see this" code path on `/records/{id}*` endpoints (FR-008), with pinned HTTP 403 status, body, `Content-Type`, and `Content-Length`. Transport-layer headers (`Date`, etc.) are out of scope of the byte-equivalence requirement.
- **Patient self-access is audited**: When a patient reads their own record or their own access log, the operation is audited (FR-013) — required by HIPAA §164.312(b) which mandates audit of all access events, including by the data subject.
- **Compliance access is audited**: A compliance officer's `GET /access-log` call is itself audited (recursive auditing).
- **`{id}` in URL paths is a record_id, not a patient identifier**: The `record_id` is an opaque internal system handle that is not personally identifying on its own. Patient demographics (name, date of birth, SSN) never appear in URL paths.
- **Time source**: All timestamps are UTC, ISO 8601, millisecond precision, explicit `Z` suffix.
- **No tamper detection on notes or audit entries**: Append-only is enforced by code-path absence. Out-of-band database tampering by a hostile operator is not defended against in v1.
- **No emergency-access (break-glass)**: No in-feature path for a clinician to bypass care-team gating in an emergency. Operational fallbacks are the host organisation's responsibility.
- **No notifications**: This feature emits no notifications.

## Out of Scope

- Authentication implementation (token issuance, refresh, revocation; sign-in UI).
- Identity / role assignment; care-team-roster management.
- Multi-role users; role inheritance; emergency-access (break-glass) overrides.
- Patient delegate / guardian / minor-patient flows.
- Editing or deleting clinical notes after submission; formal in-product addendum linkage between notes.
- Creating, modifying, or deleting patient records or their demographic fields.
- Modifying patient summary fields (allergies, key warnings, current medications).
- Full clinical encounter narratives; imaging; lab values in detail; mental-health-specific records; sexual-health-specific records; genetic data; social-care records.
- Prescribing, clinical decision support, computer-assisted diagnostics.
- Notifications (clinician-to-clinician, clinician-to-patient, push, email, SMS).
- Bulk operations (bulk note export, batch audit pulls beyond the `GET /access-log` filtered query).
- Tamper detection on audit entries beyond append-only-by-code-path-absence.
- Real-time SIEM alerting on suspicious access patterns.
- National-system integration; cross-organisational record sharing; health information exchanges.
- Subject access request (SAR) / HIPAA §164.524 right-of-access fulfilment workflow tooling.
- HIPAA breach notification workflow (§164.404).
- Encryption at rest / in transit — host-product concerns inherited from the deployment environment.
- Anonymisation / pseudonymisation for research use.
- Pagination cursor on `GET /access-log` beyond the `from`/`to`/`limit` filters in v1.

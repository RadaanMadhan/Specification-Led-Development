# Feature Specification: Hospital Clinical Record Access

**Feature Branch**: `012-hospital-clinical-records`
**Created**: 2026-05-17
**Status**: Draft — pending governance review (see notice below)
**Input**: User description: "Build a clinical record access feature for a hospital information system. Authenticated clinicians can read patient records and add new clinical notes. Only the patient's assigned care team can read or modify their records. Hospital administrators can read access logs but cannot read the clinical content of records. Every access event must be logged including which user accessed which record and when."

> ## ⚠ Governance notice (read before planning)
>
> This spec describes a record-access feature handling patient health information, in a regulated domain. Before any implementation work begins, the spec should be reviewed by:
>
> - The product owner (to confirm scope).
> - A clinical-safety officer or equivalent (to confirm the access-control model and the absence of an emergency-access path are appropriate for the host hospital's clinical workflows).
> - A legal / privacy / information-governance team (to confirm the audit fields, retention period, and patient-rights surface meet the regulatory regime the system operates under).
>
> The Assumptions section commits to conservative defaults (audit always on, retained at least 7 years; no break-glass access; no editing or deletion of clinical notes after submission). The governance review should validate that these defaults match the host organisation's policies, or flag where they need to be tightened. If any default is rejected, the relevant section of this spec should be revised before planning.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Clinician on the Care Team Reads a Patient's Record (Priority: P1)

A signed-in clinician (a doctor, nurse, pharmacist, or clinical administrator — the four clinical roles the feature recognises) who is on patient P's currently active care team needs to view P's record. They request the record by P's identifier and receive the patient summary: identifier, date of birth, name, allergies, key warnings, current medications, recent encounters, and the chronological list of clinical notes recorded for P (oldest first). The read produces one entry in an immutable audit log within 2 seconds.

**Why this priority**: Without this story, no clinical content can be viewed; it is the indispensable first slice and the trigger for every other interaction in the feature.

**Independent Test**: A test clinician with a recorded care-team-membership row for a test patient can request that patient's record by identifier and receive a record body with the patient's safety-relevant fields (identifier, date of birth, name, allergies, key warnings) at the top of the response, followed by the rest of the patient summary and the notes list. The audit log gets exactly one new entry recording the clinician's identity, their clinical role, the patient identifier, the timestamp, the operation type `read`, and the outcome `permitted`.

**Acceptance Scenarios**:

1. **Given** an authenticated clinician X with an active care-team-membership row `(X, P, episode_of_care_id)`, **When** they request P's record by identifier, **Then** the system returns the patient summary plus all clinical notes for P (chronological, oldest first); writes one audit entry within 2 seconds of the response; and renders the patient verification fields (identifier, date of birth, name) plus the clinical-safety fields (allergies, key warnings) at the top of the response payload.
2. **Given** an authenticated clinician X with **no** active care-team-membership row for P, **When** they request P's record, **Then** the system refuses access with a response that is byte-identical to the response for a patient identifier that does not exist (status code, body bytes, and length-related headers all identical); no clinical content is returned; one audit entry is written with outcome `denied`.
3. **Given** an authenticated clinician, **When** they request a record by an identifier that does not correspond to any patient in the system, **Then** the system returns the same byte-equivalent unauthorised response as scenario 2; one audit entry is written with outcome `not_found_or_denied`.
4. **Given** an unauthenticated request, **When** it reaches the system, **Then** the system rejects it at the authentication boundary before any patient identifier is dereferenced and **does not** write an audit entry.

---

### User Story 2 - Clinician on the Care Team Adds a Clinical Note (Priority: P1)

A clinician on patient P's care team needs to document a clinical interaction. They submit a clinical note against P's record: a non-empty free-text body, a note type chosen from a fixed list (progress, assessment, plan, observation, discharge summary), and an optional encounter date. The note is persisted, immediately visible on subsequent reads of P's record to anyone authorised to see the record, and recorded in an audit entry within 2 seconds. The note itself is **append-only** — once submitted, no clinician (including the author) can edit or delete it through this feature.

**Why this priority**: The note-addition write surface is the second of the two clinician actions in the user description. Without it, the system is read-only and cannot record new clinical observations.

**Independent Test**: A test clinician on a patient's care team can submit a clinical note with a non-empty body (within the allowed length) and a valid note type; the note appears in subsequent reads of the patient's record. The audit log gets one new entry with operation `add_note` and outcome `permitted`. Any attempt to edit or delete a previously-added note through any endpoint of this feature fails with no state change to the note.

**Acceptance Scenarios**:

1. **Given** an authenticated clinician X on patient P's care team, **When** they submit a clinical note with a valid body (1–8000 characters after trimming), a valid `note_type`, and optionally an `encounter_date` (date-only, not in the future), **Then** the system stores the note with `author_user_id = X`, the clinician's display name and role snapshotted at the time of writing, `created_at = now()`, the supplied `note_type` and `body`, and `encounter_date` defaulting to today's date if omitted. The system makes the note visible on subsequent reads of P's record. One audit entry is written within 2 seconds with operation `add_note`, the new note's identifier, and outcome `permitted`.
2. **Given** an authenticated clinician X **not** on P's care team, **When** they attempt to add a note to P's record, **Then** the system refuses with the byte-equivalent unauthorised response; no note is created; one audit entry is written with operation `add_note` and outcome `denied`.
3. **Given** an authenticated clinician on P's care team, **When** they attempt to add a note with an empty body, a body exceeding 8000 characters, an invalid `note_type` (not in the fixed list), or a malformed or future `encounter_date`, **Then** the system rejects the submission with a field-level error response listing every offending field; no note is created; no audit entry is written.
4. **Given** any previously-submitted note, **When** any caller (the author, another clinician, an administrator, or anyone else) attempts to edit or delete it through any endpoint of this feature, **Then** the system refuses the action (no such endpoint exists in the feature's surface); the note is unchanged; no audit entry is written for the refused mutation attempt.

---

### User Story 3 - Hospital Administrator Reads Access Logs Without Clinical Content (Priority: P1)

A hospital administrator needs to investigate access patterns for a specific patient — for compliance review, complaint investigation, or routine audit. They request the access log for a patient by identifier and receive the chronological list of access events recorded for that patient (every read attempt, every note addition, every denied attempt). The administrator's response **must not contain any clinical content**: not the patient summary, not any note body, not any allergy or warning detail, not any encounter narrative, not any medication name. They receive only access metadata: who accessed what, when, with what outcome.

**Why this priority**: This is the explicit "administrators can read access logs but cannot read the clinical content" constraint from the user description. Without it, either the audit surface doesn't exist (operational gap) or it leaks clinical content (privacy failure).

**Independent Test**: A test administrator can look up the audit log for any patient and receive the access-event list. The response is verified to contain **none** of the patient-summary fields and **none** of the note-content fields. Only the audit-event fields appear in the response.

**Acceptance Scenarios**:

1. **Given** an authenticated administrator and a patient identifier with at least one recorded access, **When** they request the access log for that patient, **Then** the system returns the full chronological list of audit entries, each containing the accessor's user identifier, the accessor's display name snapshotted at the time of access, the accessor's role at the time of access, the timestamp, the operation type (one of `read`, `add_note`), the outcome (`permitted`, `denied`, or `not_found_or_denied`), the authorisation basis used, and the note's identifier (only when the operation was a successful note addition). The response contains **none** of: the patient summary fields, note bodies, allergy details, warning details, medication details, or encounter narratives.
2. **Given** an authenticated administrator, **When** they attempt to read a *patient record* (not the access log — i.e., use the record-read endpoint), **Then** the system refuses with the byte-equivalent unauthorised response: administrators are not members of any patient's care team and the record-read endpoint is gated by care-team membership.
3. **Given** an authenticated administrator, **When** they attempt to add a clinical note, **Then** the system refuses with the byte-equivalent unauthorised response; no note is created; one audit entry is written with operation `add_note` and outcome `denied`.
4. **Given** an authenticated clinician (not an administrator), **When** they attempt to call the access-log endpoint, **Then** the system refuses with the byte-equivalent unauthorised response: the access-log endpoint is administrator-only, and its existence is not signalled to clinicians.

---

### Edge Cases

- **Concurrent reads or note additions on the same patient**: each access produces its own audit entry; ordering follows recorded timestamps. Two notes added at near-simultaneous times both succeed and both appear in the chronological list.
- **Care-team membership revocation mid-session**: the membership predicate is evaluated on every request, so a revoked clinician cannot read or add notes after the revocation takes effect. The audit log captures the now-denied attempts.
- **Administrator's content-blindness**: enforced at the response-construction layer — the administrator response builder is a separate code path from the clinician response builder, and shares no construction code with the patient-summary or note-content rendering paths.
- **Audit-write timing budget breach** (the 2-second budget defined in the requirements): the access or note addition is rolled back and the system returns a service-unavailable response. No state change occurs and no audit entry is written for that attempt. The `add_note` path is especially careful: the note's persistence and the audit entry's persistence are atomic, so a contended commit rolls both back.
- **An administrator requests audit entries for a patient identifier that does not exist**: the system returns a response byte-equivalent to "patient exists but has no recorded accesses" — administrators cannot distinguish between the two via the response.
- **An administrator's role is downgraded to clinician mid-shift**: their subsequent access-log requests are refused; any audit entries they generated previously as an administrator preserve their role snapshot accurately.
- **A note's body contains markdown, HTML-like text, or line breaks**: stored verbatim; rendered as plain text in subsequent reads (the host UI is responsible for any safe rendering). The system never interprets markup.
- **A note's `encounter_date` is in the future**: rejected with a field-level error (future encounter dates have no clinical meaning; only past or today's date is accepted).
- **Notes are append-only by design**: there is no endpoint in this feature's surface that updates or deletes a clinical note. The audit log records the addition once; subsequent reads see the note unchanged. If an addendum is needed clinically, the workflow is to add a new note (the clinical practice known as "addendum by new note"); a formal in-product link or alias between notes is not built in v1.
- **Patient identity merge or admission/discharge changes**: out of scope for this feature; handled by the host product's patient-administration system.
- **An unauthenticated request reaches the system**: rejected at the authentication boundary; no audit entry written for that attempt.
- **No emergency-access (break-glass) path in v1**: a clinician who needs to view a record they are not on the care team for must obtain that access through the host product's operational fallback (re-assignment to the care team by clinical leadership, or paper records, or an information-governance-mediated manual review). The audit log still captures any denied attempts to access the record without care-team membership.

## Requirements *(mandatory)*

### Functional Requirements

#### Authentication, identity, and roles

- **FR-001**: All requests to this feature MUST be made by an authenticated user. Unauthenticated requests MUST be rejected at the authentication boundary before any patient identifier is dereferenced and before any audit entry is written.
- **FR-002**: The system MUST resolve every authenticated request to (a) a `user_id` (an opaque identifier from the host product's identity system), (b) a `display_name`, and (c) a `user_role` from the v1 catalogue: `doctor`, `nurse`, `pharmacist`, `clinical_admin`, `hospital_administrator`. The first four are *clinical* roles; `hospital_administrator` is the administrator role described in the user description. These three pieces of identity are read from the host product's identity context, never from the request payload.

#### Patient-identifier handling

- **FR-003**: Patient identifiers (an NHS number, MRN, or any other identifier that distinguishes one patient from another) MUST NOT appear in the path component of any URL exposed by this feature. The identifier MUST be supplied in the request body, or in a request parameter that is explicitly redacted from web-server access logs. This is to prevent unintended capture of patient identifiers in web-server access logs, browser histories, referrer headers, or screenshots.

#### Authorisation — care-team gating for clinical access, role-only for the administrator endpoint

- **FR-004**: A clinical-role caller (one of `doctor`, `nurse`, `pharmacist`, `clinical_admin`) MAY read a patient's record and MAY add a clinical note to that patient's record **if and only if** there exists an active care-team-membership record linking the caller's `user_id` to the patient's identifier for an active episode of care. The membership predicate MUST be evaluated on every request, before any clinical content is returned and before any note is persisted. No role-based override grants access outside this rule. There is no emergency-access (break-glass) path in v1.
- **FR-005**: A `hospital_administrator` caller MAY read the access log for any patient. They MUST NOT be able to read patient summaries, note bodies, allergies, warnings, medications, encounter narratives, or any other clinical content through any endpoint of this feature, regardless of the patient's care-team configuration.
- **FR-006**: When the authorisation rule (FR-004 or FR-005) denies access for the record-read or note-addition endpoint, the system MUST refuse with a response that is **byte-identical** to the response for a patient identifier that does not exist. Specifically, the HTTP status code, response body bytes, `Content-Type` header, and `Content-Length` header MUST all be identical across the two cases. This single shared unauthorised envelope covers: a clinician not on the patient's care team; a hospital administrator attempting to access clinical content; a non-administrator attempting the access-log endpoint; and any of the above against a patient identifier that does not exist.

#### Patient record content and structure

- **FR-007**: A successful patient-record read MUST return a fixed-shape response with the following ordering, top to bottom: patient identifier; date of birth; name; allergies; key warnings; current medications; recent encounters (chronological, most-recent-first); the count of clinical notes recorded against the patient; the chronological list of clinical notes (oldest first). This ordering is enforced by a single response-builder function so the safety-relevant fields appear first.
- **FR-008**: The patient summary fields exposed by a record read are exactly: a patient identifier (opaque string), a date of birth (date-only), a name (string), a list of allergies (each with a substance name, severity tag, and free-text notes), a list of key warnings (each with a category tag and free-text), a list of current medications (each with name, dose, frequency), and a list of recent encounters (each with encounter date, encounter type, and a short summary string). No other patient demographics, no contact information, no insurance / financial information, no full clinical-encounter narratives, no imaging, no lab values in detail, no mental-health-specific records, no sexual-health-specific records, no genetic data, and no social-care records appear in this feature's responses. These are all out of scope.

#### Clinical-note addition (the v1 write surface)

- **FR-009**: A clinician on a patient's care team MAY submit a clinical note via the note-addition endpoint. The request body MUST include: the patient's identifier (string), a `body` (string, length between 1 and 8000 characters after trimming surrounding whitespace, non-empty after trimming), a `note_type` (one of the fixed values `progress`, `assessment`, `plan`, `observation`, `discharge_summary`), and an optional `encounter_date` (date-only, format `YYYY-MM-DD`, must not be in the future; defaults to today's date in UTC if omitted from the request). Submissions violating any of these constraints MUST be rejected with a field-level error response listing every offending field at once.
- **FR-010**: On successful addition, the system MUST persist the note with the following fields: an opaque `note_id`; the patient identifier; the `author_user_id` (taken from the authenticated caller); the `author_display_name` snapshotted at the time of the addition (so subsequent renames of the user in the host product do not retroactively change the historical note); the `author_role` snapshotted at the time of the addition; `created_at` set to the current time in UTC, ISO 8601 format with millisecond precision and an explicit `Z` suffix; the `note_type`; the `body`; and the `encounter_date` (defaulting to the date portion of `created_at` if not supplied). The system MUST return the new note's `note_id` to the author in the response.
- **FR-011**: Clinical notes MUST be **append-only**: there MUST be no endpoint, no role, and no code path in this feature that can update or delete an existing clinical note. Subsequent reads return the note exactly as written. Clinical amendments are achieved by adding a new note (the "addendum" practice); no in-product parent-child linkage between notes is built in v1.

#### Audit log (always-on, immutable, 2-second budget, ≥7-year retention)

- **FR-012**: For every clinical-record access attempt (a record read, a note addition, or an access-log read) and regardless of outcome (`permitted`, `denied`, or `not_found_or_denied`), the system MUST write **exactly one** new audit entry. There MUST NOT be any successful state change without a matching audit entry, and there MUST NOT be any audit entry without a matching attempted access.
- **FR-013**: Each audit entry MUST contain at minimum the following fields: the `user_id` of the user making the access (the accessor); the `user_display_name` of the accessor snapshotted at the time of the access; the `user_role` of the accessor snapshotted at the time of the access (one of the five values listed in FR-002); the `patient_id` as presented in the request; a `timestamp` (UTC, ISO 8601, millisecond precision, explicit `Z` suffix); an `access_type` (one of `read` for a record read, `add_note` for a note addition, `list_audit` for an administrator's access-log read); the `note_id` (an opaque string) **only** when `access_type = "add_note"` and the outcome was `permitted`; the `outcome` (one of `permitted`, `denied`, `not_found_or_denied`); and the `authorisation_basis` used (one of `care_team_member`, `not_care_team_member`, `patient_not_found`, `administrator_role`).
- **FR-014**: Audit entries MUST be **immutable**: there MUST be no endpoint, no role (including `hospital_administrator`), and no code path of this feature that can update or delete an existing audit entry. The deletion of any other data in the system (e.g., a hypothetical patient record removal — out of scope, but if it occurred) MUST preserve the audit entries.
- **FR-015**: Every audit entry MUST be durably persisted within **2 seconds** of the access operation completing. If the audit write would exceed the 2-second budget (under storage contention or transient failure), the access itself MUST be rolled back and the system MUST return a `service unavailable` response; no record content MUST be returned and no note MUST be persisted in that case. Under no circumstances may a record be observed by a clinician, or a note added, without a matching audit entry.
- **FR-016**: Audit entries MUST be retained for at least **7 years** from the date of the entry. This retention floor is a conservative healthcare default chosen to cover the audit-log retention requirements of major healthcare regulatory regimes; the host organisation's specific jurisdiction may impose a longer floor, which this feature accommodates by setting the in-feature floor at 7 years and the deletion path absent. There MUST be no code path in this feature that deletes audit entries within the retention window.

#### Administrator endpoint and content-blindness

- **FR-017**: The system MUST expose an administrator-only endpoint that returns, for a given patient identifier, the chronological list of audit entries recorded for that patient. The endpoint MUST be accessible **only** to callers with `user_role = "hospital_administrator"`. Non-administrator callers MUST receive the byte-equivalent unauthorised response (FR-006). The endpoint accepts the patient identifier in the request body (FR-003).
- **FR-018**: The administrator's response MUST contain **no** clinical-content fields. Specifically, the response MUST NOT contain any field named (or carrying the data of) `body`, `note_body`, `content`, `note_content`, `allergies`, `key_warnings`, `current_medications`, `recent_encounters`, `encounters`, `summary`, `name`, `patient_name`, `date_of_birth`, or `dob`. The only allowed fields per audit event are those enumerated in FR-013. This invariant MUST be enforced at the response-construction layer, such that the administrator response-builder is a separate code path that shares no construction code with the patient-summary or note-content rendering paths.

#### Clinical-safety guards (response-layout-level)

- **FR-019**: The patient-record-read response MUST place the patient identifier and date of birth at the very top of the response (FR-007), with allergies and key warnings rendered immediately after, before any other clinical information. The intent is to support routine patient verification by the clinician (confirming they are looking at the correct patient's record) and to surface clinical-safety information prominently so it cannot be missed in a quick read.
- **FR-020**: The patient-record-read response MUST include a count of the clinical notes recorded against the patient, placed in the response payload after the safety fields and before the notes themselves. This is a quick-orientation field for the clinician.

### Key Entities *(include if feature involves data)*

- **User**: A signed-in person (a clinician or a hospital administrator). Carries: `user_id` (opaque identifier supplied by the host product's identity system), `display_name` (the user's name as it should appear in audit responses), and `user_role` (one of the five values: `doctor`, `nurse`, `pharmacist`, `clinical_admin`, `hospital_administrator`). The role is read on every request from the host product's identity context.
- **Patient**: A subject whose clinical record is held by the system. Identified by `patient_id` (an opaque string supplied by the host product — typically an NHS number, an MRN, or an equivalent — but treated as opaque by this feature).
- **Care-Team Membership**: An assertion by the host product that a clinician X is currently part of patient P's care team for an active episode of care. Identified by the tuple `(clinician_user_id, patient_id, episode_of_care_id)`. Carries a `status` (`active` or `ended`) and a date range. This feature reads care-team-membership rows on every record-access request; it does not modify them (the host product's care-team-management system is responsible for populating them).
- **Patient Summary**: A per-patient denormalised view including the patient's allergies, key warnings, and current medications. Snapshot for v1 — modifications to these fields are out of scope for this feature.
- **Encounter**: A chronological record of a clinical encounter (encounter date, encounter type, short summary string).
- **Clinical Note**: An append-only note about a patient. Carries: `note_id`, `patient_id`, `author_user_id`, `author_display_name` snapshot, `author_role` snapshot, `created_at` (UTC ISO 8601), `note_type` (one of the fixed values listed in FR-009), `body` (1–8000 characters), `encounter_date` (date-only).
- **Audit Entry**: An immutable append-only record of one access event. Carries the fields enumerated in FR-013.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of clinical-record access attempts (record reads, note additions, and access-log reads, whether permitted, denied, or not-found-or-denied) have a corresponding audit entry. Verified by reconciling endpoint logs against the audit table on a periodic basis.
- **SC-002**: **Zero** occurrences in production where a clinical-record access succeeds without a matching audit entry, or where an audit entry exists without a matching attempted access.
- **SC-003**: **Zero** occurrences in production where the response to a clinician's record-read or note-addition attempt distinguishes between "this patient does not exist" and "you are not on this patient's care team" — i.e., the FR-006 byte-equivalence holds in production. Verified by automated probes that compare responses across (real-non-care-team, real-other-team, fabricated-identifier) triples.
- **SC-004**: **Zero** occurrences in production where an unauthenticated request returns any patient data, any clinical-note body, or any audit content.
- **SC-005**: **Zero** occurrences in production where a patient identifier appears in a URL path, web-server access log entry, browser history record, or referrer header logged by this feature's components.
- **SC-006**: **Zero** occurrences in production where a `hospital_administrator` response contains any clinical-content field (per the explicit forbidden-keys list in FR-018). Verified by an automated probe that walks every administrator response recursively and asserts the absence of every forbidden key.
- **SC-007**: **Zero** occurrences in production where a previously-recorded clinical note is observed to have been edited or deleted within its retention window (the FR-011 append-only invariant).
- **SC-008**: **Zero** occurrences in production where an audit entry, once written, is observed to have been updated or deleted within its 7-year retention window (the FR-014 immutability and FR-016 retention invariants).
- **SC-009**: At least 99% of audit entries are durably persisted within 2 seconds of the access operation completing; the remaining ≤1% of attempts are refused with a `service unavailable` response rather than served without an audit.
- **SC-010**: At least 95% of intended-care-team lookups (a clinician on the patient's care team enters the correct patient identifier) complete in under 3 seconds from request to response, on a representative clinical workload.
- **SC-011**: At least 90% of clinicians report (via post-launch survey) that the note-addition flow takes ≤30 seconds for a typical progress note, from opening the form to seeing the confirmation.

## Assumptions

- **Authentication**: Users are authenticated by the host product's existing identity system. This feature consumes an authenticated identity (the `user_id`, `display_name`, and `user_role`). It does not introduce sign-up, sign-in, password-management, or token-issuance flows.
- **Role catalogue**: Exactly five roles in v1: `doctor`, `nurse`, `pharmacist`, `clinical_admin`, `hospital_administrator`. The first four are clinical; the fifth is the administrator role with audit-only access. This catalogue is mirrored from the host product; this feature does not manage role assignment.
- **Care-team data**: Care-team-membership data is supplied by the host product's care-team-management system, which is out of scope for this feature. v1 reads from a `care_team_memberships` table; on a missing or stale row, the system fails closed (denies access).
- **No emergency-access (break-glass)**: There is no in-feature path for a clinician to bypass care-team gating in an emergency. Operational fallbacks (re-assignment to the care team by clinical leadership; paper records; information-governance-mediated review) are the host organisation's responsibility. The governance review (see notice at top) must validate that this fallback strategy is adequate for the hospital's workflows.
- **Append-only notes**: The user description's "add new clinical notes" verb implies append-only semantics. Once submitted, a note cannot be edited or deleted through this feature. Amendments are by new note (the "addendum" practice). Formal addendum-linking between notes is out of scope for v1.
- **Note structure**: Free-text body (1–8000 characters) plus a fixed `note_type` enum (`progress`, `assessment`, `plan`, `observation`, `discharge_summary`) and an optional `encounter_date`. No templates, no structured fields, no codes (ICD/SNOMED) in v1.
- **Patient identifier scheme**: One opaque identifier per patient. This feature treats it as a string; it does not generate identifiers, validate identifier format, or interpret the identifier scheme.
- **Patient record content scope**: A minimal patient summary view only. Full clinical notes (other than those added via this feature), imaging, full lab values, mental-health records, sexual-health records, genetic data, and social-care records are out of scope for v1. Each of those would require its own feature with its own clinical-safety case.
- **Audit-retention floor**: 7 years (a conservative healthcare default). The host organisation's specific regulatory regime may impose a longer requirement, in which case the in-feature floor remains at 7 years and the operational retention scheduling (outside this feature) provides the additional duration.
- **Audit-write timing budget**: 2 seconds. Chosen to be loose enough to permit a synchronous-write design (the audit entry persisted in the same atomic operation as the access decision) but tight enough to satisfy clinical workflow expectations for responsiveness.
- **Byte-equivalent unauthorised envelope**: A single fixed envelope used at every "you cannot see this" code path (FR-006), with pinned status code, body, `Content-Type`, and `Content-Length` headers. Transport-layer headers (`Date`, etc.) are out of scope of the byte-equivalence requirement.
- **No patient identifier in URL paths**: Both record-access endpoints take the identifier in the request body (FR-003).
- **No tamper detection on clinical notes or audit entries**: Append-only is enforced by code-path absence (no edit/delete endpoints, no UPDATE/DELETE SQL paths in the storage layer). Out-of-band database tampering by a hostile operator is not defended against in v1.
- **No notifications, alerts, or messaging**: This feature emits no notifications, no clinician-to-clinician messages, no patient-facing alerts.
- **Time source**: UTC, ISO 8601, millisecond precision, explicit `Z` suffix on every timestamp.

## Out of Scope

- Authentication implementation (token issuance, refresh, revocation, sign-in UI, password management).
- Identity / role assignment / care-team-roster management (host product features).
- Multi-role users; role inheritance; emergency-access (break-glass) overrides.
- Patient-facing endpoints (patient views own record / own access log) — a related downstream feature enabled by the audit data this feature stores, but not built here.
- Editing or deleting clinical notes after submission; formal in-product addendum linking between notes.
- Modifying the patient summary fields (allergies, key warnings, current medications) — these are read-only views fed by other host-product features.
- Full clinical notes from outside this feature, imaging, lab values, mental-health records, sexual-health records, genetic data, social-care records — each would require its own clinical-safety case and its own spec.
- Prescribing, prescribing safety checks, clinical decision support, computer-assisted diagnostics.
- Notifications (clinician-to-clinician, clinician-to-patient, push, email, SMS).
- Bulk operations (bulk note export, batch audit pulls beyond per-patient queries).
- Tamper detection on the audit log (e.g., chained-hash); real-time SIEM-style alerting on suspicious access patterns.
- National-system integration; cross-organisational record sharing.
- Department-scoped administrator role (the administrator role is system-wide in v1).
- Patient identity merging or splitting.
- Subject access request (patient right-of-access) workflow tooling.
- Anonymisation or pseudonymisation for research use.
- Encryption at rest / in transit — these are host-product concerns inherited from the deployment environment.

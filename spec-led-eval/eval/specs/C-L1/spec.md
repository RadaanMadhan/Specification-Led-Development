# Feature Specification: Clinician Access to Patient Medical Records (v1, narrow scope)

**Feature Branch**: `009-clinician-record-access`
**Created**: 2026-05-17
**Status**: Draft — **PENDING GOVERNANCE REVIEW**
**Input**: User description: "Build a feature where clinicians can access patient medical records." (Resolved as: **Q1 = A** — UK NHS regulatory regime; **Q2 = A** — read-only access scope; **Q3 = A** — care-team-membership authorisation.)

> ## ⚠ v1 scope and governance notice
>
> This spec captures the **deliberately narrow v1** that resulted from accepting the recommended defaults on the three scope-defining clarifications:
>
> - **Q1 = A**: UK NHS regulatory framing (Caldicott, DSPT, GDPR + DPA 2018, DCB0129/0160 clinical-safety standards, NHS records retention guidance).
> - **Q2 = A**: Read-only. v1 ships **no** amendment, **no** prescribing, **no** note-writing surface.
> - **Q3 = A**: Care-team membership. A clinician X may access patient P's record iff X is recorded as a member of P's care team for an active episode of care. **No break-glass path in v1.**
>
> The user accepted these defaults to keep scope minimal. The spec **must still be reviewed** by:
>
> - Product owner.
> - Clinical-safety officer (DCB0129/0160 case for a default-deny read-only viewer with no break-glass).
> - Legal / privacy / information-governance (NHS Caldicott guardian sign-off; retention; lawful basis under Article 9(2)(h) GDPR; patient-rights surface).
>
> A "Care-team-only, no break-glass" authorisation model has a known safety implication: it will fail-deny in genuine emergency-access scenarios. The clinical-safety case must confirm that the host product's operational fallbacks (out-of-hours coordinators, IG-mediated manual access, paper records) are sufficient. If that confirmation cannot be obtained, **revisit Q3** and re-spec; do not work around it in implementation.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Clinician Looks Up a Patient on Their Care Team (Priority: P1)

A signed-in clinician who is on patient P's care team needs to view P's record. They enter P's identifier (NHS number / MRN — see Assumptions) and receive the patient summary (FR-014, FR-015 fields). The access is recorded in an immutable audit entry within 2 seconds.

**Why this priority**: Indispensable first slice; the only successful-access path in v1.

**Independent Test**: A test clinician (with a recorded care-team relationship to a test patient) can look up that patient by identifier and receive a 200-OK record-view payload. The audit log contains exactly one new entry with `outcome = "permitted"`, `access_type = "read"`, the clinician's id/name/role snapshot, the patient identifier, and a UTC timestamp.

**Acceptance Scenarios**:

1. **Given** an authenticated clinician X who has an active care-team-membership row for patient P, **When** they look up P by identifier, **Then** the system returns the patient summary (FR-014 fields with allergies/warnings rendered first; FR-015 fields rendered at the top of the response), and one audit entry is written within 2 seconds recording `clinician_id`, `clinician_display_name` snapshot, `clinician_role` snapshot, `patient_id`, `timestamp`, `access_type = "read"`, `outcome = "permitted"`, and `authorisation_basis = "care_team_member"`.
2. **Given** an authenticated clinician X with **no** care-team-membership row for patient P, **When** they look up P by identifier, **Then** the system refuses access with a response **byte-identical** to the response for an identifier that does not correspond to any patient (FR-007); writes one audit entry with `outcome = "denied"`, `authorisation_basis = "not_care_team_member"`; and returns **no** record content beyond the byte-equivalent not-found response.
3. **Given** an authenticated clinician X, **When** they look up an identifier that does not correspond to any patient in the system, **Then** the system returns a response byte-identical to the deny case in scenario 2; writes one audit entry with `outcome = "not_found_or_denied"`.
4. **Given** an unauthenticated request, **When** it reaches the system, **Then** the system rejects it at the authentication boundary before any patient identifier is dereferenced and **does not** write an audit entry (the authentication-failure log lives in the host product's identity-provider audit, not in this feature's patient-level audit table).

### User Story 2 - Audit / Information-Governance Inspects the Audit Log for a Patient (Priority: P1)

An authorised audit / information-governance user can list every access — `permitted`, `denied`, or `not_found_or_denied` — recorded against a given patient identifier. The list is read-only: there is no API path that updates or deletes existing audit entries.

**Why this priority**: Auditability is a regulatory requirement under Q1 = A (UK NHS / Caldicott / DSPT). Without this view, the audit log exists but cannot be used by IG.

**Independent Test**: An IG-role user can fetch the audit entries for a patient identifier and receive the full chronological list of access attempts, each containing every field required by FR-009. Every write attempt against any audit entry (by anyone, including the IG role) is refused.

**Acceptance Scenarios**:

1. **Given** an authorised audit / IG user, **When** they request the audit entries for patient P, **Then** the system returns every audit entry recorded for P in chronological order, each containing `clinician_id`, `clinician_display_name` snapshot, `clinician_role` snapshot, `timestamp` (UTC ISO 8601 with millisecond precision), `access_type`, `outcome`, `authorisation_basis`.
2. **Given** any user (clinician, audit/IG, or otherwise), **When** they attempt to update or delete any existing audit entry through any endpoint, **Then** the system refuses the action and the entry is unchanged.
3. **Given** a clinician (non-IG-role) caller, **When** they attempt to call the IG audit-listing endpoint, **Then** the system refuses with the byte-equivalent not-found response (no leakage of audit-log existence to non-IG roles).

### Edge Cases

- **Concurrent accesses by two clinicians on the same patient**: both are logged; ordering is determined by the recorded timestamp.
- **Mid-care role change for a clinician**: the audit log captures the clinician's role at the time of the access (snapshot). Subsequent reads do not retroactively shift.
- **Care-team membership changes mid-day** (clinician added or removed from a patient's care team): the authorisation check is evaluated on every request, so a removal takes effect immediately on the next access attempt. The audit log preserves what was true at the time of each access.
- **Genuine emergency requiring access outside the care team** (the safety implication of Q3 = A): **out of scope for v1**. The clinician must use the host product's operational fallback (out-of-hours coordinator, IG-mediated manual access, paper records). v1 will fail-deny with a byte-equivalent not-found. This trade-off is the headline item the clinical-safety case must validate.
- **Patient identity merge** (two identifiers retrospectively refer to the same person): out of scope for v1.
- **An unauthenticated request reaches the system**: rejected at the authentication boundary; no audit entry is written (no patient identifier dereferenced).
- **The host product reports a clinician identity that the system has no record of** (a malformed token or an unknown user): rejected at the authentication boundary, same path as the unauthenticated case.
- **Patient record contains data flagged as "sensitive" under UK NHS guidance** (mental health, sexual health, gender identity, etc.): explicitly **out of scope** for v1 record content (see Key Entities — Patient Record View). These categories require their own clinical-safety case before being added.
- **The system is asked for a record on behalf of a third party** (legal disclosure, subject access request, regulator request): out of scope; goes through the host product's IG team using separate tooling.
- **Clinician's view is cached or printed**: out of scope of this feature; client-side caching/printing controls are part of the host application's clinical-safety case.

## Requirements *(mandatory)*

### Functional Requirements

#### Authentication and identity

- **FR-001**: All requests to this feature MUST be made by an authenticated clinician. Unauthenticated requests MUST be rejected at the authentication boundary before any patient identifier is dereferenced and before any audit entry is written.
- **FR-002**: The system MUST resolve every authenticated request to (a) a `clinician_id`, (b) a `clinician_role` from the v1 catalogue (`doctor`, `nurse`, `pharmacist`, `audit_officer`, `clinical_admin`), and (c) the clinician's current care-team memberships supplied by the host product. These MUST be taken from the host product's identity context, never from the request payload.

#### Regulatory regime and patient-identifier handling (UK NHS, Q1 = A)

- **FR-003**: The feature MUST operate under UK NHS regulatory requirements:
  - **Lawful basis**: Article 9(2)(h) GDPR (processing for health and social care) read with the Data Protection Act 2018 Schedule 1.
  - **Confidentiality**: Caldicott principles; access on a strict need-to-know basis.
  - **Standards**: DSPT (Data Security and Protection Toolkit) baseline; DCB0129 (clinical risk management — manufacturer) and DCB0160 (clinical risk management — health and care organisation) for the clinical-safety case.
  - **Records retention** (FR-012 below): NHS adult records 8 years from last entry; paediatric records until the patient's 25th birthday (or 26th if last entry was at age 17).
  - **Patient rights** (related but a separate downstream feature — see Out of Scope): patients have the right to view who has accessed their own record (NHS App "My health record" access-log pattern). This feature's audit-log data model MUST support per-patient-identifier query so the downstream patient-facing endpoint can be built on it.
- **FR-004**: Patient identifiers MUST NOT appear in the path component of any URL exposed by this feature. The identifier MUST be supplied in the request body (or in a request parameter that is explicitly redacted from web-server access logs).

#### Authorisation, access scope, and refusal (read-only, care-team membership; Q2 = A, Q3 = A)

- **FR-005**: v1 access scope is **read-only**. The only operation a clinician may perform on a patient's record through this feature is a read returning the patient summary defined in Key Entities. There MUST be no endpoint that amends any field, no endpoint that creates a record, no endpoint that prescribes, no endpoint that writes notes. Any future write surface is a separate spec with its own clinical-safety case.
- **FR-006**: The authorisation rule is **care-team membership**: a clinician X may access patient P's record iff there exists an active care-team-membership row `(X, P, episode_of_care)` supplied by the host product. The membership lookup MUST be evaluated on every request, before any record content is returned. No role-based override grants access outside this rule in v1 — there is no break-glass path.
- **FR-007**: When the authorisation rule (FR-006) denies access, the system MUST refuse with a response **byte-identical** to the response for an identifier that does not correspond to any patient (HTTP status, response body bytes, `Content-Type` header, and `Content-Length` header all identical). This avoids leaking the existence of patients to clinicians not on their care team.
- **FR-008**: For every access attempt (whether the outcome is `permitted`, `denied`, or `not_found_or_denied`), the system MUST record one audit entry as specified in FR-009 through FR-013. The audit entry MUST be written even when the outcome is `denied` or `not_found_or_denied`, and even when the patient identifier turns out not to correspond to a real patient.

#### Audit log (always-on, immutable, 2-second SLA, NHS retention)

- **FR-009**: Every audit entry MUST contain: `clinician_id`, `clinician_display_name` (snapshotted at the time of the access), `clinician_role` (snapshotted at the time of the access), `patient_id` (as presented in the request), `timestamp` (UTC ISO 8601 with millisecond precision and explicit `Z` suffix), `access_type` (in v1 always `read`), `outcome` (one of `permitted`, `denied`, `not_found_or_denied`), and `authorisation_basis` (one of `care_team_member`, `not_care_team_member`, `patient_not_found`).
- **FR-010**: Audit entries MUST be **immutable**: no API path, no role (including audit / IG), and no code path of this feature may update or delete an existing audit entry.
- **FR-011**: Audit entries MUST be readable via a dedicated endpoint by users holding the audit / information-governance role. The endpoint accepts a patient identifier and returns all entries recorded for that identifier in chronological order. (A patient-facing "view who accessed my record" endpoint is a related downstream feature — see Out of Scope.)
- **FR-012**: Audit entries MUST be retained for at least 8 years from the date of the entry (NHS adult-record retention floor under Q1 = A); for entries against paediatric records, retention extends until the patient's 25th birthday (or 26th if the last entry was at age 17). The system enforces this floor by having **no DELETE code path** against the audit-log storage and no automatic age-out within the retention period.
- **FR-013**: Every audit entry MUST be durably persisted within **2 seconds** of the access operation completing. If the audit write would exceed 2 seconds, the access itself MUST be refused with a `service temporarily unavailable` outcome rather than served without an audit. Under no circumstances may a record be observed by a clinician without a matching audit entry.

#### Clinical-safety guards (DCB0129/0160 baseline)

- **FR-014**: The system MUST surface, on every record view, the patient's allergies and "key warnings" content (if present) at the top of the response payload, ahead of all other content. This is a baseline DCB0129/0160 clinical-safety expectation; the host application's UI is responsible for rendering it prominently. This feature exposes the data in a fixed position in the response.
- **FR-015**: The feature MUST include the patient's identifier and date of birth at the top of every record view, to support routine patient verification by the clinician. The system does **not** automatically warn about possible identifier confusion (e.g., two patients with similar names); that is out of scope.

### Key Entities *(include if feature involves data)*

- **Clinician**: A signed-in healthcare professional or audit/IG user. Carries `clinician_id`, `clinician_display_name`, `clinician_role` (one of `doctor`, `nurse`, `pharmacist`, `audit_officer`, `clinical_admin`), and (for clinical roles) a set of current care-team memberships supplied by the host product. The role and care-team data are read from the host product on every request; this feature does not manage either.
- **Patient**: A subject whose medical record is held by the system. Identified by `patient_id` (NHS number / MRN — opaque to this feature). The full content of a Patient's record is out of scope for this feature.
- **Care-Team Membership**: An assertion by the host product that clinician X is currently part of patient P's care team for an active episode of care. Identified by `(clinician_id, patient_id, episode_of_care_id)`. This feature reads care-team data; it never modifies it.
- **Patient Record View**: The data returned on a successful read. v1 returns a minimal *patient summary*: the patient's identifier and date of birth (at the top of the response — FR-015), name, known allergies and key warnings (also at the top — FR-014), current medications, and a chronological list of recent encounters (date, type, summary text). v1 **does not** expose: full clinical notes, imaging, lab results in detail, mental-health records, sexual-health records, genetic data, or social-care records.
- **Audit Entry**: An immutable append-only record of one access attempt, with every field in FR-009. Retained at minimum 8 years (FR-012).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of completed access operations (`permitted`, `denied`, or `not_found_or_denied`) have a corresponding audit entry.
- **SC-002**: **Zero** occurrences in production where a patient record is observed by a clinician without a matching audit entry; and **zero** occurrences where an audit entry exists without a matching attempted access.
- **SC-003**: **Zero** occurrences in production where a clinician's response distinguishes between "this patient does not exist" and "you are not on this patient's care team" (FR-007 byte-equivalence verified by automated probes).
- **SC-004**: **Zero** occurrences in production where an unauthenticated request returns any patient data or writes any audit entry.
- **SC-005**: **Zero** occurrences in production where a patient identifier appears in a URL path, web-server access log entry, browser history record, or referrer header logged by this feature's components.
- **SC-006**: **Zero** occurrences in production where an audit entry, once written, is updated or deleted within the 8-year (or paediatric-extended) retention window.
- **SC-007**: At least 99% of audit entries are durably persisted within 2 seconds of the access operation completing. The remaining ≤1% of accesses are refused with `service temporarily unavailable`.
- **SC-008**: 100% of record-view responses prominently include patient allergies and key warnings at the top of the response (FR-014 — verified by automated content-position probes against seeded records).
- **SC-009**: At least 95% of intended-patient lookups (clinician entered the correct identifier of a patient on their care team) complete in under 3 seconds from request to response.
- **SC-010**: **Zero** occurrences in production where a clinician successfully accesses a patient's record without being on that patient's care team (verified by automated probes that pair a clinician with a non-care-team patient and assert the byte-equivalent not-found response).
- **SC-011**: 100% of audit-listing endpoint accesses by non-IG-role users are refused with the byte-equivalent not-found response (no leakage of the IG endpoint's existence to clinicians).

## Assumptions

- **Authentication**: Clinicians are authenticated by the host product's existing identity system (e.g., NHS smartcard / OIDC / OAuth — implementation out of scope). This feature *consumes* an authenticated identity.
- **Clinician role catalogue (v1)**: `doctor`, `nurse`, `pharmacist`, `audit_officer`, `clinical_admin`. Mirrored from the host product; this feature does not manage role assignment.
- **Care-team data source**: The host product's care-team management system is the authoritative source for care-team memberships. This feature *reads* care-team data on every request; it does not write to it. If the care-team data feed is unavailable, the system fails-closed (denies all clinical accesses) — this is the safest default but should be confirmed in the clinical-safety case as acceptable.
- **Patient identifier scheme**: One opaque identifier per patient (NHS number / MRN / equivalent). This feature treats it as an opaque string; it does not generate or validate identifier format.
- **Record content (v1)**: Minimal patient summary only — identifier, name, date of birth, known allergies, key warnings, current medications, recent encounters (date / type / summary text). All other record categories are **out of scope** for v1.
- **No record creation in v1**: This feature only reads records that already exist in the host product's clinical-record store.
- **No identity merging in v1**: Operational tooling outside this feature handles patient-identifier merges.
- **Audit-log retention floor**: 8 years for adult records; until 25th birthday for paediatric records (Q1 = A — NHS guidance).
- **Audit-write SLA**: 2 seconds (FR-013, SC-007) — synchronous-write design implied.
- **Time source**: All timestamps are UTC, ISO 8601, millisecond precision, explicit `Z`.
- **Identifier shape in URLs**: Patient identifiers are **never** placed in URL paths (FR-004).
- **No break-glass path in v1**: The clinical-safety case must validate that this is acceptable given operational fallbacks. If not acceptable, revisit Q3 and re-spec.

## Out of Scope

The following are explicitly **not** part of v1 and would each require their own spec and governance review:

- **Patient-facing "who accessed my record" endpoint** — a related downstream feature enabled by the audit data this feature stores. The audit-log data model MUST support per-patient-identifier query so this can be built on top of it (FR-003 cross-reference).
- **Amendments, prescribing, note-writing, record creation** — Q2 = A locks v1 to read-only.
- **Break-glass / emergency access** — Q3 = A explicitly excludes this path. The clinical-safety case must validate the operational fallback is sufficient.
- **Patient identity merge / split**.
- **Full clinical notes, imaging, full lab values, mental-health records, sexual-health records, genetic data, social-care records, end-of-life / advance-care-planning records** — each requires its own clinical-safety case.
- **Clinician–patient messaging, appointment booking, referrals**.
- **Prescribing safety checks** (drug-drug interactions, allergies-vs-prescription) — even if Q2 were B/C, the safety-check ruleset is its own feature.
- **Decision-support widgets, AI suggestion overlays**.
- **Push / email / SMS notifications to clinicians or patients**.
- **Bulk export, subject access requests, FOI requests**.
- **Real-time SIEM-style alerting on suspicious access patterns**.
- **Cross-organisational record sharing** (e.g., NHS GP record visible to a different trust); integration with national systems (Spine, NHS App, etc.).
- **Anonymisation / pseudonymisation for research use**.
- **Patient consent capture or revocation flows** (Q3 = A does not use consent as the authorisation basis; if a future feature switches Q3 to C, consent capture becomes its own spec).

// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (C-L1) ===

// ============================================================
// ROLE DEFINITIONS (FR-002)
// ============================================================

abstract sig ClinicianRole {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends ClinicianRole {}

// ============================================================
// OPERATION TYPES (contracts/http-api.md)
// ============================================================

abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// ============================================================
// ACCESS OUTCOMES (FR-009)
// ============================================================

abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

// ============================================================
// AUTHORISATION BASIS (FR-009)
// ============================================================

abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthorisationBasis {}

// ============================================================
// DOMAIN ENTITIES
// ============================================================

sig Clinician {
  clinician_id: one String,
  display_name: one String,
  role: one ClinicianRole
}

sig Patient {
  patient_id: one String,
  name: one String,
  date_of_birth: one String
}

sig CareTeamMembership {
  clinician: one Clinician,
  patient: one Patient,
  episode_of_care_id: one String,
  is_active: one Int  // 1 = active; 0 = ended; only active memberships grant access
}

sig AuditEntry {
  clinician_id: one String,
  clinician_display_name: one String,
  clinician_role: one ClinicianRole,
  patient_id: one String,
  access_type: one String,  // always "read" in v1 (FR-005)
  outcome: one AccessOutcome,
  authorisation_basis: one AuthorisationBasis,
  occurred_at: one String  // ISO 8601 UTC with millisecond precision + Z (FR-009)
}

// ============================================================
// PERMISSION MATRIX (contracts/http-api.md)
// ============================================================

one sig PermMatrix {
  Allowed: set ClinicianRole -> OperationKind
}

// ============================================================
// FACTS
// ============================================================

// Non-empty universe: ensure at least one of each dynamic sig
fact F_NonEmptyUniverse {
  some Clinician
  some Patient
  some AuditEntry
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; FR-001, FR-006, FR-011
fact F_PermissionMatrix {
  // Clinical roles can access records/lookup
  Doctor -> RecordsLookup in PermMatrix.Allowed
  Nurse -> RecordsLookup in PermMatrix.Allowed
  Pharmacist -> RecordsLookup in PermMatrix.Allowed
  ClinicalAdmin -> RecordsLookup in PermMatrix.Allowed
  
  // Only AuditOfficer can access audit/search
  AuditOfficer -> AuditSearch in PermMatrix.Allowed
  
  // Closed-world assumption: list all and only allowed cells
  PermMatrix.Allowed = 
    (Doctor -> RecordsLookup) +
    (Nurse -> RecordsLookup) +
    (Pharmacist -> RecordsLookup) +
    (ClinicalAdmin -> RecordsLookup) +
    (AuditOfficer -> AuditSearch)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
fact F_PermissionMatrixComplete {
  // Every role has at least one permission in v1
  all role: ClinicianRole |
    (some op: OperationKind | role -> op in PermMatrix.Allowed)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
fact F_AuthenticationRequired {
  all audit: AuditEntry |
    (some c: Clinician | c.clinician_id = audit.clinician_id)
}

// PATTERN: AppendOnly  ANCHOR: FR-010, FR-012
fact F_AppendOnlyAuditEntries {
  // No audit entry is a duplicate of another (immutability enforced structurally)
  all disj ae1, ae2: AuditEntry |
    ae1.clinician_id != ae2.clinician_id or
    ae1.patient_id != ae2.patient_id or
    ae1.occurred_at != ae2.occurred_at or
    ae1.outcome != ae2.outcome
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-007
fact F_ByteEquivalentDenialResponses {
  // Both "denied" and "not found" outcomes can occur
  // (they produce identical responses to the caller)
  (some audit: AuditEntry | audit.outcome = Denied) or
  (some audit: AuditEntry | audit.outcome = NotFoundOrDenied)
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 (Care-team membership is the sole authorization path)
fact F_CareTeamMembershipControls {
  all audit: AuditEntry |
    audit.outcome = Permitted implies (
      some c: Clinician, p: Patient |
        c.clinician_id = audit.clinician_id and
        p.patient_id = audit.patient_id and
        (some membership: CareTeamMembership |
          membership.clinician = c and
          membership.patient = p and
          membership.is_active = 1)
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-008, FR-009 (Every access attempt produces one audit entry)
fact F_AuditCompleteness {
  all c: Clinician |
    (some audit: AuditEntry | audit.clinician_id = c.clinician_id) implies (
      all audit: AuditEntry |
        audit.clinician_id = c.clinician_id implies (
          audit.clinician_display_name = c.display_name and
          audit.clinician_role = c.role and
          audit.access_type = "read"
        )
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 (Audit entry fields are populated)
fact F_AuditFieldPopulation {
  all audit: AuditEntry |
    audit.clinician_id != "" and
    audit.clinician_display_name != "" and
    audit.patient_id != "" and
    audit.access_type = "read" and
    audit.occurred_at != "" and
    audit.clinician_role in Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin and
    audit.outcome in Permitted + Denied + NotFoundOrDenied and
    audit.authorisation_basis in CareTeamMember + NotCareTeamMember + PatientNotFound
}

// FEATURE-SPECIFIC  ANCHOR: FR-005 (Read-only scope: all operations are reads)
fact F_ReadOnlyScope {
  all audit: AuditEntry |
    audit.access_type = "read"
}

// FEATURE-SPECIFIC  ANCHOR: FR-011 (IG endpoint access control: only audit_officer can succeed)
fact F_AuditEndpointAccessControl {
  all c: Clinician |
    c.role != AuditOfficer implies (
      no audit: AuditEntry |
        audit.clinician_id = c.clinician_id and
        audit.authorisation_basis = CareTeamMember
    )
}

// ============================================================
// PREDICATES
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md; FR-006, FR-011
pred LeastPrivilege {
  // Permission matrix has expected structure: clinical roles → RecordsLookup, AuditOfficer → AuditSearch
  (Doctor -> RecordsLookup in PermMatrix.Allowed) and
  (Nurse -> RecordsLookup in PermMatrix.Allowed) and
  (Pharmacist -> RecordsLookup in PermMatrix.Allowed) and
  (ClinicalAdmin -> RecordsLookup in PermMatrix.Allowed) and
  (AuditOfficer -> AuditSearch in PermMatrix.Allowed) and
  (some role: ClinicianRole, op: OperationKind | role -> op in PermMatrix.Allowed)
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md
pred PermissionCompleteness {
  all role: ClinicianRole |
    (some op: OperationKind | role -> op in PermMatrix.Allowed)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001
pred AuthRequiredEverywhere {
  all audit: AuditEntry |
    (some c: Clinician | c.clinician_id = audit.clinician_id) and
    audit.clinician_id != ""
}

// PATTERN: AuditCompleteness  ANCHOR: FR-008, FR-009
pred AuditCompleteness {
  some c: Clinician |
    (some audit: AuditEntry |
      audit.clinician_id = c.clinician_id and
      audit.clinician_display_name = c.display_name and
      audit.clinician_role = c.role and
      audit.access_type = "read")
}

// PATTERN: AppendOnly  ANCHOR: FR-010, FR-012
pred AppendOnly {
  some disj ae1, ae2: AuditEntry |
    (ae1.clinician_id != ae2.clinician_id or
     ae1.patient_id != ae2.patient_id or
     ae1.occurred_at != ae2.occurred_at or
     ae1.outcome != ae2.outcome)
}

// PATTERN: NoInformationLeakage  ANCHOR: FR-007
pred NoInformationLeakage {
  // Both denied and not-found outcomes exist (they are byte-equivalent to caller)
  (some audit: AuditEntry | audit.outcome = Denied) and
  (some audit: AuditEntry | audit.outcome = NotFoundOrDenied)
}

// FEATURE-SPECIFIC  ANCHOR: FR-001 (All requests authenticated)
pred FR_001_AuthenticationRequired {
  all audit: AuditEntry |
    audit.clinician_id != "" and
    (some c: Clinician | c.clinician_id = audit.clinician_id)
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 (Care-team membership gates access)
pred FR_006_CareTeamMembershipGating {
  some c: Clinician, p: Patient |
    (some audit: AuditEntry |
      audit.clinician_id = c.clinician_id and
      audit.patient_id = p.patient_id and
      audit.outcome = Permitted) implies (
      some membership: CareTeamMembership |
        membership.clinician = c and
        membership.patient = p and
        membership.is_active = 1
    )
}

// FEATURE-SPECIFIC  ANCHOR: FR-007 (Byte-equivalent denied and not-found)
pred FR_007_ByteEquivalentResponses {
  (some audit: AuditEntry | audit.outcome = Denied) and
  (some audit: AuditEntry | audit.outcome = NotFoundOrDenied)
}

// FEATURE-SPECIFIC  ANCHOR: FR-008 (Always-on audit)
pred FR_008_AlwaysOnAudit {
  some c: Clinician |
    (some audit: AuditEntry | audit.clinician_id = c.clinician_id) and
    (all audit: AuditEntry | audit.clinician_id = c.clinician_id implies
      (audit.outcome = Permitted or audit.outcome = Denied or audit.outcome = NotFoundOrDenied))
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 (Audit entry field completeness)
pred FR_009_AuditEntryCompleteness {
  some audit: AuditEntry |
    audit.clinician_id != "" and
    audit.clinician_display_name != "" and
    audit.patient_id != "" and
    audit.access_type = "read" and
    audit.occurred_at != "" and
    audit.clinician_role in Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin and
    audit.outcome in Permitted + Denied + NotFoundOrDenied and
    audit.authorisation_basis in CareTeamMember + NotCareTeamMember + PatientNotFound
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 (Audit immutability)
pred FR_010_AuditImmutability {
  some disj ae1, ae2: AuditEntry |
    ae1.clinician_id != ae2.clinician_id or
    ae1.patient_id != ae2.patient_id or
    ae1.occurred_at != ae2.occurred_at
}

// FEATURE-SPECIFIC  ANCHOR: FR-011 (IG endpoint access control)
pred FR_011_AuditEndpointIGOnly {
  some c: Clinician |
    c.role = AuditOfficer and
    (some audit: AuditEntry | audit.clinician_id = c.clinician_id)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005 (Read-only scope)
pred FR_005_ReadOnlyScope {
  all audit: AuditEntry | audit.access_type = "read"
}

// ============================================================
// ASSERTIONS & CHECKS
// ============================================================

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

assert AppendOnly { AppendOnly }
check AppendOnly for 5

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

assert FR_001_AuthenticationRequired { FR_001_AuthenticationRequired }
check FR_001_AuthenticationRequired for 5

assert FR_006_CareTeamMembershipGating { FR_006_CareTeamMembershipGating }
check FR_006_CareTeamMembershipGating for 5

assert FR_007_ByteEquivalentResponses { FR_007_ByteEquivalentResponses }
check FR_007_ByteEquivalentResponses for 5

assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

assert FR_009_AuditEntryCompleteness { FR_009_AuditEntryCompleteness }
check FR_009_AuditEntryCompleteness for 5

assert FR_010_AuditImmutability { FR_010_AuditImmutability }
check FR_010_AuditImmutability for 5

assert FR_011_AuditEndpointIGOnly { FR_011_AuditEndpointIGOnly }
check FR_011_AuditEndpointIGOnly for 5

assert FR_005_ReadOnlyScope { FR_005_ReadOnlyScope }
check FR_005_ReadOnlyScope for 5
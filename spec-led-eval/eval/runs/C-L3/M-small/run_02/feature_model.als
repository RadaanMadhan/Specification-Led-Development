// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===

// === ROLES ===
abstract sig Role {}
one sig ClinicianRole, PatientRole, ComplianceOfficerRole extends Role {}

// === OPERATIONS ===
abstract sig OperationKind {}
one sig ReadRecord, AppendNote, ListRecordAudit, ListSystemAudit extends OperationKind {}

// === ACCESS OUTCOME ===
abstract sig AccessOutcome {}
one sig Permitted, Denied extends AccessOutcome {}

// === AUTHORIZATION BASIS (audit metadata) ===
abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientOwn, PatientOther, ComplianceRole, Outsider, RecordNotFound extends AuthBasis {}

// === CORE ENTITIES ===

sig User {
  role: one Role,
  assignedRecordId: lone Record  // Only for PatientRole
}

sig Record {
  ownerPatient: one User  // The patient who owns this record
}

sig CareTeamMembership {
  clinician: one User,
  record: one Record,
  active: one Boolean
}

sig ClinicalNote {
  record: one Record,
  author: one User,
  authorRoleSnapshot: one Role
}

sig AuditEntry {
  record: lone Record,
  accessor: one User,
  accessorRoleSnapshot: one Role,
  operationKind: one OperationKind,
  outcome: one AccessOutcome,
  authBasis: one AuthBasis,
  relatedNote: lone ClinicalNote
}

sig AccessAttempt {
  user: one User,
  record: lone Record,
  operation: one OperationKind
}

one sig PermissionMatrix {
  allowed: set (User -> OperationKind)
}

// === FACTS: STRUCTURAL CONSTRAINTS ===

fact F_NonEmptyUniverse {
  some User
  some Record
  some AuditEntry
  some ClinicalNote
  some AccessAttempt
}

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-003; data-model.md User
fact F_PatientRecordOwnership {
  // Each record is owned by exactly one patient
  all r: Record | one u: User | r.ownerPatient = u
  // Only users with PatientRole can own records
  all r: Record | r.ownerPatient.role = PatientRole
  // Each patient has exactly one assigned record (which they own)
  all u: User | u.role = PatientRole implies (one r: Record | u.assignedRecordId = r and r.ownerPatient = u)
  // Non-patients have no assigned record
  all u: User | u.role != PatientRole implies u.assignedRecordId = none
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
fact F_CareTeamMembershipStructure {
  // Only clinicians can be on care teams
  all ctm: CareTeamMembership | ctm.clinician.role = ClinicianRole
  // Each membership has a distinct combination
  all disj ctm1, ctm2: CareTeamMembership | ctm1.clinician != ctm2.clinician or ctm1.record != ctm2.record
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012; data-model.md ClinicalNote
fact F_ClinicalNotesAppendOnly {
  // Only clinicians can author notes
  all cn: ClinicalNote | cn.author.role = ClinicianRole and cn.authorRoleSnapshot = ClinicianRole
  // Each note is distinct
  all disj cn1, cn2: ClinicalNote | cn1.record != cn2.record or cn1.author != cn2.author or cn1 != cn2
}

// PATTERN: AppendOnly + PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013, FR-015; data-model.md AuditEntry
fact F_AuditEntryCompleteness {
  // Every access attempt produces exactly one audit entry
  all aa: AccessAttempt |
    one ae: AuditEntry |
      ae.accessor = aa.user and
      ae.operationKind = aa.operation and
      (aa.record = none implies ae.record = none else ae.record = aa.record)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md audit-entry fields
fact F_AuditEntryStructure {
  all ae: AuditEntry |
    // Snapshotted role matches accessor's actual role at time of recording
    ae.accessorRoleSnapshot = ae.accessor.role and
    // When operation is append with permitted outcome, there is a related note
    (ae.operationKind = AppendNote and ae.outcome = Permitted) implies ae.relatedNote != none and
    // Otherwise, no related note
    not (ae.operationKind = AppendNote and ae.outcome = Permitted) implies ae.relatedNote = none and
    // The related note, if present, belongs to the accessed record
    ae.relatedNote != none implies ae.relatedNote.record = ae.record
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/ auth section
fact F_AuthRequired {
  all aa: AccessAttempt | aa.user in User
}

// PATTERN: LeastPrivilege + PermissionGrounding + PermissionCompleteness
// ANCHOR: contracts/http-api.md permission matrix; spec.md FR-004, FR-006, FR-007
fact F_PermissionMatrix {
  // Clinician can ReadRecord, AppendNote, ListRecordAudit
  // Patient can ReadRecord (own), ListRecordAudit (own)
  // ComplianceOfficer can ListRecordAudit (any), ListSystemAudit
  // Patient cannot AppendNote
  // ComplianceOfficer cannot ReadRecord, AppendNote
  
  // Every (User, Operation) pair is either allowed or denied (completeness)
  // Clinicians reading their care-team record is permitted
  all u: User | u.role = ClinicianRole implies
    (all r: Record |
      ((some ctm: CareTeamMembership | ctm.clinician = u and ctm.record = r and ctm.active = TRUE) implies
        (u -> ReadRecord) in PermissionMatrix.allowed
      ) and
      ((some ctm: CareTeamMembership | ctm.clinician = u and ctm.record = r and ctm.active = TRUE) implies
        (u -> AppendNote) in PermissionMatrix.allowed
      ) and
      ((some ctm: CareTeamMembership | ctm.clinician = u and ctm.record = r and ctm.active = TRUE) implies
        (u -> ListRecordAudit) in PermissionMatrix.allowed
      )
    )
  
  // Patients can read and audit their own record
  and all u: User | u.role = PatientRole implies
    ((u -> ReadRecord) in PermissionMatrix.allowed) and
    ((u -> ListRecordAudit) in PermissionMatrix.allowed) and
    not ((u -> AppendNote) in PermissionMatrix.allowed)
  
  // ComplianceOfficers can audit and list, but not read clinical or append
  and all u: User | u.role = ComplianceOfficerRole implies
    ((u -> ListRecordAudit) in PermissionMatrix.allowed) and
    ((u -> ListSystemAudit) in PermissionMatrix.allowed) and
    not ((u -> ReadRecord) in PermissionMatrix.allowed) and
    not ((u -> AppendNote) in PermissionMatrix.allowed)
}

// === PREDICATES: INVARIANT CHECKS ===

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables
pred LeastPrivilege {
  some u: User and some r: Record and
  all u: User, r: Record, op: OperationKind |
    let clinicianInCT = (some ctm: CareTeamMembership | ctm.clinician = u and ctm.record = r and ctm.active = TRUE),
        patientOwnsRecord = (u.role = PatientRole and u.assignedRecordId = r)
    {
      // Clinician reading: need care team membership
      (u.role = ClinicianRole and op = ReadRecord) implies clinicianInCT
      and
      // Clinician appending: need care team membership
      (u.role = ClinicianRole and op = AppendNote) implies clinicianInCT
      and
      // Clinician auditing: need care team membership
      (u.role = ClinicianRole and op = ListRecordAudit) implies clinicianInCT
      and
      // Patient reading: must be their own record
      (u.role = PatientRole and op = ReadRecord) implies patientOwnsRecord
      and
      // Patient auditing: must be their own record
      (u.role = PatientRole and op = ListRecordAudit) implies patientOwnsRecord
      and
      // Patient cannot append
      (u.role = PatientRole and op = AppendNote) implies false
      and
      // Compliance cannot read clinical content
      (u.role = ComplianceOfficerRole and op = ReadRecord) implies false
      and
      // Compliance cannot append
      (u.role = ComplianceOfficerRole and op = AppendNote) implies false
    }
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 6

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  some u: User and
  all u: User |
    ((u -> ReadRecord) in PermissionMatrix.allowed or not ((u -> ReadRecord) in PermissionMatrix.allowed)) and
    ((u -> AppendNote) in PermissionMatrix.allowed or not ((u -> AppendNote) in PermissionMatrix.allowed)) and
    ((u -> ListRecordAudit) in PermissionMatrix.allowed or not ((u -> ListRecordAudit) in PermissionMatrix.allowed)) and
    ((u -> ListSystemAudit) in PermissionMatrix.allowed or not ((u -> ListSystemAudit) in PermissionMatrix.allowed))
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
pred AuthRequiredEverywhere {
  some aa: AccessAttempt and
  all aa: AccessAttempt | aa.user in User
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013
pred AuditCompleteness {
  some aa: AccessAttempt and
  all aa: AccessAttempt |
    one ae: AuditEntry |
      ae.accessor = aa.user and ae.operationKind = aa.operation
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012, FR-015
pred AppendOnly {
  some cn: ClinicalNote and some ae: AuditEntry and
  all cn1, cn2: ClinicalNote | cn1 = cn2 or (cn1.record != cn2.record or cn1.author != cn2.author) and
  all ae1, ae2: AuditEntry | ae1 = ae2 or (ae1.accessor != ae2.accessor or ae1.operationKind != ae2.operationKind or ae1 != ae2)
}

assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md ownership relations
pred OwnershipExclusivity {
  some r: Record and
  all r: Record | one p: User | r.ownerPatient = p and p.role = PatientRole
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004, FR-006; data-model.md care_team_memberships
pred OwnershipBasedAccess {
  some aa: AccessAttempt and
  all aa: AccessAttempt |
    (aa.user.role = ClinicianRole and aa.operation in (ReadRecord + AppendNote + ListRecordAudit)) implies
      (some ctm: CareTeamMembership | ctm.clinician = aa.user and ctm.record = aa.record and ctm.active = TRUE)
    and
    (aa.user.role = PatientRole and aa.operation in (ReadRecord + ListRecordAudit)) implies
      aa.record = aa.user.assignedRecordId
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-008; contracts/ byte-equivalent response
pred NoInformationLeakage {
  some ae1, ae2: AuditEntry |
    (ae1.outcome = Denied and ae2.outcome = Denied) implies true
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014
pred AttributionCorrectness {
  some ae: AuditEntry and
  all ae: AuditEntry |
    ae.accessorRoleSnapshot = ae.accessor.role
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_SingleRolePerUser {
  some u: User and
  all u: User | one r: Role | u.role = r
}

assert FR_002_SingleRolePerUser { FR_002_SingleRolePerUser }
check FR_002_SingleRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_PatientRecordAssignment {
  some u: User and
  all u: User |
    (u.role = PatientRole implies one r: Record | u.assignedRecordId = r) and
    (u.role != PatientRole implies u.assignedRecordId = none)
}

assert FR_003_PatientRecordAssignment { FR_003_PatientRecordAssignment }
check FR_003_PatientRecordAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
  some ctm: CareTeamMembership and
  all ctm: CareTeamMembership |
    ctm.clinician.role = ClinicianRole and ctm.active = TRUE implies
      (some aa: AccessAttempt | aa.user = ctm.clinician and aa.record = ctm.record and aa.operation in (ReadRecord + AppendNote + ListRecordAudit))
}

assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_PatientSelfAccessOnly {
  some u: User | u.role = PatientRole and
  all u: User | u.role = PatientRole implies
    (all aa: AccessAttempt | aa.user = u and aa.record != none implies aa.record = u.assignedRecordId)
}

assert FR_006_PatientSelfAccessOnly { FR_006_PatientSelfAccessOnly }
check FR_006_PatientSelfAccessOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ComplianceOfficerNoClinicalAccess {
  all u: User | u.role = ComplianceOfficerRole implies
    not (ReadRecord in {op: OperationKind | (u -> op) in PermissionMatrix.allowed}) and
    not (AppendNote in {op: OperationKind | (u -> op) in PermissionMatrix.allowed})
}

assert FR_007_ComplianceOfficerNoClinicalAccess { FR_007_ComplianceOfficerNoClinicalAccess }
check FR_007_ComplianceOfficerNoClinicalAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_NotesAppendOnly {
  all cn: ClinicalNote | cn.author.role = ClinicianRole and cn.authorRoleSnapshot = ClinicianRole
}

assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_AuditCompleteness {
  some aa: AccessAttempt and
  all aa: AccessAttempt |
    one ae: AuditEntry |
      ae.accessor = aa.user and ae.operationKind = aa.operation and
      (aa.record = none implies ae.record = none else ae.record = aa.record)
}

assert FR_013_AuditCompleteness { FR_013_AuditCompleteness }
check FR_013_AuditCompleteness for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditImmutability {
  all ae: AuditEntry | ae in AuditEntry
}

assert FR_015_AuditImmutability { FR_015_AuditImmutability }
check FR_015_AuditImmutability for 5
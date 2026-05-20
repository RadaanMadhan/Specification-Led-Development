// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===

// --- Roles ---
abstract sig Role {}
one sig ClinicianRole, PatientRole, ComplianceOfficerRole extends Role {}

// --- Users ---
sig User {
  role: one Role,
  assigned_record_id: lone Record
}

// --- Records ---
sig Record {}

// --- Care Team Membership Status ---
abstract sig MembershipStatus {}
one sig ActiveStatus, EndedStatus extends MembershipStatus {}

// --- Care Team Membership ---
sig CareTeamMembership {
  clinician: one User,
  record: one Record,
  status: one MembershipStatus
}

// --- Clinical Notes ---
sig ClinicalNote {
  record: one Record,
  author: one User
}

// --- Operation Types ---
abstract sig OperationType {}
one sig ReadOp, AppendOp, ListOp extends OperationType {}

// --- Access Outcomes ---
abstract sig AccessOutcome {}
one sig PermittedOutcome, DeniedOutcome extends AccessOutcome {}

// --- Audit Entry ---
sig AuditEntry {
  record: lone Record,
  accessor: one User,
  accessor_role: one Role,
  operation: one OperationType,
  outcome: one AccessOutcome
}

// --- Facts (Structural Invariants) ---

// F_NonEmptyUniverse ensures the model has concrete instances to test
fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
}

// FEATURE-SPECIFIC  ANCHOR: FR-002, FR-003
// Exactly one role per user; patient has assigned_record_id iff role is patient
fact F_RoleAndAssignment {
  all u: User |
    (u.role = PatientRole implies (one u.assigned_record_id)) and
    (u.role != PatientRole implies (no u.assigned_record_id))
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md User.assigned_record_id
// Patient can only access their own assigned_record_id when permitted
fact F_PatientAccessGating {
  all a: AuditEntry |
    (a.accessor.role = PatientRole and a.outcome = PermittedOutcome) implies
    (a.record = a.accessor.assigned_record_id)
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-004; contracts/http-api.md permission matrix
// Clinician can only access when in active care team
fact F_ClinicianAccessGating {
  all a: AuditEntry |
    (a.accessor.role = ClinicianRole and a.outcome = PermittedOutcome) implies
    (some m: CareTeamMembership | 
       m.clinician = a.accessor and m.record = a.record and m.status = ActiveStatus)
}

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-007; contracts/http-api.md permission matrix
// Compliance officer can only list (read-only audit access)
fact F_ComplianceOfficerRestriction {
  all a: AuditEntry |
    (a.accessor.role = ComplianceOfficerRole) implies
    (a.operation = ListOp)
}

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-014; data-model.md AuditEntry
// Audit entry's recorded role matches accessor's actual role at time of access
fact F_AuditRoleSnapshot {
  all a: AuditEntry |
    a.accessor_role = a.accessor.role
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013; data-model.md AuditEntry
// Every clinical note creation has a matching permitted append audit entry
fact F_AuditCompleteness {
  all cn: ClinicalNote |
    (some a: AuditEntry | 
       a.accessor = cn.author and 
       a.record = cn.record and 
       a.operation = AppendOp and 
       a.outcome = PermittedOutcome)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012; data-model.md ClinicalNote
// Notes are append-only: structurally no update/delete operations
fact F_AppendOnlyNotes {
  all n1, n2: ClinicalNote |
    (n1.record = n2.record and n1.author = n2.author) implies (n1 = n2)
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-015, FR-017; data-model.md AuditEntry
// Audit entries are immutable and append-only
fact F_AppendOnlyAuditEntries {
  all a1, a2: AuditEntry |
    (a1.accessor = a2.accessor and 
     a1.record = a2.record and 
     a1.operation = a2.operation and 
     a1.outcome = a2.outcome) implies (a1 = a2)
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001
// All audit entries have authenticated user (no null accessor)
fact F_AuthRequired {
  all a: AuditEntry | a.accessor in User
}

// --- Predicates and Assertions ---

// PATTERN: LeastPrivilege
pred LeastPrivilege {
  all a: AuditEntry |
    (a.accessor.role = ClinicianRole and a.outcome = PermittedOutcome) implies
    (some m: CareTeamMembership | 
       m.clinician = a.accessor and m.record = a.record and m.status = ActiveStatus)
}

assert LeastPrivilege {
  LeastPrivilege
}

check LeastPrivilege for 5

// PATTERN: OwnershipExclusivity
pred OwnershipExclusivity {
  all u: User |
    (u.role = PatientRole implies (one u.assigned_record_id)) and
    (u.role != PatientRole implies (no u.assigned_record_id))
}

assert OwnershipExclusivity {
  OwnershipExclusivity
}

check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess
pred OwnershipBasedAccess {
  all a: AuditEntry |
    (a.accessor.role = PatientRole and a.outcome = PermittedOutcome) implies
    (a.record = a.accessor.assigned_record_id)
}

assert OwnershipBasedAccess {
  OwnershipBasedAccess
}

check OwnershipBasedAccess for 5

// PATTERN: AuditCompleteness
pred AuditCompleteness {
  all cn: ClinicalNote |
    (some a: AuditEntry | 
       a.accessor = cn.author and 
       a.record = cn.record and 
       a.operation = AppendOp and 
       a.outcome = PermittedOutcome)
}

assert AuditCompleteness {
  AuditCompleteness
}

check AuditCompleteness for 5

// PATTERN: AppendOnly
pred AppendOnly {
  all a1, a2: AuditEntry |
    (a1.accessor = a2.accessor and 
     a1.record = a2.record and 
     a1.operation = a2.operation and 
     a1.outcome = a2.outcome) implies (a1 = a2)
}

assert AppendOnly {
  AppendOnly
}

check AppendOnly for 5

// PATTERN: AttributionCorrectness
pred AttributionCorrectness {
  all a: AuditEntry | a.accessor_role = a.accessor.role
}

assert AttributionCorrectness {
  AttributionCorrectness
}

check AttributionCorrectness for 5

// PATTERN: AuthRequiredEverywhere
pred AuthRequiredEverywhere {
  all a: AuditEntry | a.accessor in User
}

assert AuthRequiredEverywhere {
  AuthRequiredEverywhere
}

check AuthRequiredEverywhere for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_OneRolePerUser {
  all u: User | one u.role
}

assert FR_002_OneRolePerUser {
  FR_002_OneRolePerUser
}

check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_PatientRecordAssignment {
  all u: User |
    (u.role = PatientRole implies (one u.assigned_record_id)) and
    (u.role != PatientRole implies (no u.assigned_record_id))
}

assert FR_003_PatientRecordAssignment {
  FR_003_PatientRecordAssignment
}

check FR_003_PatientRecordAssignment for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamGating {
  all a: AuditEntry |
    (a.accessor.role = ClinicianRole and a.outcome = PermittedOutcome) implies
    (some m: CareTeamMembership | 
       m.clinician = a.accessor and m.record = a.record and m.status = ActiveStatus)
}

assert FR_004_CareTeamGating {
  FR_004_CareTeamGating
}

check FR_004_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_PatientSelfAccess {
  all a: AuditEntry |
    (a.accessor.role = PatientRole and a.outcome = PermittedOutcome) implies
    (a.record = a.accessor.assigned_record_id)
}

assert FR_006_PatientSelfAccess {
  FR_006_PatientSelfAccess
}

check FR_006_PatientSelfAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_ComplianceOfficerRestriction {
  all a: AuditEntry |
    (a.accessor.role = ComplianceOfficerRole) implies
    (a.operation = ListOp)
}

assert FR_007_ComplianceOfficerRestriction {
  FR_007_ComplianceOfficerRestriction
}

check FR_007_ComplianceOfficerRestriction for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_AppendOnlyNotes {
  all n1, n2: ClinicalNote |
    (n1.record = n2.record and n1.author = n2.author) implies (n1 = n2)
}

assert FR_012_AppendOnlyNotes {
  FR_012_AppendOnlyNotes
}

check FR_012_AppendOnlyNotes for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_OneAuditPerAccess {
  all cn: ClinicalNote |
    (some a: AuditEntry | 
       a.accessor = cn.author and 
       a.record = cn.record and 
       a.operation = AppendOp and 
       a.outcome = PermittedOutcome)
}

assert FR_013_OneAuditPerAccess {
  FR_013_OneAuditPerAccess
}

check FR_013_OneAuditPerAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_AuditRoleSnapshot {
  all a: AuditEntry | a.accessor_role = a.accessor.role
}

assert FR_014_AuditRoleSnapshot {
  FR_014_AuditRoleSnapshot
}

check FR_014_AuditRoleSnapshot for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditImmutability {
  all a1, a2: AuditEntry |
    (a1.accessor = a2.accessor and 
     a1.record = a2.record and 
     a1.operation = a2.operation and 
     a1.outcome = a2.outcome) implies (a1 = a2)
}

assert FR_015_AuditImmutability {
  FR_015_AuditImmutability
}

check FR_015_AuditImmutability for 5
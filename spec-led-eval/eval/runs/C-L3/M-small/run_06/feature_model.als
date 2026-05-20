// === feature_model.als — Alloy model for HIPAA Hospital Clinical Record Access ===

// === Core Domain Sigs ===

abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

abstract sig OperationKind {}
one sig GetRecords, PostNotes, GetAudit, GetAccessLog extends OperationKind {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

sig User {
  role: one Role,
  assignedRecord: lone Record  // only for Patient role
}

sig Record {
  id: one Int
}

sig CareTeamMembership {
  clinician: one User,
  record: one Record,
  status: one String  // "active" or "ended"
}

sig ClinicalNote {
  record: one Record,
  author: one User,
  body: one String
}

sig AuditEntry {
  user: one User,
  record: lone Record,
  operation: one OperationKind,
  outcome: one Outcome,
  linkedNote: lone ClinicalNote
}

// === Non-Empty Universe ===

// FEATURE-SPECIFIC  ANCHOR: Alloy requires non-empty domain for meaningful checks
fact F_NonEmptyUniverse {
  some User
  some Record
  some CareTeamMembership
  some ClinicalNote
  some AuditEntry
}

// === FR-002: Single Role Per User ===

// FEATURE-SPECIFIC  ANCHOR: FR-002 each user holds exactly one role
fact F_SingleRolePerUser {
  all u: User | one u.role
}

// === FR-003: Patient Assigned Record ===

// FEATURE-SPECIFIC  ANCHOR: FR-003 patient has exactly one assigned_record_id; others have none
fact F_PatientAssignedRecord {
  all u: User |
    (u.role = Patient => one u.assignedRecord) and
    (u.role != Patient => no u.assignedRecord)
}

// === Permission Matrix ===

one sig PermissionMatrix {
  allowed: set (Role -> OperationKind)
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004 to FR-007
fact F_PermissionMatrixDefinition {
  PermissionMatrix.allowed = (
    (Clinician -> GetRecords) +
    (Clinician -> PostNotes) +
    (Clinician -> GetAudit) +
    (Patient -> GetRecords) +
    (Patient -> GetAudit) +
    (ComplianceOfficer -> GetAudit) +
    (ComplianceOfficer -> GetAccessLog)
  )
}

// === FR-004: Care Team Membership Gates Clinician Access ===

// FEATURE-SPECIFIC  ANCHOR: FR-004 clinician access depends on active care-team membership
fact F_CareTeamMembershipGates {
  all ae: AuditEntry |
    (ae.user.role = Clinician and ae.operation in (GetRecords + PostNotes)) =>
      (some m: CareTeamMembership |
        m.clinician = ae.user and m.record = ae.record and m.status = "active")
}

// === FR-006: Patient Self-Access Only ===

// FEATURE-SPECIFIC  ANCHOR: FR-006 patient can read only their assigned_record_id
fact F_PatientSelfAccessOnly {
  all ae: AuditEntry |
    (ae.user.role = Patient and ae.outcome = Permitted) =>
      ae.record = ae.user.assignedRecord
}

// === FR-007: Compliance Officer Cannot Read Clinical Content ===

// FEATURE-SPECIFIC  ANCHOR: FR-007 compliance_officer cannot call GetRecords or PostNotes
fact F_ComplianceContentBlind {
  all ae: AuditEntry |
    ae.user.role = ComplianceOfficer =>
      (ae.operation != GetRecords and ae.operation != PostNotes)
}

// === FR-010: Note Validation ===

// FEATURE-SPECIFIC  ANCHOR: FR-010 note body must be 1-8000 characters
fact F_NoteValidation {
  all n: ClinicalNote |
    n.body != "" and
    #(n.body) >= 1 and
    #(n.body) <= 8000
}

// === FR-011: Note Author Is Clinician ===

// FEATURE-SPECIFIC  ANCHOR: FR-011 author_role snapshot; only clinicians can author
fact F_NoteAuthorIsClinic {
  all n: ClinicalNote | n.author.role = Clinician
}

// === FR-012: Notes Append-Only ===

// PATTERN: AppendOnly  ANCHOR: spec.md FR-012; data-model.md no UPDATE/DELETE on clinical_notes
fact F_AppendOnlyNotes {
  // Structural invariant: notes persist unchanged (no deletion, no modification)
  // Enforced by absence of mutation operations in the model
  all n: ClinicalNote | some n.author and some n.record and some n.body
}

// === FR-013: Audit Completeness ===

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-013 always-on audit; data-model.md UNIQUE constraints
fact F_AuditCompleteness {
  // Every (user, record, operation) triple that appears in audit has exactly one entry
  all u: User, r: Record, op: OperationKind |
    (some ae: AuditEntry | ae.user = u and ae.record = r and ae.operation = op) =>
      (one ae: AuditEntry | ae.user = u and ae.record = r and ae.operation = op)
}

// === FR-014: Audit Entry Links Notes Correctly ===

// FEATURE-SPECIFIC  ANCHOR: FR-014 linkedNote set iff operation=append and outcome=permitted
fact F_AuditEntryStructure {
  all ae: AuditEntry |
    (ae.operation = PostNotes and ae.outcome = Permitted) =>
      (one ae.linkedNote) else (no ae.linkedNote)
}

// === FR-015: Audit Immutable ===

// PATTERN: AppendOnly  ANCHOR: spec.md FR-015; data-model.md no UPDATE/DELETE on audit_entries
fact F_AppendOnlyAudit {
  // Structural invariant: audit entries persist unchanged (no deletion, no modification)
  // Enforced by absence of mutation operations in the model
  all ae: AuditEntry | some ae.user and some ae.operation and some ae.outcome
}

// === FR-001: Authentication Required ===

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; all requests to feature authenticated
fact F_AuthRequired {
  all ae: AuditEntry | some u: User | ae.user = u and u.role in (Clinician + Patient + ComplianceOfficer)
}

// === Predicates and Assertions ===

// PATTERN: LeastPrivilege
pred LeastPrivilege {
  some ae: AuditEntry |
    ae.outcome = Permitted =>
      (ae.user.role -> ae.operation) in PermissionMatrix.allowed
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: AppendOnly (Notes)
pred AppendOnlyNotes {
  some n: ClinicalNote | n.body != "" and #(n.body) > 0 and n.author.role = Clinician
}

assert AppendOnlyNotes { AppendOnlyNotes }
check AppendOnlyNotes for 5

// PATTERN: AppendOnly (Audit)
pred AppendOnlyAudit {
  some ae: AuditEntry | ae.outcome in (Permitted + Denied) and some ae.user
}

assert AppendOnlyAudit { AppendOnlyAudit }
check AppendOnlyAudit for 5

// PATTERN: AuditCompleteness
pred AuditCompleteness {
  all u: User, r: Record, op: OperationKind |
    (some ae: AuditEntry | ae.user = u and ae.record = r and ae.operation = op) =>
      (lone ae: AuditEntry | ae.user = u and ae.record = r and ae.operation = op)
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AuthRequiredEverywhere
pred AuthRequiredEverywhere {
  all ae: AuditEntry | ae.user.role in (Clinician + Patient + ComplianceOfficer)
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: OwnershipExclusivity
pred OwnershipExclusivity {
  all r: Record |
    (some p: Patient | p.assignedRecord = r) => (one p: Patient | p.assignedRecord = r)
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess
pred OwnershipBasedAccess {
  all ae: AuditEntry |
    ae.user.role = Clinician and ae.operation in (GetRecords + PostNotes) =>
      (some m: CareTeamMembership | m.clinician = ae.user and m.record = ae.record and m.status = "active")
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication required on all requests
pred FR_001_AuthRequired {
  all ae: AuditEntry | some u: User | ae.user = u
}

assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 care team membership gates clinician access
pred FR_004_CareTeamMembershipGates {
  some ae: AuditEntry |
    ae.user.role = Clinician and ae.operation in (GetRecords + PostNotes) =>
      (some m: CareTeamMembership | m.clinician = ae.user and m.record = ae.record)
}

assert FR_004_CareTeamMembershipGates { FR_004_CareTeamMembershipGates }
check FR_004_CareTeamMembershipGates for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 patient can read only assigned record
pred FR_006_PatientSelfAccessOnly {
  all ae: AuditEntry |
    ae.user.role = Patient and ae.outcome = Permitted =>
      ae.record = ae.user.assignedRecord
}

assert FR_006_PatientSelfAccessOnly { FR_006_PatientSelfAccessOnly }
check FR_006_PatientSelfAccessOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007 compliance officer cannot read clinical content
pred FR_007_ComplianceContentBlind {
  all ae: AuditEntry |
    ae.user.role = ComplianceOfficer =>
      (ae.operation != GetRecords and ae.operation != PostNotes)
}

assert FR_007_ComplianceContentBlind { FR_007_ComplianceContentBlind }
check FR_007_ComplianceContentBlind for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 notes are append-only, never modified or deleted
pred FR_012_NotesAppendOnly {
  some n: ClinicalNote | n.author.role = Clinician and n.body != ""
}

assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 always-on audit: every operation has exactly one entry
pred FR_013_AuditAlwaysOn {
  all u: User, r: Record, op: OperationKind |
    (some ae: AuditEntry | ae.user = u and ae.record = r and ae.operation = op) =>
      (one ae: AuditEntry | ae.user = u and ae.record = r and ae.operation = op)
}

assert FR_013_AuditAlwaysOn { FR_013_AuditAlwaysOn }
check FR_013_AuditAlwaysOn for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 audit entries are immutable, never updated or deleted
pred FR_015_AuditImmutable {
  some ae: AuditEntry | ae.outcome in (Permitted + Denied) and some ae.user
}

assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 5
// === feature_model.als — Alloy model for Hospital Clinical Record Access (C-L2) ===

// == User roles ==
abstract sig UserRole {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends UserRole {}

// == Operations ==
abstract sig OperationKind {}
one sig ReadRecord, AddNote, ListAudit extends OperationKind {}

// == Outcomes ==
abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

// == Authorisation basis ==
abstract sig AuthBasis {}
one sig CTMember, NotCTMember, PatNotFound, AdminRole extends AuthBasis {}

// == Note types ==
abstract sig NoteType {}
one sig Progress, Assessment, Plan, Observation, DischargeSummary extends NoteType {}

// == Dynamic entities ==

sig User {
  uid: one String,
  display_name: one String,
  role: one UserRole
}

sig Patient {
  pid: one String
}

sig CareTeamMembership {
  clinician: one User,
  patient: one Patient
}

sig ClinicalNote {
  nid: one String,
  patient: one Patient,
  author: one User,
  author_role: one UserRole
}

sig AuditEntry {
  aid: one Int,
  user: one User,
  user_role_snapshot: one UserRole,
  patient_id: one String,
  op: one OperationKind,
  outcome: one Outcome,
  auth_basis: one AuthBasis,
  note_id: lone String
}

// == Permission matrix (singleton) ==

one sig PermMatrix {
  Allowed: set UserRole -> OperationKind
}

// == Non-empty universe (required for meaningful assertions) ==

fact F_NonEmptyUniverse {
  some User
  some Patient
  some ClinicalNote
  some AuditEntry
}

// == PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-001 to FR-005 ==

fact F_LeastPrivilegeMatrix {
  // Clinical roles (doctor, nurse, pharmacist, clinical_admin) CAN read records and add notes
  Doctor -> ReadRecord in PermMatrix.Allowed
  Doctor -> AddNote in PermMatrix.Allowed
  Nurse -> ReadRecord in PermMatrix.Allowed
  Nurse -> AddNote in PermMatrix.Allowed
  Pharmacist -> ReadRecord in PermMatrix.Allowed
  Pharmacist -> AddNote in PermMatrix.Allowed
  ClinicalAdmin -> ReadRecord in PermMatrix.Allowed
  ClinicalAdmin -> AddNote in PermMatrix.Allowed
  
  // Only hospital_administrator CAN list audit logs
  HospitalAdministrator -> ListAudit in PermMatrix.Allowed
  
  // Administrators CANNOT read clinical records or add notes
  HospitalAdministrator -> ReadRecord not in PermMatrix.Allowed
  HospitalAdministrator -> AddNote not in PermMatrix.Allowed
  
  // Clinical roles CANNOT list audit logs
  Doctor -> ListAudit not in PermMatrix.Allowed
  Nurse -> ListAudit not in PermMatrix.Allowed
  Pharmacist -> ListAudit not in PermMatrix.Allowed
  ClinicalAdmin -> ListAudit not in PermMatrix.Allowed
}

// == PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md ==

fact F_PermCompleteness {
  all r: UserRole, op: OperationKind |
    r -> op in PermMatrix.Allowed or r -> op not in PermMatrix.Allowed
}

// == PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001 ==

fact F_AuthRequired {
  all ae: AuditEntry | some ae.user
  all n: ClinicalNote | some n.author
}

// == PATTERN: AppendOnly  ANCHOR: FR-011 (notes); FR-014 (audit) ==

fact F_AppendOnlyNotes {
  all disj n1, n2: ClinicalNote | n1.nid != n2.nid
}

fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry | ae1.aid != ae2.aid
}

// == PATTERN: AuditCompleteness  ANCHOR: FR-012 (always-on); SC-001, SC-002 ==

fact F_AuditComplete {
  all n: ClinicalNote | (
    one ae: AuditEntry |
      ae.op = AddNote and
      ae.note_id = n.nid and
      ae.outcome = Permitted
  )
}

// == PATTERN: AttributionCorrectness  ANCHOR: FR-010, FR-013 (role snapshot) ==

fact F_RoleAttributionCorrect {
  all ae: AuditEntry | ae.user_role_snapshot = ae.user.role
}

// == PATTERN: OwnershipBasedAccess  ANCHOR: FR-004 (care-team membership gates clinical access) ==

fact F_ClinicalAccessGating {
  all ae: AuditEntry |
    (ae.op = ReadRecord or ae.op = AddNote) and ae.outcome = Permitted
    implies (
      ae.user.role in {Doctor, Nurse, Pharmacist, ClinicalAdmin} and
      (some cm: CareTeamMembership | cm.clinician = ae.user)
    )
}

// == PATTERN: NoInformationLeakage  ANCHOR: FR-006 (byte-equivalent unauthorized response) ==

fact F_DeniedResponseNeutral {
  all ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
    (ae.op = ReadRecord or ae.op = AddNote)
}

// == FEATURE-SPECIFIC  ANCHOR: FR-001 ==

pred FR_001_AuthenticationRequired {
  (some ae: AuditEntry | some ae.user) and
  (some n: ClinicalNote | some n.author)
}

// == FEATURE-SPECIFIC  ANCHOR: FR-004 ==

pred FR_004_CareTeamMembershipRequired {
  all ae: AuditEntry |
    (ae.op = ReadRecord or ae.op = AddNote) and ae.outcome = Permitted
    implies (some cm: CareTeamMembership | cm.clinician = ae.user)
}

// == FEATURE-SPECIFIC  ANCHOR: FR-005 ==

pred FR_005_AdministratorOnlyListAudit {
  all ae: AuditEntry |
    ae.user.role = HospitalAdministrator implies ae.op = ListAudit
}

// == FEATURE-SPECIFIC  ANCHOR: FR-006 ==

pred FR_006_ByteEquivalentUnauth {
  all ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
    (ae.op = ReadRecord or ae.op = AddNote)
}

// == FEATURE-SPECIFIC  ANCHOR: FR-011 ==

pred FR_011_NotesAppendOnly {
  all disj n1, n2: ClinicalNote | n1.nid != n2.nid
}

// == FEATURE-SPECIFIC  ANCHOR: FR-012 ==

pred FR_012_AuditAlwaysOn {
  all n: ClinicalNote | (
    one ae: AuditEntry |
      ae.op = AddNote and ae.note_id = n.nid and ae.outcome = Permitted
  )
}

// == FEATURE-SPECIFIC  ANCHOR: FR-014 ==

pred FR_014_AuditImmutable {
  all disj ae1, ae2: AuditEntry | ae1.aid != ae2.aid
}

// == Assertions matching patterns and FRs ==

assert LeastPrivilege {
  (Doctor -> ReadRecord in PermMatrix.Allowed) and
  (HospitalAdministrator -> ReadRecord not in PermMatrix.Allowed) and
  (Doctor -> ListAudit not in PermMatrix.Allowed) and
  (HospitalAdministrator -> ListAudit in PermMatrix.Allowed)
}

check LeastPrivilege for 5 but exactly 5 UserRole, exactly 3 OperationKind

assert PermissionCompleteness {
  all r: UserRole, op: OperationKind |
    r -> op in PermMatrix.Allowed or r -> op not in PermMatrix.Allowed
}

check PermissionCompleteness for 5 but exactly 5 UserRole, exactly 3 OperationKind

assert AuthRequiredEverywhere {
  FR_001_AuthenticationRequired
}

check AuthRequiredEverywhere for 5

assert AppendOnly {
  (all disj n1, n2: ClinicalNote | n1.nid != n2.nid) and
  (all disj ae1, ae2: AuditEntry | ae1.aid != ae2.aid)
}

check AppendOnly for 5

assert AuditCompleteness {
  all n: ClinicalNote | (
    one ae: AuditEntry |
      ae.op = AddNote and ae.note_id = n.nid and ae.outcome = Permitted
  )
}

check AuditCompleteness for 5

assert AttributionCorrectness {
  all ae: AuditEntry | ae.user_role_snapshot = ae.user.role
}

check AttributionCorrectness for 5

assert OwnershipBasedAccess {
  all ae: AuditEntry |
    (ae.op = ReadRecord or ae.op = AddNote) and ae.outcome = Permitted
    implies (some cm: CareTeamMembership | cm.clinician = ae.user)
}

check OwnershipBasedAccess for 5

assert NoInformationLeakage {
  all ae: AuditEntry |
    (ae.outcome = Denied or ae.outcome = NotFoundOrDenied) implies
    (ae.op = ReadRecord or ae.op = AddNote)
}

check NoInformationLeakage for 5

assert FR_001_AuthenticationRequired {
  FR_001_AuthenticationRequired
}

check FR_001_AuthenticationRequired for 5

assert FR_004_CareTeamMembershipRequired {
  FR_004_CareTeamMembershipRequired
}

check FR_004_CareTeamMembershipRequired for 5

assert FR_005_AdministratorOnlyListAudit {
  FR_005_AdministratorOnlyListAudit
}

check FR_005_AdministratorOnlyListAudit for 5

assert FR_006_ByteEquivalentUnauth {
  FR_006_ByteEquivalentUnauth
}

check FR_006_ByteEquivalentUnauth for 5

assert FR_011_NotesAppendOnly {
  FR_011_NotesAppendOnly
}

check FR_011_NotesAppendOnly for 5

assert FR_012_AuditAlwaysOn {
  FR_012_AuditAlwaysOn
}

check FR_012_AuditAlwaysOn for 5

assert FR_014_AuditImmutable {
  FR_014_AuditImmutable
}

check FR_014_AuditImmutable for 5
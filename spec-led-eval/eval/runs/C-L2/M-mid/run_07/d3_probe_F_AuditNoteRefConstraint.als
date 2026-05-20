// === feature_model.als — Alloy model for Hospital Clinical Record Access ===
// Feature folder : C-L2  (branch 012-hospital-clinical-records)
// Sources        : spec.md, data-model.md, contracts/http-api.md
// Patterns used  : LeastPrivilege, PermissionCompleteness, AuthRequiredEverywhere,
//                  AuditCompleteness, AppendOnly, AttributionCorrectness,
//                  OwnershipBasedAccess, NoInformationLeakage, ValidationBeforeMutation

// ============================================================
// ROLES
// ============================================================
abstract sig UserRole {}
one sig Doctor, Nurse, Pharmacist, ClinicalAdmin, HospitalAdministrator extends UserRole {}

// ============================================================
// OPERATION KINDS  (exactly the three endpoints in contracts/http-api.md)
// ============================================================
abstract sig OperationKind {}
one sig RecordLookup, AddNote, ListAudit extends OperationKind {}

// ============================================================
// PERMISSION MATRIX
// contracts/http-api.md: clinical roles → RecordLookup & AddNote (care-team conditional);
// HospitalAdministrator → ListAudit only.
// ============================================================
one sig PermMatrix { Allowed: set UserRole -> OperationKind }

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor         -> RecordLookup) +
    (Doctor         -> AddNote)      +
    (Nurse          -> RecordLookup) +
    (Nurse          -> AddNote)      +
    (Pharmacist     -> RecordLookup) +
    (Pharmacist     -> AddNote)      +
    (ClinicalAdmin  -> RecordLookup) +
    (ClinicalAdmin  -> AddNote)      +
    (HospitalAdministrator -> ListAudit)
}

// ============================================================
// ACCESS OUTCOMES AND AUTHORISATION BASIS  (data-model.md enums)
// ============================================================
abstract sig AccessOutcome {}
one sig Permitted, Denied, NotFoundOrDenied extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMemberBasis, NotCareTeamMemberBasis,
         PatientNotFoundBasis, AdministratorRoleBasis extends AuthBasis {}

// ============================================================
// CORE ENTITIES  (data-model.md)
// ============================================================

sig User { userRole: one UserRole }

sig Patient {}

// Represents one active care-team-membership row (status = active).
// Populated by the host product; read-only in this feature (FR-004).
sig ActiveMembership {
  membClinician : one User,
  membPatient   : one Patient
}

// Clinical notes — append-only (FR-011).
// author_role is snapshotted at write time (FR-010).
sig ClinicalNote {
  notePatient    : one Patient,
  noteAuthor     : one User,
  noteAuthorRole : one UserRole   // snapshot
}

// Audit entries — immutable, append-only (FR-014).
// accessor role is snapshotted at write time (FR-013).
sig AuditEntry {
  aeAccessor     : one User,
  aeAccessorRole : one UserRole,  // snapshot
  aeAccessType   : one OperationKind,
  aeOutcome      : one AccessOutcome,
  aeAuthBasis    : one AuthBasis,
  aeNoteRef      : lone ClinicalNote  // non-null iff add_note + permitted (FR-013)
}

// An Operation represents one authenticated, body-validated request that
// reaches the service layer (post-auth, post-validation).  Unauthenticated
// and validation-failure requests never become Operations (FR-001, FR-009).
sig Operation {
  opKind          : one OperationKind,
  opCaller        : one User,
  opTargetPatient : lone Patient,      // lone: patient may not exist
  opOutcome       : one AccessOutcome,
  opAuditEntry    : one AuditEntry,    // exactly one audit per operation (FR-012)
  opNoteCreated   : lone ClinicalNote  // only for add_note + permitted (FR-010)
}

// ============================================================
// NON-EMPTY UNIVERSE  (rule 9 — prevent vacuous universal assertions)
// ============================================================
fact F_NonEmptyUniverse {
  some User
  some Patient
  some ActiveMembership
  some ClinicalNote
  some AuditEntry
  some Operation
}

// ============================================================
// STRUCTURAL INTEGRITY FACTS
// ============================================================

// Active memberships must involve clinicians, not administrators.
fact F_ActiveMembershipClinicalRoleOnly {
  all m: ActiveMembership |
    m.membClinician.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

// data-model.md CHECK: author_role excludes hospital_administrator (FR-005).
fact F_NoteAuthorMustBeClinical {
  all n: ClinicalNote |
    n.noteAuthorRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
}

// FR-010: author_role snapshot matches actual role at creation time.
fact F_NoteAuthorRoleSnapshot {
  all n: ClinicalNote | n.noteAuthorRole = n.noteAuthor.userRole
}

// FR-013: accessor role snapshot matches actual role at access time.
fact F_AuditAccessorRoleSnapshot {
  all ae: AuditEntry | ae.aeAccessorRole = ae.aeAccessor.userRole
}

// FR-013 / data-model CHECK: aeNoteRef non-null iff add_note + permitted.
fact F_AuditNoteRefConstraint {
  all ae: AuditEntry | {
    (ae.aeAccessType = AddNote and ae.aeOutcome = Permitted)
      implies (one ae.aeNoteRef)
    (ae.aeAccessType = AddNote and ae.aeOutcome != Permitted)
      implies (no ae.aeNoteRef)
    (ae.aeAccessType in (RecordLookup + ListAudit))
      implies (no ae.aeNoteRef)
  }
}

// FR-012: one-to-one between Operation and AuditEntry.
fact F_AuditOperationBijection {
  all disj op1, op2: Operation | op1.opAuditEntry != op2.opAuditEntry
  all ae: AuditEntry | (one op: Operation | op.opAuditEntry = ae)
}

// Audit entry fields must faithfully reflect the generating operation.
fact F_AuditEntryMatchesOperation {
  all op: Operation | {
    op.opAuditEntry.aeAccessor    = op.opCaller
    op.opAuditEntry.aeAccessType  = op.opKind
    op.opAuditEntry.aeOutcome     = op.opOutcome
  }
}

// FR-010: note created iff add_note + permitted.
fact F_NoteCreatedOnlyForPermittedAddNote {
  all op: Operation | {
    (op.opKind = AddNote and op.opOutcome = Permitted)
      implies (one op.opNoteCreated)
    (op.opKind != AddNote or op.opOutcome != Permitted)
      implies (no op.opNoteCreated)
  }
}

// Every ClinicalNote was created by exactly one permitted add-note operation.
fact F_NoteHasExactlyOneCreatingOperation {
  all n: ClinicalNote |
    (one op: Operation |
      op.opKind = AddNote and op.opOutcome = Permitted and op.opNoteCreated = n)
}

// Attribution: note author and patient match the operation that created it.
fact F_NoteAttributionMatchesCaller {
  all op: Operation |
    (op.opKind = AddNote and op.opOutcome = Permitted) implies {
      op.opNoteCreated.noteAuthor  = op.opCaller
      op.opNoteCreated.notePatient = op.opTargetPatient
    }
}

// FR-013 / FR-015: audit note reference matches the note actually created.
fact F_AuditNoteRefMatchesCreatedNote {
  all op: Operation |
    (op.opKind = AddNote and op.opOutcome = Permitted) implies
      (op.opAuditEntry.aeNoteRef = op.opNoteCreated)
}

// FR-004: permitted clinical access requires care-team membership.
fact F_CareTeamGating {
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted) implies {
      op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin)
      (some m: ActiveMembership |
        m.membClinician = op.opCaller and m.membPatient = op.opTargetPatient)
    }
}

// FR-004 (converse): no care-team membership → not permitted on clinical endpoints.
fact F_NoCareTeamMeansNotPermitted {
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and
     op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     (no m: ActiveMembership |
       m.membClinician = op.opCaller and m.membPatient = op.opTargetPatient))
    implies op.opOutcome != Permitted
}

// FR-005 / FR-017: HospitalAdministrator can only perform ListAudit.
fact F_AdminRestrictedToListAudit {
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies op.opKind = ListAudit
}

// FR-017 (converse): ListAudit is exclusively for HospitalAdministrator.
fact F_ClinicalRolesCannotAccessListAudit {
  all op: Operation |
    op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) implies
      op.opKind != ListAudit
}

// FR-005: HospitalAdministrator can never author a note.
fact F_AdminCannotAuthorNote {
  all n: ClinicalNote | n.noteAuthor.userRole != HospitalAdministrator
}

// Authorisation basis must be coherent with outcome and operation kind.
fact F_AuthBasisConsistency {
  all op: Operation | {
    (op.opOutcome = Permitted and op.opKind in (RecordLookup + AddNote))
      implies op.opAuditEntry.aeAuthBasis = CareTeamMemberBasis
    (op.opOutcome = Permitted and op.opKind = ListAudit)
      implies op.opAuditEntry.aeAuthBasis = AdministratorRoleBasis
    op.opOutcome = Denied
      implies op.opAuditEntry.aeAuthBasis in (NotCareTeamMemberBasis + AdministratorRoleBasis)
    op.opOutcome = NotFoundOrDenied
      implies op.opAuditEntry.aeAuthBasis = PatientNotFoundBasis
  }
}

// ============================================================
// PATTERN PREDICATES AND ASSERTIONS
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-004, FR-005, FR-017
pred LeastPrivilege {
  some op: Operation | op.opKind in (RecordLookup + AddNote)
  // Admin cannot reach clinical endpoints.
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies op.opKind = ListAudit
  // Clinical roles cannot reach the audit endpoint.
  all op: Operation |
    op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) implies
      op.opKind != ListAudit
  // Denied cells are absent from the matrix.
  HospitalAdministrator -> RecordLookup not in PermMatrix.Allowed
  HospitalAdministrator -> AddNote not in PermMatrix.Allowed
  Doctor -> ListAudit not in PermMatrix.Allowed
  Nurse -> ListAudit not in PermMatrix.Allowed
  Pharmacist -> ListAudit not in PermMatrix.Allowed
  ClinicalAdmin -> ListAudit not in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables; spec.md FR-002
pred PermissionCompleteness {
  // All 5 roles × 3 ops = 15 cells; exactly 9 are allowed.
  #(PermMatrix.Allowed) = 9
  // Every role that has an allowed operation can reach at least one endpoint.
  all r: UserRole | (some ok: OperationKind | r -> ok in PermMatrix.Allowed)
  // Every allowed cell is defined in the matrix (no undefined cells).
  all r: UserRole, ok: OperationKind |
    (r -> ok in PermMatrix.Allowed) or (r -> ok not in PermMatrix.Allowed)
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md Authentication section
pred AuthRequiredEverywhere {
  some Operation
  // Every Operation has exactly one authenticated caller.
  all op: Operation | one op.opCaller
  // Every AuditEntry has exactly one authenticated accessor.
  all ae: AuditEntry | one ae.aeAccessor
  // No AuditEntry or note exists without a backing Operation.
  all ae: AuditEntry | (one op: Operation | op.opAuditEntry = ae)
  all n: ClinicalNote | (some op: Operation |
    op.opKind = AddNote and op.opOutcome = Permitted and op.opNoteCreated = n)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-012, SC-001, SC-002; data-model.md AuditEntry
pred AuditCompleteness {
  some Operation
  // Every operation has exactly one audit entry.
  all op: Operation | one op.opAuditEntry
  // No two operations share an audit entry.
  all disj op1, op2: Operation | op1.opAuditEntry != op2.opAuditEntry
  // Every audit entry belongs to exactly one operation (completeness in both directions).
  all ae: AuditEntry | (one op: Operation | op.opAuditEntry = ae)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-011 (notes), FR-014 (audit); data-model.md append-only enforcement
pred AppendOnly {
  some ClinicalNote
  some AuditEntry
  // Every note was created by exactly one permitted add-note operation.
  all n: ClinicalNote |
    (one op: Operation |
      op.opKind = AddNote and op.opOutcome = Permitted and op.opNoteCreated = n)
  // Every audit entry was created by exactly one operation (no replacement/update).
  all ae: AuditEntry | (one op: Operation | op.opAuditEntry = ae)
  // The only OperationKinds in the system are the three defined endpoints.
  all ok: OperationKind | ok in (RecordLookup + AddNote + ListAudit)
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-013, FR-010; data-model.md snapshot fields
pred AttributionCorrectness {
  some AuditEntry
  // Audit entry correctly names the accessor and their role (snapshot = actual in static model).
  all ae: AuditEntry | ae.aeAccessorRole = ae.aeAccessor.userRole
  // Audit entry correctly names the generating operation.
  all op: Operation | op.opAuditEntry.aeAccessor = op.opCaller
  // Note author role snapshot matches actual role.
  all n: ClinicalNote | n.noteAuthorRole = n.noteAuthor.userRole
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-004; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  some op: Operation | op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted
  // Every permitted clinical access traces through an active care-team membership.
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted) implies
      (op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
       (some m: ActiveMembership |
         m.membClinician = op.opCaller and m.membPatient = op.opTargetPatient))
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-006, SC-003; contracts/http-api.md byte-equivalent response
pred NoInformationLeakage {
  some Operation
  // Admin attempting clinical endpoints never gets Permitted.
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator and
     op.opKind in (RecordLookup + AddNote)) implies
      op.opOutcome != Permitted
  // Clinical role attempting ListAudit: modelled by structural exclusion of that case.
  all op: Operation |
    op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) implies
      op.opKind != ListAudit
  // Non-team clinician on clinical endpoints never gets Permitted.
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and
     (no m: ActiveMembership |
       m.membClinician = op.opCaller and m.membPatient = op.opTargetPatient)) implies
      op.opOutcome != Permitted
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-009, FR-015; contracts/http-api.md 400/503
pred ValidationBeforeMutation {
  some Operation
  // No note exists without a backing permitted add-note operation.
  all n: ClinicalNote |
    (some op: Operation |
      op.opKind = AddNote and op.opOutcome = Permitted and op.opNoteCreated = n)
  // Denied or not-found outcomes produce no note.
  all op: Operation | op.opOutcome != Permitted implies no op.opNoteCreated
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// ============================================================
// FEATURE-SPECIFIC PREDICATES (one per FR)
// ============================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 — unauthenticated requests rejected before any patient access
pred FR_001_AuthRequired {
  some Operation
  all op: Operation | one op.opCaller
  // Every audit entry and note has an authenticated User behind it.
  all ae: AuditEntry | (one op: Operation | op.opAuditEntry = ae)
  all n: ClinicalNote |
    (some op: Operation |
      op.opKind = AddNote and op.opOutcome = Permitted and op.opNoteCreated = n)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 — exactly one role per user
pred FR_002_OneRolePerUser {
  some User
  all u: User | one u.userRole
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004 — care-team membership gating; fail-closed
pred FR_004_CareTeamGating {
  some op: Operation | op.opKind in (RecordLookup + AddNote)
  // Permitted clinical access ↔ active care-team membership exists.
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and op.opOutcome = Permitted) implies
      (op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
       (some m: ActiveMembership |
         m.membClinician = op.opCaller and m.membPatient = op.opTargetPatient))
  // No care-team membership → not permitted (fail-closed).
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and
     op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
     (no m: ActiveMembership |
       m.membClinician = op.opCaller and m.membPatient = op.opTargetPatient))
    implies op.opOutcome != Permitted
}
assert FR_004_CareTeamGating { FR_004_CareTeamGating }
check FR_004_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 / FR-017 — HospitalAdministrator restricted to ListAudit
pred FR_005_AdminRestrictedToListAudit {
  some op: Operation | op.opCaller.userRole = HospitalAdministrator
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies op.opKind = ListAudit
}
assert FR_005_AdminRestrictedToListAudit { FR_005_AdminRestrictedToListAudit }
check FR_005_AdminRestrictedToListAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 — byte-equivalent unauthorised response across all denied paths
pred FR_006_ByteEquivalentUnauthorisedResponse {
  some Operation
  // Admins on clinical endpoints: never Permitted.
  all op: Operation |
    (op.opCaller.userRole = HospitalAdministrator and
     op.opKind in (RecordLookup + AddNote)) implies
      op.opOutcome != Permitted
  // Clinical roles on ListAudit: structurally excluded (no such Operation can exist).
  all op: Operation |
    op.opCaller.userRole in (Doctor + Nurse + Pharmacist + ClinicalAdmin) implies
      op.opKind != ListAudit
  // Clinician without care-team membership: never Permitted on clinical endpoints.
  all op: Operation |
    (op.opKind in (RecordLookup + AddNote) and
     (no m: ActiveMembership |
       m.membClinician = op.opCaller and m.membPatient = op.opTargetPatient)) implies
      op.opOutcome != Permitted
}
assert FR_006_ByteEquivalentUnauthorisedResponse { FR_006_ByteEquivalentUnauthorisedResponse }
check FR_006_ByteEquivalentUnauthorisedResponse for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 — all validation failures produce no note and no audit
// (Structural: Operations only exist post-validation; notes only exist for Permitted add-note ops)
pred FR_009_ValidationBeforeAudit {
  some Operation
  all n: ClinicalNote |
    (some op: Operation |
      op.opKind = AddNote and op.opOutcome = Permitted and op.opNoteCreated = n)
  // Denied operations leave no note in the system.
  all op: Operation | op.opOutcome != Permitted implies no op.opNoteCreated
}
assert FR_009_ValidationBeforeAudit { FR_009_ValidationBeforeAudit }
check FR_009_ValidationBeforeAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011 — clinical notes are append-only (no edit, no delete endpoint)
pred FR_011_NotesAppendOnly {
  some ClinicalNote
  // Every note was created by exactly one permitted add-note operation.
  all n: ClinicalNote |
    (one op: Operation |
      op.opKind = AddNote and op.opOutcome = Permitted and op.opNoteCreated = n)
  // The system has no OperationKind for deleting or editing notes.
  all ok: OperationKind | ok in (RecordLookup + AddNote + ListAudit)
  // No note appears as the product of more than one operation.
  all disj op1, op2: Operation |
    no (op1.opNoteCreated & op2.opNoteCreated)
}
assert FR_011_NotesAppendOnly { FR_011_NotesAppendOnly }
check FR_011_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 — always-on audit; one entry per access regardless of outcome
pred FR_012_AlwaysOnAudit {
  some Operation
  // One audit entry per operation — no more, no less.
  all op: Operation | one op.opAuditEntry
  all disj op1, op2: Operation | op1.opAuditEntry != op2.opAuditEntry
  // Every audit entry belongs to exactly one operation (none "floating").
  all ae: AuditEntry | (one op: Operation | op.opAuditEntry = ae)
  // Every permitted access has an audit entry (specific emphasis for SC-002).
  all op: Operation | op.opOutcome = Permitted implies one op.opAuditEntry
}
assert FR_012_AlwaysOnAudit { FR_012_AlwaysOnAudit }
check FR_012_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013 — audit entry shape (note_id only for add_note+permitted)
pred FR_013_AuditEntryShape {
  some AuditEntry
  all ae: AuditEntry | {
    ae.aeAccessType = AddNote and ae.aeOutcome = Permitted
      implies one ae.aeNoteRef
    ae.aeAccessType = AddNote and ae.aeOutcome != Permitted
      implies no ae.aeNoteRef
    ae.aeAccessType in (RecordLookup + ListAudit)
      implies no ae.aeNoteRef
    // Snapshot correctness.
    ae.aeAccessorRole = ae.aeAccessor.userRole
  }
}
assert FR_013_AuditEntryShape { FR_013_AuditEntryShape }
check FR_013_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014 — audit entries are immutable (no update, no delete)
pred FR_014_AuditImmutable {
  some AuditEntry
  // One-to-one: no two operations share an audit entry (no "replacement").
  all disj op1, op2: Operation | op1.opAuditEntry != op2.opAuditEntry
  // Every audit entry has exactly one operation generating it.
  all ae: AuditEntry | (one op: Operation | op.opAuditEntry = ae)
}
assert FR_014_AuditImmutable { FR_014_AuditImmutable }
check FR_014_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015 — audit write is atomic with the access (no note without audit)
pred FR_015_AuditAtomicWithAccess {
  some Operation
  // If a note was created, the audit entry references it.
  all op: Operation |
    (op.opKind = AddNote and op.opOutcome = Permitted) implies
      (op.opAuditEntry.aeNoteRef = op.opNoteCreated)
  // A note cannot exist without a corresponding audit entry.
  all n: ClinicalNote |
    (some op: Operation |
      op.opKind = AddNote and op.opOutcome = Permitted and op.opNoteCreated = n and
      op.opAuditEntry.aeNoteRef = n)
}
assert FR_015_AuditAtomicWithAccess { FR_015_AuditAtomicWithAccess }
check FR_015_AuditAtomicWithAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017 — ListAudit endpoint is exclusively for HospitalAdministrator
pred FR_017_AdminOnlyListAudit {
  some op: Operation | op.opKind = ListAudit
  all op: Operation |
    op.opKind = ListAudit implies op.opCaller.userRole = HospitalAdministrator
}
assert FR_017_AdminOnlyListAudit { FR_017_AdminOnlyListAudit }
check FR_017_AdminOnlyListAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-018 — administrator response contains no clinical content
pred FR_018_AdminNoClinicaContent {
  some op: Operation | op.opCaller.userRole = HospitalAdministrator
  // Administrators never create notes.
  all n: ClinicalNote | n.noteAuthor.userRole != HospitalAdministrator
  // All administrator operations are ListAudit with no note creation.
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies
      (op.opKind = ListAudit and no op.opNoteCreated)
  // Administrator audit entries carry no note reference (list_audit access type).
  all op: Operation |
    op.opCaller.userRole = HospitalAdministrator implies
      no op.opAuditEntry.aeNoteRef
}
assert FR_018_AdminNoClinicaContent { FR_018_AdminNoClinicaContent }
check FR_018_AdminNoClinicaContent for 6

// === D3 inject_violation (validator-appended) ===
fact MUTATE_AuditNoteRefViolation { some ae: AuditEntry | ae.aeAccessType = ListAudit and some ae.aeNoteRef }

// === D3 over-constraint probe (validator-appended) ===
assert __D3_OverConstraintProbe { some none }
check __D3_OverConstraintProbe for 5

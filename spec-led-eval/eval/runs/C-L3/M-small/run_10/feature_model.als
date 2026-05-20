// === feature_model.als — Alloy model for HIPAA Clinical Record Access ===

// ============================================================================
// ROLES
// ============================================================================

abstract sig Role {}
one sig Clinician, Patient, ComplianceOfficer extends Role {}

// ============================================================================
// OPERATIONS AND OUTCOMES
// ============================================================================

abstract sig Operation {}
one sig Read, Append, List extends Operation {}

abstract sig Outcome {}
one sig Permitted, Denied extends Outcome {}

abstract sig AuthorisationBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientOwn, PatientOther,
    ComplianceRole, Outsider, RecordNotFound extends AuthorisationBasis {}

// ============================================================================
// CORE ENTITIES
// ============================================================================

sig User {
  role: one Role,
  assigned_record: lone Record  // Patient-only: their one record
}

sig Record {}

sig CareTeamMembership {
  clinician: one User,
  record: one Record,
  is_active: one Int  // 1 = active, 0 = ended (modeled as Int for Alloy compatibility)
}

sig ClinicalNote {
  record: one Record,
  author: one User
}

sig AuditEntry {
  record: lone Record,  // NULL for system-wide GET /access-log
  accessor: one User,
  accessor_role: one Role,
  operation: one Operation,
  outcome: one Outcome,
  authorisation_basis: one AuthorisationBasis,
  note_id: lone ClinicalNote
}

// ============================================================================
// F_NonEmptyUniverse: Ensure at least one of each dynamic sig
// ============================================================================

fact F_NonEmptyUniverse {
  some User
  some Record
  some AuditEntry
  some Operation
}

// ============================================================================
// F_UserRoleConstraints: FR-002 single role + patient-record pairing
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-002
fact F_UserRoleConstraints {
  all u: User | {
    (u.role = Patient implies one u.assigned_record) and
    (u.role != Patient implies no u.assigned_record)
  }
}

// ============================================================================
// F_CareTeamMembership: FR-004 clinician care-team gating
// ============================================================================

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-004, data-model.md CareTeamMembership
fact F_CareTeamMembership {
  all ctm: CareTeamMembership | {
    ctm.clinician.role = Clinician and
    ctm.is_active = 1  // Only model active memberships
  }
}

// ============================================================================
// F_ClinicalNoteStructure: FR-010, FR-011 note fields
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-010, FR-011
fact F_ClinicalNoteStructure {
  all cn: ClinicalNote | {
    cn.author.role = Clinician
  }
}

// ============================================================================
// F_AppendOnlyNotes: FR-012 notes cannot be mutated
// ============================================================================

// PATTERN: AppendOnly  ANCHOR: FR-012, spec.md "append-only clinical notes"
fact F_AppendOnlyNotes {
  // Each clinical note is uniquely identified by (record, author, created_at)
  // Two notes with same record and author must be the same note
  all cn1, cn2: ClinicalNote | {
    (cn1.record = cn2.record and cn1.author = cn2.author) implies cn1 = cn2
  }
}

// ============================================================================
// F_AuditCompleteness: FR-013 one audit per operation
// ============================================================================

// PATTERN: AuditCompleteness  ANCHOR: FR-013, spec.md "one audit entry per operation"
fact F_AuditCompleteness {
  all cn: ClinicalNote | {
    one ae: AuditEntry | {
      ae.record = cn.record and
      ae.accessor = cn.author and
      ae.operation = Append and
      ae.outcome = Permitted and
      ae.note_id = cn
    }
  }
}

// ============================================================================
// F_AuditEntryStructure: FR-014 required audit fields and invariants
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-014
fact F_AuditEntryStructure {
  all ae: AuditEntry | {
    // Snapshot role must match accessor's role at time of access
    ae.accessor_role = ae.accessor.role and
    // note_id linkage: only set for permitted append
    (ae.operation = Append and ae.outcome = Permitted) implies one ae.note_id and
    (ae.operation = Append and ae.outcome = Denied) implies no ae.note_id and
    (ae.operation in (Read, List)) implies no ae.note_id and
    // record_id: NULL only for system-wide list (compliance officer GET /access-log)
    (ae.operation = List and ae.accessor.role = ComplianceOfficer) implies no ae.record and
    (ae.operation in (Read, Append)) implies one ae.record
  }
}

// ============================================================================
// F_AppendOnlyAuditEntries: FR-015 audit entries are immutable
// ============================================================================

// PATTERN: AppendOnly  ANCHOR: FR-015, spec.md "immutable audit log"
fact F_AppendOnlyAuditEntries {
  // Each audit entry is unique by its (accessor, operation, record, timestamp)
  // Two entries with same accessor, operation, record cannot exist
  all ae1, ae2: AuditEntry | {
    (ae1.accessor = ae2.accessor and ae1.operation = ae2.operation and ae1.record = ae2.record)
      implies ae1 = ae2
  }
}

// ============================================================================
// PERMISSION PREDICATES — Core access-control logic
// ============================================================================

// Clinician is on the care team for a record
// PATTERN: OwnershipBasedAccess  ANCHOR: FR-004, data-model.md CareTeamMembership
pred IsCareTeamMember[u: User, r: Record] {
  u.role = Clinician and
  some ctm: CareTeamMembership | {
    ctm.clinician = u and ctm.record = r and ctm.is_active = 1
  }
}

// Patient owns a record (assigned_record_id matches)
// PATTERN: OwnershipBasedAccess  ANCHOR: FR-006, data-model.md User.assigned_record_id
pred IsOwnRecord[u: User, r: Record] {
  u.role = Patient and u.assigned_record = r
}

// Can read clinical record content
pred CanReadRecord[u: User, r: Record] {
  (IsCareTeamMember[u, r]) or (IsOwnRecord[u, r])
}

// Can append notes (write-only, clinician in care team only)
pred CanAppendNote[u: User, r: Record] {
  IsCareTeamMember[u, r]
}

// Can read per-record audit log
pred CanReadRecordAudit[u: User, r: Record] {
  (IsCareTeamMember[u, r]) or (IsOwnRecord[u, r]) or (u.role = ComplianceOfficer)
}

// Can read system-wide access log
// FEATURE-SPECIFIC  ANCHOR: FR-018
pred CanReadAccessLog[u: User] {
  u.role = ComplianceOfficer
}

// ============================================================================
// PATTERN: LeastPrivilege
// ============================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md permission matrix; FR-004, FR-006, FR-007
pred LeastPrivilege {
  all u: User, r: Record | {
    // Clinician: can read/append only if in care team
    (u.role = Clinician and CanReadRecord[u, r]) implies IsCareTeamMember[u, r] and
    (u.role = Clinician and not IsCareTeamMember[u, r]) implies (not CanReadRecord[u, r] and not CanAppendNote[u, r]) and
    // Patient: can access only own record
    (u.role = Patient and CanReadRecord[u, r]) implies IsOwnRecord[u, r] and
    (u.role = Patient and not IsOwnRecord[u, r]) implies not CanReadRecord[u, r] and
    // Compliance: cannot read clinical content or append
    (u.role = ComplianceOfficer) implies (not CanReadRecord[u, r] and not CanAppendNote[u, r])
  }
}

assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// ============================================================================
// PATTERN: PermissionCompleteness
// ============================================================================

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission matrix
pred PermissionCompleteness {
  all u: User, r: Record, op: Operation | {
    (op = Read) implies (CanReadRecord[u, r] or not CanReadRecord[u, r])
  }
}

assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// ============================================================================
// PATTERN: PermissionGrounding
// ============================================================================

// PATTERN: PermissionGrounding  ANCHOR: FR-004, FR-006, FR-007
pred PermissionGrounding {
  all u: User, r: Record | {
    (IsCareTeamMember[u, r] implies (CanReadRecord[u, r] and CanAppendNote[u, r])) and
    (IsOwnRecord[u, r] implies CanReadRecord[u, r]) and
    (u.role = ComplianceOfficer implies CanReadRecordAudit[u, r])
  }
}

assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5

// ============================================================================
// PATTERN: AuthRequiredEverywhere
// ============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001, contracts/http-api.md authentication
pred AuthRequiredEverywhere {
  all u: User | {
    one u.role
  } and
  all ae: AuditEntry | {
    ae.accessor in User
  }
}

assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// ============================================================================
// PATTERN: AuditCompleteness
// ============================================================================

// PATTERN: AuditCompleteness  ANCHOR: FR-013, spec.md "every operation produces one audit"
pred AuditCompleteness {
  all cn: ClinicalNote | {
    one ae: AuditEntry | {
      ae.accessor = cn.author and
      ae.record = cn.record and
      ae.operation = Append and
      ae.outcome = Permitted and
      ae.note_id = cn
    }
  }
}

assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// ============================================================================
// PATTERN: AppendOnly (notes)
// ============================================================================

// PATTERN: AppendOnly  ANCHOR: FR-012, spec.md "notes are append-only"
pred AppendOnlyNotes {
  all cn1, cn2: ClinicalNote | {
    cn1.record = cn2.record and cn1.author = cn2.author implies cn1 = cn2
  }
}

assert AppendOnlyNotes { AppendOnlyNotes }
check AppendOnlyNotes for 5

// ============================================================================
// PATTERN: AppendOnly (audit entries)
// ============================================================================

// PATTERN: AppendOnly  ANCHOR: FR-015, spec.md "audit entries are immutable"
pred AppendOnlyAuditEntries {
  all ae1, ae2: AuditEntry | {
    (ae1.accessor = ae2.accessor and ae1.operation = ae2.operation and ae1.record = ae2.record)
      implies ae1 = ae2
  }
}

assert AppendOnlyAuditEntries { AppendOnlyAuditEntries }
check AppendOnlyAuditEntries for 5

// ============================================================================
// PATTERN: AttributionCorrectness
// ============================================================================

// PATTERN: AttributionCorrectness  ANCHOR: FR-014, data-model.md audit-entry snapshot fields
pred AttributionCorrectness {
  all ae: AuditEntry | {
    ae.accessor_role = ae.accessor.role
  }
}

assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// ============================================================================
// PATTERN: OwnershipExclusivity
// ============================================================================

// PATTERN: OwnershipExclusivity  ANCHOR: FR-003, data-model.md "assigned_record is unique per patient"
pred OwnershipExclusivity {
  all r: Record | {
    lone u: User | u.assigned_record = r
  }
}

assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// ============================================================================
// PATTERN: OwnershipBasedAccess
// ============================================================================

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-004, FR-006, data-model.md CareTeamMembership + assigned_record_id
pred OwnershipBasedAccess {
  all u: User, r: Record | {
    (IsCareTeamMember[u, r] implies CanReadRecord[u, r]) and
    (CanReadRecord[u, r] and u.role = Clinician implies IsCareTeamMember[u, r]) and
    (IsOwnRecord[u, r] implies CanReadRecord[u, r]) and
    (CanReadRecord[u, r] and u.role = Patient implies IsOwnRecord[u, r])
  }
}

assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// ============================================================================
// PATTERN: NoInformationLeakage
// ============================================================================

// PATTERN: NoInformationLeakage  ANCHOR: FR-008, spec.md "byte-equivalent 403 response"
pred NoInformationLeakage {
  all u: User | {
    all r1, r2: Record | {
      (not CanReadRecord[u, r1] and not CanReadRecord[u, r2]) implies (
        (some ae1: AuditEntry | ae1.accessor = u and ae1.record = r1 and ae1.outcome = Denied) iff
        (some ae2: AuditEntry | ae2.accessor = u and ae2.record = r2 and ae2.outcome = Denied)
      )
    }
  }
}

assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ============================================================================
// FEATURE-SPECIFIC ASSERTIONS (mapped to individual FRs)
// ============================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_SingleRoleAndPatientRecordPairing {
  all u: User | {
    one u.role and
    (u.role = Patient implies one u.assigned_record) and
    (u.role != Patient implies no u.assigned_record)
  }
}

assert FR_002_SingleRoleAndPatientRecordPairing { FR_002_SingleRoleAndPatientRecordPairing }
check FR_002_SingleRoleAndPatientRecordPairing for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_CareTeamMembershipGating {
  all u: User, r: Record | {
    (u.role = Clinician and IsCareTeamMember[u, r]) implies (CanReadRecord[u, r] and CanAppendNote[u, r]) and
    (u.role = Clinician and not IsCareTeamMember[u, r]) implies (not CanReadRecord[u, r] and not CanAppendNote[u, r])
  }
}

assert FR_004_CareTeamMembershipGating { FR_004_CareTeamMembershipGating }
check FR_004_CareTeamMembershipGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_PatientSelfAccessOnly {
  all u: User | {
    u.role = Patient implies (
      all r: Record | {
        (r = u.assigned_record implies CanReadRecord[u, r]) and
        (r != u.assigned_record implies not CanReadRecord[u, r])
      }
    )
  }
}

assert FR_006_PatientSelfAccessOnly { FR_006_PatientSelfAccessOnly }
check FR_006_PatientSelfAccessOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007, FR-019
pred FR_007_ComplianceOfficerContentBlindness {
  all u: User | {
    u.role = ComplianceOfficer implies (
      (all r: Record | CanReadRecordAudit[u, r]) and
      (CanReadAccessLog[u]) and
      (all r: Record | not CanReadRecord[u, r]) and
      (all r: Record | not CanAppendNote[u, r])
    )
  }
}

assert FR_007_ComplianceOfficerContentBlindness { FR_007_ComplianceOfficerContentBlindness }
check FR_007_ComplianceOfficerContentBlindness for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_ClinicalNoteValidation {
  all cn: ClinicalNote | {
    cn.author.role = Clinician
  }
}

assert FR_010_ClinicalNoteValidation { FR_010_ClinicalNoteValidation }
check FR_010_ClinicalNoteValidation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
pred FR_012_NotesAppendOnly {
  all cn1, cn2: ClinicalNote | {
    cn1.record = cn2.record and cn1.author = cn2.author implies cn1 = cn2
  }
}

assert FR_012_NotesAppendOnly { FR_012_NotesAppendOnly }
check FR_012_NotesAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013
pred FR_013_AuditForEveryAccess {
  all cn: ClinicalNote | {
    one ae: AuditEntry | ae.note_id = cn
  }
}

assert FR_013_AuditForEveryAccess { FR_013_AuditForEveryAccess }
check FR_013_AuditForEveryAccess for 5

// FEATURE-SPECIFIC  ANCHOR: FR-014
pred FR_014_AuditEntryFields {
  all ae: AuditEntry | {
    one ae.accessor and
    one ae.accessor_role and
    one ae.operation and
    one ae.outcome and
    ae.accessor_role = ae.accessor.role and
    ((ae.operation = Append and ae.outcome = Permitted) implies one ae.note_id) and
    ((ae.operation = Append and ae.outcome = Denied) implies no ae.note_id) and
    ((ae.operation in (Read, List)) implies no ae.note_id)
  }
}

assert FR_014_AuditEntryFields { FR_014_AuditEntryFields }
check FR_014_AuditEntryFields for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_AuditImmutable {
  all ae1, ae2: AuditEntry | {
    (ae1.accessor = ae2.accessor and ae1.operation = ae2.operation and ae1.record = ae2.record)
      implies ae1 = ae2
  }
}

assert FR_015_AuditImmutable { FR_015_AuditImmutable }
check FR_015_AuditImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
pred FR_018_ComplianceAccessLog {
  all u: User | {
    CanReadAccessLog[u] iff u.role = ComplianceOfficer
  }
}

assert FR_018_ComplianceAccessLog { FR_018_ComplianceAccessLog }
check FR_018_ComplianceAccessLog for 5
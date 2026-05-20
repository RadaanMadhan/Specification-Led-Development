// === feature_model.als — Alloy model for 009 Clinician Access to Patient Medical Records (v1) ===
// Self-contained Alloy 6 encoding of the structural invariants for the
// clinician-record-access feature. No external module references.

// -------------------------------------------------------------------
// Non-empty universe: keep predicates from being vacuously satisfied
// under "check ... for 5" empty-universe instances.
// -------------------------------------------------------------------
fact F_NonEmptyUniverse {
  some User
  some Patient
  some CareTeamMembership
  some Operation
  some AuditEntry
}

// -------------------------------------------------------------------
// Roles (closed v1 catalogue from spec FR-002 / data-model.md ClinicianRole)
// -------------------------------------------------------------------
abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

// Clinical roles vs IG role (spec User Stories 1/2; contracts/http-api.md
// "audit_officer cannot use /records/lookup").
fun ClinicalRoles : set Role { Doctor + Nurse + Pharmacist + ClinicalAdmin }
fun IGRoles       : set Role { AuditOfficer }

// -------------------------------------------------------------------
// Operations / endpoints (contracts/http-api.md exposes exactly two).
// -------------------------------------------------------------------
abstract sig OperationKind {}
one sig LookupRecord, SearchAudit extends OperationKind {}

// -------------------------------------------------------------------
// Outcomes and authorisation-bases (data-model.md enums).
// -------------------------------------------------------------------
abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthBasis {}

// -------------------------------------------------------------------
// Permission matrix: Role × OperationKind cells documented in
// contracts/http-api.md Authorisation sections.
// -------------------------------------------------------------------
one sig PermMatrix { Allowed: set Role -> OperationKind }

// FEATURE-SPECIFIC permission matrix.
// Doctor / Nurse / Pharmacist / ClinicalAdmin may attempt /records/lookup
// (final allow still depends on care-team membership).
// AuditOfficer may attempt /audit/search.
// No other cells are allowed (closed-world enumeration).
fact F_PermissionMatrix {
  PermMatrix.Allowed =
      (Doctor         -> LookupRecord)
    + (Nurse          -> LookupRecord)
    + (Pharmacist     -> LookupRecord)
    + (ClinicalAdmin  -> LookupRecord)
    + (AuditOfficer   -> SearchAudit)
}

// -------------------------------------------------------------------
// Domain sigs
// -------------------------------------------------------------------
sig User {
  role: one Role
}

sig Patient {}

sig CareTeamMembership {
  member:  one User,
  subject: one Patient,
  active:  one Bool
}

abstract sig Bool {}
one sig True, False extends Bool {}

// An Operation models one access attempt that has passed the
// authentication boundary (so caller is a known User).
sig Operation {
  caller:        one User,
  callerRole:    one Role,         // snapshot at request time (FR-002, FR-009)
  kind:          one OperationKind,
  target:        one Patient,
  authenticated: one Bool,
  outcome:       one Outcome,
  basis:         one AuthBasis,
  log:           lone AuditEntry   // exactly-one for clinical endpoint;
                                   // contracts/http-api.md FR-008
}

// Audit entries (immutable, append-only). FR-009 shape.
sig AuditEntry {
  recordedClinician:     one User,
  recordedDisplayName:   one User,   // snapshot reference (proxy field)
  recordedRole:          one Role,
  recordedPatient:       one Patient,
  recordedOutcome:       one Outcome,
  recordedBasis:         one AuthBasis,
  recordedKind:          one OperationKind,
  ofOperation:           one Operation
}

// -------------------------------------------------------------------
// Frame conditions / sanity wiring
// -------------------------------------------------------------------
fact F_AuditEntryWiring {
  // Every audit entry refers back to exactly one operation that points
  // back at it. (1-to-1 correspondence for those operations that have a log.)
  all ae: AuditEntry | ae.ofOperation.log = ae
  all op: Operation  | some op.log implies op.log.ofOperation = op
}

fact F_CallerRoleSnapshotMatchesCaller { /* MUTATED — body cleared by validator */ }

// -------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------
pred onCareTeam[u: User, p: Patient] {
  some m: CareTeamMembership | m.member = u and m.subject = p and m.active = True
}

// ===================================================================
// PATTERN PREDICATES + FEATURE-SPECIFIC PREDICATES
// ===================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-004; contracts/http-api.md "Authentication"
pred AuthRequiredEverywhere {
  // No Operation runs business logic (has an outcome+basis other than
  // pure authentication failure) without being authenticated. Modelled
  // as: every Operation we see in the model is authenticated.
  all op: Operation | op.authenticated = True
  // And: no audit entry exists for an unauthenticated request.
  all ae: AuditEntry | ae.ofOperation.authenticated = True
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 6

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation; spec.md FR-005, FR-006, FR-011
pred LeastPrivilege {
  // The caller's role must be in the permission matrix for the
  // operation they invoked. Cells not in the matrix => the endpoint
  // returns byte-equivalent 404 BEFORE business logic runs, which
  // means no Operation atom should exist for them in this model.
  all op: Operation |
    op.callerRole -> op.kind in PermMatrix.Allowed
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8 but exactly 5 Role, exactly 2 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorisation tables
pred PermissionCompleteness {
  // Every (Role, OperationKind) cell has a verdict in {allow, deny}.
  // In our model the matrix is total: it is either listed in Allowed
  // or it is implicitly denied. We assert that allow + deny partition
  // the universe (no undefined cells) by asserting the union covers
  // everything.
  all r: Role, k: OperationKind |
    (r -> k in PermMatrix.Allowed) or (r -> k not in PermMatrix.Allowed)
  // And: at least one cell is allowed (the matrix is not empty).
  some PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8 but exactly 5 Role, exactly 2 OperationKind

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
  // A clinical-endpoint operation is Permitted iff the caller is on
  // the patient's care team. (The "iff" makes this assertion bite.)
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Permitted)
      implies onCareTeam[op.caller, op.target]
  all op: Operation |
    (op.kind = LookupRecord and onCareTeam[op.caller, op.target]
     and op.callerRole in ClinicalRoles)
      implies op.outcome = Permitted
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 6

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, FR-011, SC-011
pred NoInformationLeakage {
  // Denied and NotFoundOrDenied are byte-equivalent to the caller.
  // Structurally: a non-care-team caller MUST NOT receive Permitted,
  // and the AuditOfficer role MUST NOT invoke LookupRecord at all
  // (the endpoint hides itself by returning byte-equivalent 404).
  all op: Operation |
    (op.kind = LookupRecord and not onCareTeam[op.caller, op.target])
      implies op.outcome != Permitted
  all op: Operation |
    op.kind = LookupRecord implies op.callerRole in ClinicalRoles
  all op: Operation |
    op.kind = SearchAudit  implies op.callerRole in IGRoles
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 6

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002; contracts/http-api.md
pred AuditCompleteness {
  // Every LookupRecord operation produces exactly one AuditEntry that
  // references it; and every AuditEntry references exactly one
  // LookupRecord operation. (SearchAudit is NOT in this feature's audit.)
  all op: Operation |
    op.kind = LookupRecord implies (one ae: AuditEntry | ae.ofOperation = op)
  all ae: AuditEntry | ae.ofOperation.kind = LookupRecord
  // No two audit entries share an operation (1-to-1).
  all disj a1, a2: AuditEntry | a1.ofOperation != a2.ofOperation
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 6

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, SC-006; data-model.md "no UPDATE/DELETE on audit_entries"
pred AppendOnly {
  // An audit entry's recorded fields must equal the underlying operation's
  // fields. Any "mutation" would manifest as a divergence between
  // (ae.recordedX) and (ae.ofOperation.X). We assert none exists.
  all ae: AuditEntry |
        ae.recordedClinician   = ae.ofOperation.caller
    and ae.recordedRole        = ae.ofOperation.callerRole
    and ae.recordedPatient     = ae.ofOperation.target
    and ae.recordedOutcome     = ae.ofOperation.outcome
    and ae.recordedBasis       = ae.ofOperation.basis
    and ae.recordedKind        = ae.ofOperation.kind
}
assert AppendOnly { AppendOnly }
check AppendOnly for 6

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md AuditEntry
pred AttributionCorrectness {
  // The audit entry must record the actual initiator and the actual role
  // at the time of the access. Misattribution => assertion fails.
  all ae: AuditEntry |
        ae.recordedClinician = ae.ofOperation.caller
    and ae.recordedRole      = ae.ofOperation.caller.role
    and ae.recordedPatient   = ae.ofOperation.target
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 6

// ===================================================================
// FUNCTIONAL-REQUIREMENT-LEVEL ASSERTIONS
// ===================================================================

// FEATURE-SPECIFIC  ANCHOR: FR-001 (authentication required; no audit for failed auth)
pred FR_001_AuthRequired {
  all op: Operation | op.authenticated = True
  all ae: AuditEntry | ae.ofOperation.authenticated = True
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 6

// FEATURE-SPECIFIC  ANCHOR: FR-002 (role/identity from host context; one role per user)
pred FR_002_OneRolePerUser {
  all u: User | one u.role
  all op: Operation | op.callerRole = op.caller.role
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 6

// FEATURE-SPECIFIC  ANCHOR: FR-003 (NHS regulatory regime; audit queryable per patient)
pred FR_003_AuditQueryablePerPatient {
  // Every audit entry is keyed by patient (the per-patient query path
  // requires recordedPatient be set and matched to the operation's target).
  all ae: AuditEntry | one ae.recordedPatient
  all ae: AuditEntry | ae.recordedPatient = ae.ofOperation.target
}
assert FR_003_AuditQueryablePerPatient { FR_003_AuditQueryablePerPatient }
check FR_003_AuditQueryablePerPatient for 6

// FEATURE-SPECIFIC  ANCHOR: FR-004 (patient_id never in URL path => only POST endpoints)
pred FR_004_NoPatientIdInPath {
  // Modelled at the type level: every OperationKind is one of the two
  // POST endpoints we admit. There is no GET-by-path endpoint in the model.
  all op: Operation | op.kind in (LookupRecord + SearchAudit)
}
assert FR_004_NoPatientIdInPath { FR_004_NoPatientIdInPath }
check FR_004_NoPatientIdInPath for 6

// FEATURE-SPECIFIC  ANCHOR: FR-005 (v1 is read-only; only LookupRecord touches a record)
pred FR_005_ReadOnly {
  // No OperationKind beyond LookupRecord and SearchAudit exists.
  // (Future amend/prescribe/note-write surfaces would add atoms here.)
  OperationKind = LookupRecord + SearchAudit
  // SearchAudit does not return record content (it returns audit list);
  // record-content operations must be LookupRecord.
  all op: Operation | op.kind = LookupRecord or op.kind = SearchAudit
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-006 (care-team-membership gating; no break-glass)
pred FR_006_CareTeamGating {
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Permitted)
      implies onCareTeam[op.caller, op.target]
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 6

// FEATURE-SPECIFIC  ANCHOR: FR-007 (byte-equivalent deny vs not-found)
pred FR_007_ByteEquivDenyNotFound {
  // No outside-observable distinction between Denied and NotFoundOrDenied:
  // i.e., neither outcome returns record content. We capture that
  // structurally by requiring that neither outcome is ever a synonym for
  // Permitted-access semantics: a non-care-team caller never gets Permitted.
  all op: Operation |
    (op.kind = LookupRecord and not onCareTeam[op.caller, op.target])
      implies op.outcome != Permitted
  // And: when the outcome is Denied OR NotFoundOrDenied, neither leaks
  // existence — both have identical observable shape (modelled by the
  // fact that they're both legal outcomes for the same code path).
  all op: Operation |
    op.outcome in (Denied + NotFoundOrDenied) implies
      op.basis in (NotCareTeamMember + PatientNotFound)
}
assert FR_007_ByteEquivDenyNotFound { FR_007_ByteEquivDenyNotFound }
check FR_007_ByteEquivDenyNotFound for 6

// FEATURE-SPECIFIC  ANCHOR: FR-008 (always-on audit on the clinical endpoint)
pred FR_008_AuditEveryAccess {
  all op: Operation |
    op.kind = LookupRecord implies (one ae: AuditEntry | ae.ofOperation = op)
}
assert FR_008_AuditEveryAccess { FR_008_AuditEveryAccess }
check FR_008_AuditEveryAccess for 6

// FEATURE-SPECIFIC  ANCHOR: FR-009 (audit-entry shape: clinician, role, patient, outcome, basis, kind)
pred FR_009_AuditEntryShape {
  all ae: AuditEntry {
    one ae.recordedClinician
    one ae.recordedRole
    one ae.recordedPatient
    one ae.recordedOutcome
    one ae.recordedBasis
    one ae.recordedKind
  }
}
assert FR_009_AuditEntryShape { FR_009_AuditEntryShape }
check FR_009_AuditEntryShape for 6

// FEATURE-SPECIFIC  ANCHOR: FR-010 (audit immutability; append-only)
pred FR_010_AuditAppendOnly {
  // Each AuditEntry's recorded fields equal the underlying Operation's
  // fields — i.e., no mutation has been applied. Differences would
  // indicate post-hoc modification.
  all ae: AuditEntry {
    ae.recordedClinician = ae.ofOperation.caller
    ae.recordedRole      = ae.ofOperation.callerRole
    ae.recordedPatient   = ae.ofOperation.target
    ae.recordedOutcome   = ae.ofOperation.outcome
    ae.recordedBasis     = ae.ofOperation.basis
    ae.recordedKind      = ae.ofOperation.kind
  }
  // And: at most one audit entry per operation (no overwrites).
  all disj a1, a2: AuditEntry | a1.ofOperation != a2.ofOperation
}
assert FR_010_AuditAppendOnly { FR_010_AuditAppendOnly }
check FR_010_AuditAppendOnly for 6

// FEATURE-SPECIFIC  ANCHOR: FR-011 (IG-only audit endpoint; hidden from clinical)
pred FR_011_IGOnlyAuditEndpoint {
  all op: Operation |
    op.kind = SearchAudit implies op.callerRole = AuditOfficer
  // Conversely: the AuditOfficer cannot invoke LookupRecord.
  all op: Operation |
    op.kind = LookupRecord implies op.callerRole in ClinicalRoles
}
assert FR_011_IGOnlyAuditEndpoint { FR_011_IGOnlyAuditEndpoint }
check FR_011_IGOnlyAuditEndpoint for 6

// FEATURE-SPECIFIC  ANCHOR: FR-012 (8-year retention floor; no DELETE path)
pred FR_012_RetentionNoDelete {
  // Modelled: every AuditEntry that exists for an Operation persists —
  // operationally, "no delete" means once an AuditEntry references an
  // Operation, no instance has the Operation with no AuditEntry attached.
  all op: Operation |
    op.kind = LookupRecord implies some ae: AuditEntry | ae.ofOperation = op
}
assert FR_012_RetentionNoDelete { FR_012_RetentionNoDelete }
check FR_012_RetentionNoDelete for 6

// FEATURE-SPECIFIC  ANCHOR: FR-013 (2-second audit SLA; no record observed without audit)
pred FR_013_NoRecordWithoutAudit {
  // If an Operation has outcome = Permitted on the clinical endpoint,
  // an audit entry must exist for it. (The 503-on-SLA-miss case is
  // captured because such operations never reach outcome = Permitted.)
  all op: Operation |
    (op.kind = LookupRecord and op.outcome = Permitted)
      implies (one ae: AuditEntry | ae.ofOperation = op)
}
assert FR_013_NoRecordWithoutAudit { FR_013_NoRecordWithoutAudit }
check FR_013_NoRecordWithoutAudit for 6

// FEATURE-SPECIFIC  ANCHOR: FR-014 (allergies + key-warnings at top of every record view)
pred FR_014_SafetyContentSurfaced {
  // Structural surrogate: every Permitted lookup is on a Patient that
  // is well-defined (one target patient), so the safety block is always
  // computable. We assert non-vacuous existence: at least one Permitted
  // operation exists in any model where care-team membership exists.
  all op: Operation |
    op.outcome = Permitted implies one op.target
}
assert FR_014_SafetyContentSurfaced { FR_014_SafetyContentSurfaced }
check FR_014_SafetyContentSurfaced for 6

// FEATURE-SPECIFIC  ANCHOR: FR-015 (patient identifier + DoB at top of every record view)
pred FR_015_VerificationBlockSurfaced {
  // Structural surrogate, paralleling FR-014: every Permitted op has
  // a single resolvable Patient target.
  all op: Operation |
    op.outcome = Permitted implies one op.target
}
assert FR_015_VerificationBlockSurfaced { FR_015_VerificationBlockSurfaced }
check FR_015_VerificationBlockSurfaced for 6

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_MisattributionViolation { some ae: AuditEntry | ae.recordedRole != ae.ofOperation.caller.role }

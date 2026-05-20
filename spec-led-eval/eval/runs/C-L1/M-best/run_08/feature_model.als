// === feature_model.als — Alloy model for Clinician Access to Patient Medical Records (009-clinician-record-access) ===
//
// Spec-led structural encoding of the v1 narrow-scope clinician record access feature:
//   - Q1 = A (UK NHS regulatory regime)
//   - Q2 = A (read-only)
//   - Q3 = A (care-team membership; no break-glass)
//
// Two endpoints: POST /records/lookup (clinical roles) and POST /audit/search (audit_officer).
// Always-on, append-only audit log; byte-equivalent denial; care-team gating.

// --------------------------------------------------------------------
// Roles & Operation kinds
// --------------------------------------------------------------------

abstract sig Role {}
one sig Doctor, Nurse, Pharmacist, AuditOfficer, ClinicalAdmin extends Role {}

abstract sig OperationKind {}
one sig RecordsLookup, AuditSearch extends OperationKind {}

// Permission matrix as a singleton-sig field (Role -> OperationKind).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// --------------------------------------------------------------------
// Domain sigs
// --------------------------------------------------------------------

sig DisplayName {}
sig User { role: one Role, displayName: one DisplayName }
sig Patient {}

abstract sig MembershipStatus {}
one sig MembershipActive, MembershipEnded extends MembershipStatus {}

sig CareTeamMembership {
  member:  one User,
  patient: one Patient,
  status:  one MembershipStatus
}

abstract sig Outcome {}
one sig Permitted, Denied, NotFoundOrDenied extends Outcome {}

abstract sig AuthBasis {}
one sig CareTeamMember, NotCareTeamMember, PatientNotFound extends AuthBasis {}

abstract sig AccessType {}
one sig ReadAccess extends AccessType {}

// Marker singletons used as "did this phase happen" flags on an Operation.
one sig ServiceFlag {}
one sig RecordFlag {}

sig Operation {
  kind:             one  OperationKind,
  caller:           lone User,           // none ⇒ unauthenticated
  presentedPatient: lone Patient,        // none ⇒ patient_id did not resolve
  reachedService:   lone ServiceFlag,    // marker: passed auth + validation
  recordReturned:   lone RecordFlag,     // marker: record content was returned
  result:           lone Outcome,
  basis:            lone AuthBasis
}

sig AuditEntry {
  op:               one  Operation,
  clinician:        one  User,
  roleSnapshot:     one  Role,
  nameSnapshot:     one  DisplayName,
  presentedPatient: lone Patient,
  outcome:          one  Outcome,
  basis:            one  AuthBasis,
  accessType:       one  AccessType
}

// --------------------------------------------------------------------
// Non-empty universe (one fact, at the top)
// --------------------------------------------------------------------

fact F_NonEmptyUniverse {
  some User
  some DisplayName
  some Patient
  some CareTeamMembership
  some Operation
  some AuditEntry
}

// --------------------------------------------------------------------
// Permission matrix (from contracts/http-api.md)
// --------------------------------------------------------------------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (Doctor         -> RecordsLookup) +
    (Nurse          -> RecordsLookup) +
    (Pharmacist     -> RecordsLookup) +
    (ClinicalAdmin  -> RecordsLookup) +
    (AuditOfficer   -> AuditSearch)
}

// --------------------------------------------------------------------
// Core structural facts (each is a single named, mutation-testable fact)
// --------------------------------------------------------------------

// FR-001: an unauthenticated operation never reaches the service layer.
fact F_AuthRequiredBeforeService {
  all op: Operation | no op.caller implies no op.reachedService
}

// FR-001 / FR-008: no audit entry is written for an unauthenticated request.
fact F_NoAuditWithoutCaller {
  all ae: AuditEntry | some ae.op.caller
}

// Returning record content requires the service layer to have been reached.
fact F_NoRecordWithoutService {
  all op: Operation | some op.recordReturned implies some op.reachedService
}

// FR-005 / FR-011 / LeastPrivilege: only (Role, Kind) cells in the matrix reach service.
fact F_RoleKindAuthorization {
  all op: Operation |
    some op.reachedService implies
      op.caller.role -> op.kind in PermMatrix.Allowed
}

// FR-006 / OwnershipBasedAccess: record content requires active care-team membership.
fact F_CareTeamRequiredForRecord {
  all op: Operation |
    some op.recordReturned implies
      (some m: CareTeamMembership |
         m.member  = op.caller    and
         m.patient = op.presentedPatient and
         m.status  = MembershipActive)
}

// FR-007 / NoInformationLeakage: deny and not-found outcomes return no record bytes.
fact F_NoRecordOnDenyOrNotFound {
  all op: Operation |
    (op.result = Denied or op.result = NotFoundOrDenied) implies no op.recordReturned
}

// A serviced RecordsLookup always has a recorded outcome.
fact F_ResultPresenceForServicedLookup {
  all op: Operation |
    (op.kind = RecordsLookup and some op.reachedService) iff some op.result
}

// Basis is present iff a result is present.
fact F_BasisPresenceMatchesResult {
  all op: Operation | some op.result iff some op.basis
}

// A "permitted" outcome actually returns record content (success case is observable).
fact F_PermittedReturnsRecord {
  all op: Operation | op.result = Permitted implies some op.recordReturned
}

// FR-008 / AuditCompleteness: exactly one audit entry per serviced RecordsLookup.
fact F_AuditOnEveryClinicalServiceOp {
  all op: Operation |
    (op.kind = RecordsLookup and some op.reachedService) implies
      (one ae: AuditEntry | ae.op = op)
}

// FR-011 plumbing: AuditSearch operations are not audited in this feature's table.
fact F_NoAuditForAuditSearch {
  all ae: AuditEntry | ae.op.kind = RecordsLookup
}

// FR-009 / AttributionCorrectness: audit fields snapshot the operation truthfully.
fact F_AuditAttribution {
  all ae: AuditEntry |
    ae.clinician        = ae.op.caller             and
    ae.roleSnapshot     = ae.op.caller.role        and
    ae.nameSnapshot     = ae.op.caller.displayName and
    ae.presentedPatient = ae.op.presentedPatient   and
    ae.outcome          = ae.op.result             and
    ae.basis            = ae.op.basis
}

// FR-010 / AppendOnly: at most one audit row exists for any given operation.
fact F_AppendOnlyAuditOneToOne {
  all disj a, b: AuditEntry | a.op != b.op
}

// FR-005: v1 audit access_type is always "read".
fact F_AccessTypeAlwaysRead {
  all ae: AuditEntry | ae.accessType = ReadAccess
}

// --------------------------------------------------------------------
// PATTERN PREDICATES / ASSERTIONS
// --------------------------------------------------------------------

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md auth tables; spec.md FR-005, FR-011
pred LeastPrivilege {
  all op: Operation |
    some op.reachedService implies
      (some op.caller and op.caller.role -> op.kind in PermMatrix.Allowed)
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md auth tables
pred PermissionCompleteness {
  // every explicit allow is present
  Doctor        -> RecordsLookup in PermMatrix.Allowed
  Nurse         -> RecordsLookup in PermMatrix.Allowed
  Pharmacist    -> RecordsLookup in PermMatrix.Allowed
  ClinicalAdmin -> RecordsLookup in PermMatrix.Allowed
  AuditOfficer  -> AuditSearch   in PermMatrix.Allowed
  // every explicit deny is absent
  AuditOfficer  -> RecordsLookup not in PermMatrix.Allowed
  Doctor        -> AuditSearch   not in PermMatrix.Allowed
  Nurse         -> AuditSearch   not in PermMatrix.Allowed
  Pharmacist    -> AuditSearch   not in PermMatrix.Allowed
  ClinicalAdmin -> AuditSearch   not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001, SC-004
pred AuthRequiredEverywhere {
  all op: Operation |
    no op.caller implies (no op.reachedService and no op.recordReturned)
  all ae: AuditEntry | some ae.op.caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, FR-009, SC-001
pred AuditCompleteness {
  all op: Operation |
    (op.kind = RecordsLookup and some op.reachedService) implies
      (one ae: AuditEntry | ae.op = op)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012, SC-006
pred AppendOnly {
  all disj a, b: AuditEntry | a.op != b.op
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009 (snapshot semantics)
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.clinician    = ae.op.caller and
    ae.roleSnapshot = ae.op.caller.role and
    ae.nameSnapshot = ae.op.caller.displayName
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006 (care-team membership), SC-010
pred OwnershipBasedAccess {
  all op: Operation |
    some op.recordReturned implies
      (some m: CareTeamMembership |
         m.member  = op.caller and
         m.patient = op.presentedPatient and
         m.status  = MembershipActive)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 8

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011
pred NoInformationLeakage {
  all op: Operation |
    (op.result = Denied or op.result = NotFoundOrDenied) implies no op.recordReturned
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 8

// --------------------------------------------------------------------
// FEATURE-SPECIFIC FR PREDICATES (one per FR-NNN where structurally meaningful)
// --------------------------------------------------------------------

// FEATURE-SPECIFIC  ANCHOR: FR-001 authentication boundary
pred FR_001_AuthRequired {
  all op: Operation | no op.caller implies no op.reachedService
  all ae: AuditEntry | some ae.op.caller
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 catalogue of clinician roles
pred FR_002_RoleFromCatalogue {
  all u: User |
    u.role in (Doctor + Nurse + Pharmacist + AuditOfficer + ClinicalAdmin)
}
assert FR_002_RoleFromCatalogue { FR_002_RoleFromCatalogue }
check FR_002_RoleFromCatalogue for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 read-only access type in v1
pred FR_005_ReadOnly {
  all ae: AuditEntry | ae.accessType = ReadAccess
}
assert FR_005_ReadOnly { FR_005_ReadOnly }
check FR_005_ReadOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 care-team membership gates record content
pred FR_006_CareTeamGating {
  all op: Operation |
    some op.recordReturned implies
      (some m: CareTeamMembership |
         m.member  = op.caller and
         m.patient = op.presentedPatient and
         m.status  = MembershipActive)
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 byte-equivalent denial / not-found
pred FR_007_ByteEquivalentDeny {
  all op: Operation |
    (op.result = Denied or op.result = NotFoundOrDenied) implies no op.recordReturned
}
assert FR_007_ByteEquivalentDeny { FR_007_ByteEquivalentDeny }
check FR_007_ByteEquivalentDeny for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 one audit entry per clinical access attempt
pred FR_008_OneAuditPerAccess {
  all op: Operation |
    (op.kind = RecordsLookup and some op.reachedService) implies
      (one ae: AuditEntry | ae.op = op)
}
assert FR_008_OneAuditPerAccess { FR_008_OneAuditPerAccess }
check FR_008_OneAuditPerAccess for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 audit entry fields & snapshot semantics
pred FR_009_AuditFields {
  all ae: AuditEntry |
    ae.clinician        = ae.op.caller             and
    ae.roleSnapshot     = ae.op.caller.role        and
    ae.nameSnapshot     = ae.op.caller.displayName and
    ae.outcome          = ae.op.result             and
    ae.basis            = ae.op.basis              and
    ae.accessType       = ReadAccess
}
assert FR_009_AuditFields { FR_009_AuditFields }
check FR_009_AuditFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 audit immutability / append-only
pred FR_010_AuditAppendOnly {
  all disj a, b: AuditEntry | a.op != b.op
}
assert FR_010_AuditAppendOnly { FR_010_AuditAppendOnly }
check FR_010_AuditAppendOnly for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 audit search visible only to AuditOfficer
pred FR_011_IGOnlyAuditSearch {
  all op: Operation |
    (op.kind = AuditSearch and some op.reachedService) implies
      op.caller.role = AuditOfficer
}
assert FR_011_IGOnlyAuditSearch { FR_011_IGOnlyAuditSearch }
check FR_011_IGOnlyAuditSearch for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 no record observation without a matching audit
pred FR_013_NoRecordWithoutAudit {
  all op: Operation |
    some op.recordReturned implies
      (one ae: AuditEntry | ae.op = op and ae.outcome = Permitted)
}
assert FR_013_NoRecordWithoutAudit { FR_013_NoRecordWithoutAudit }
check FR_013_NoRecordWithoutAudit for 8
// === feature_model.als — Alloy 6 model for C-L1: Clinician Access to Patient Medical Records ===
// Feature folder: C-L1  (branch 009-clinician-record-access, v1, read-only, care-team auth)
// Generated from spec.md, data-model.md, contracts/http-api.md

// ===================================================================
// ROLES
// ===================================================================
abstract sig Role {}
one sig Doctor       extends Role {}
one sig Nurse        extends Role {}
one sig Pharmacist   extends Role {}
one sig AuditOfficer extends Role {}
one sig ClinicalAdmin extends Role {}

// ===================================================================
// OPERATION KINDS (the two endpoints in the API contract)
// ===================================================================
abstract sig OperationKind {}
one sig PostRecordsLookup extends OperationKind {}   // POST /records/lookup
one sig PostAuditSearch   extends OperationKind {}   // POST /audit/search

// ===================================================================
// PERMISSION MATRIX — singleton carrier
// (see contracts/http-api.md Authorisation sections)
// ===================================================================
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ===================================================================
// ENUMERATIONS
// ===================================================================
abstract sig MembershipStatus {}
one sig Active extends MembershipStatus {}
one sig Ended  extends MembershipStatus {}

abstract sig AccessOutcome {}
one sig Permitted         extends AccessOutcome {}
one sig Denied            extends AccessOutcome {}
one sig NotFoundOrDenied  extends AccessOutcome {}

abstract sig AuthBasis {}
one sig CareTeamMember    extends AuthBasis {}
one sig NotCareTeamMember extends AuthBasis {}
one sig PatientNotFound   extends AuthBasis {}

abstract sig AuthStatus {}
one sig Authenticated   extends AuthStatus {}
one sig Unauthenticated extends AuthStatus {}

// What the caller observes in the HTTP response
abstract sig ResponseShape {}
one sig RecordContent    extends ResponseShape {}   // 200 with patient summary
one sig NotFoundResponse extends ResponseShape {}   // 404 byte-equivalent not-found
// (401 / 400 / 503 are modelled as absent outcome, not as ResponseShape atoms)

// ===================================================================
// DOMAIN ENTITIES
// ===================================================================
sig User { userRole: one Role }

sig Patient {}

sig CareTeamMembership {
    ctmClinician : one User,
    ctmPatient   : one Patient,
    ctmStatus    : one MembershipStatus
}

// Immutable audit record; every field is a snapshot (FR-009).
sig AuditEntry {
    aeClinician     : one User,
    aeSnapshotRole  : one Role,
    aePatient       : one Patient,
    aeOutcome       : one AccessOutcome,
    aeAuthBasis     : one AuthBasis
}

// One AccessRequest per service invocation attempt.
// Fields are `lone` for cases where auth fails or patient is absent.
sig AccessRequest {
    reqAuthStatus   : one AuthStatus,
    reqCaller       : lone User,          // present iff Authenticated
    reqKind         : one OperationKind,
    reqTargetPatient: lone Patient,       // absent when patient_id yields no real patient
    reqOutcome      : lone AccessOutcome, // absent when Unauthenticated
    reqAuditEntry   : lone AuditEntry,    // absent when Unauthenticated
    reqResponse     : lone ResponseShape  // absent when Unauthenticated
}

// ===================================================================
// FACTS — NAMED, MUTATION-TESTABLE
// ===================================================================

// -------------------------------------------------------------------
// F_NonEmptyUniverse
// Every dynamic sig has at least one atom so predicates are non-vacuous.
// -------------------------------------------------------------------
fact F_NonEmptyUniverse {
    some User
    some Patient
    some CareTeamMembership
    some AuditEntry
    some AccessRequest
}

// -------------------------------------------------------------------
// F_PermissionMatrix
// Closed-world permission matrix from contracts/http-api.md.
// Clinical roles → PostRecordsLookup only.
// AuditOfficer   → PostAuditSearch only.
// -------------------------------------------------------------------
fact F_PermissionMatrix {
    PermMatrix.Allowed =
        (Doctor       -> PostRecordsLookup) +
        (Nurse        -> PostRecordsLookup) +
        (Pharmacist   -> PostRecordsLookup) +
        (ClinicalAdmin -> PostRecordsLookup) +
        (AuditOfficer -> PostAuditSearch)
}

// -------------------------------------------------------------------
// F_CallerConsistency
// A request carries a caller iff it is authenticated.
// -------------------------------------------------------------------
fact F_CallerConsistency {
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated) iff (one req.reqCaller)
}

// -------------------------------------------------------------------
// F_UnauthenticatedProducesNoAuditEntry
// FR-001: unauthenticated requests are rejected at the boundary — no audit,
// no outcome, no response content.
// -------------------------------------------------------------------
fact F_UnauthenticatedProducesNoAuditEntry {
    all req: AccessRequest |
        req.reqAuthStatus = Unauthenticated implies
            (no req.reqAuditEntry and no req.reqOutcome and no req.reqResponse)
}

// -------------------------------------------------------------------
// F_AuthenticatedProducesAuditEntry
// FR-008: every authenticated, dispatched request produces exactly one
// audit entry and one outcome.
// -------------------------------------------------------------------
fact F_AuthenticatedProducesAuditEntry {
    all req: AccessRequest |
        req.reqAuthStatus = Authenticated implies
            (one req.reqAuditEntry and one req.reqOutcome and one req.reqResponse)
}

// -------------------------------------------------------------------
// F_AppendOnlyAuditEntries
// FR-010, SC-006: no two AccessRequests share an AuditEntry;
// each entry is created once and never re-used or mutated.
// -------------------------------------------------------------------
fact F_AppendOnlyAuditEntries {
    all disj req1, req2: AccessRequest |
        (one req1.reqAuditEntry and one req2.reqAuditEntry) implies
            req1.reqAuditEntry != req2.reqAuditEntry
}

// -------------------------------------------------------------------
// F_AuditAttributionCorrect
// FR-009: snapshot clinician and snapshot role in the audit entry match
// the actual caller and their role at the time of the request.
// -------------------------------------------------------------------
fact F_AuditAttributionCorrect {
    all req: AccessRequest |
        req.reqAuthStatus = Authenticated implies {
            req.reqAuditEntry.aeClinician    = req.reqCaller
            req.reqAuditEntry.aeSnapshotRole = req.reqCaller.userRole
            req.reqAuditEntry.aeOutcome      = req.reqOutcome
        }
}

// -------------------------------------------------------------------
// F_AuditPatientRecorded
// FR-008, FR-009: when a real patient atom is present, the audit entry
// records it. (Patient not found = PatientNotFound AuthBasis is still logged.)
// -------------------------------------------------------------------
fact F_AuditPatientRecorded {
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and some req.reqTargetPatient) implies
            req.reqAuditEntry.aePatient = req.reqTargetPatient
}

// -------------------------------------------------------------------
// F_CareTeamMembershipGating
// FR-006, SC-010: for PostRecordsLookup, Permitted iff the caller holds
// a clinical role AND has an Active care-team-membership for the target patient.
// -------------------------------------------------------------------
fact F_CareTeamMembershipGating {
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and req.reqKind = PostRecordsLookup) implies {
            (req.reqOutcome = Permitted) iff
                (req.reqCaller.userRole in
                     (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
                 some m: CareTeamMembership |
                     m.ctmClinician = req.reqCaller and
                     m.ctmPatient   = req.reqTargetPatient and
                     m.ctmStatus    = Active)
        }
}

// -------------------------------------------------------------------
// F_AuditOfficerCannotAccessRecords
// contracts/http-api.md: AuditOfficer role cannot use PostRecordsLookup.
// -------------------------------------------------------------------
fact F_AuditOfficerCannotAccessRecords {
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and
         req.reqCaller.userRole = AuditOfficer and
         req.reqKind = PostRecordsLookup) implies
            req.reqOutcome in (Denied + NotFoundOrDenied)
}

// -------------------------------------------------------------------
// F_IGEndpointHiddenFromClinicalRoles
// FR-011, SC-011: any authenticated non-AuditOfficer caller hitting
// PostAuditSearch receives the byte-equivalent not-found response.
// -------------------------------------------------------------------
fact F_IGEndpointHiddenFromClinicalRoles { /* MUTATED — body cleared by validator */ }

// -------------------------------------------------------------------
// F_OnlyAuditOfficerPermittedOnAuditSearch
// The converse: only AuditOfficer can obtain Permitted on PostAuditSearch.
// -------------------------------------------------------------------
fact F_OnlyAuditOfficerPermittedOnAuditSearch {
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and req.reqKind = PostAuditSearch) implies
            ((req.reqOutcome = Permitted) iff (req.reqCaller.userRole = AuditOfficer))
}

// -------------------------------------------------------------------
// F_ByteEquivalentRefusal
// FR-007, SC-003: Denied and NotFoundOrDenied both map to NotFoundResponse;
// only Permitted maps to RecordContent (for PostRecordsLookup).
// -------------------------------------------------------------------
fact F_ByteEquivalentRefusal {
    all req: AccessRequest |
        req.reqAuthStatus = Authenticated implies {
            (req.reqOutcome in (Denied + NotFoundOrDenied)) implies
                req.reqResponse = NotFoundResponse
            (req.reqOutcome = Permitted) implies
                req.reqResponse = RecordContent
        }
}

// ===================================================================
// PREDICATES AND ASSERTIONS
// ===================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorisation tables; spec.md FR-006, FR-011
pred LeastPrivilege {
    some AccessRequest
    all req: AccessRequest |
        req.reqAuthStatus = Authenticated implies
            (req.reqCaller.userRole -> req.reqKind in PermMatrix.Allowed or
             req.reqOutcome in (Denied + NotFoundOrDenied))
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
    // AuditOfficer is NOT in the allowed set for PostRecordsLookup
    no (AuditOfficer -> PostRecordsLookup & PermMatrix.Allowed)
    // Clinical roles are NOT in the allowed set for PostAuditSearch
    no ((Doctor + Nurse + Pharmacist + ClinicalAdmin) -> PostAuditSearch
         & PermMatrix.Allowed)
    // Every clinical role CAN use PostRecordsLookup
    Doctor        -> PostRecordsLookup in PermMatrix.Allowed
    Nurse         -> PostRecordsLookup in PermMatrix.Allowed
    Pharmacist    -> PostRecordsLookup in PermMatrix.Allowed
    ClinicalAdmin -> PostRecordsLookup in PermMatrix.Allowed
    AuditOfficer  -> PostAuditSearch   in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
    some AccessRequest
    all req: AccessRequest |
        req.reqAuthStatus = Unauthenticated implies
            (no req.reqAuditEntry and no req.reqOutcome and no req.reqResponse)
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-008, SC-001, SC-002; data-model.md AuditEntry
pred AuditCompleteness {
    some req: AccessRequest | req.reqAuthStatus = Authenticated
    all req: AccessRequest |
        req.reqAuthStatus = Authenticated implies (one req.reqAuditEntry)
    // Every AuditEntry is owned by exactly one AccessRequest
    all ae: AuditEntry | one req: AccessRequest | req.reqAuditEntry = ae
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-010, FR-012, SC-006; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
    some AuditEntry
    // No AuditEntry is shared between two distinct requests
    all disj req1, req2: AccessRequest |
        (one req1.reqAuditEntry and one req2.reqAuditEntry) implies
            req1.reqAuditEntry != req2.reqAuditEntry
    // Every AuditEntry is referenced by some AccessRequest (no orphaned entries)
    all ae: AuditEntry | some req: AccessRequest | req.reqAuditEntry = ae
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-009; data-model.md snapshotted fields
pred AttributionCorrectness {
    some req: AccessRequest | req.reqAuthStatus = Authenticated
    all req: AccessRequest |
        req.reqAuthStatus = Authenticated implies {
            req.reqAuditEntry.aeClinician    = req.reqCaller
            req.reqAuditEntry.aeSnapshotRole = req.reqCaller.userRole
            req.reqAuditEntry.aeOutcome      = req.reqOutcome
        }
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md FR-006, SC-010; data-model.md CareTeamMembership
pred OwnershipBasedAccess {
    some req: AccessRequest |
        req.reqAuthStatus = Authenticated and
        req.reqKind = PostRecordsLookup and
        req.reqOutcome = Permitted
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and
         req.reqOutcome = Permitted and
         req.reqKind = PostRecordsLookup) implies
            (some m: CareTeamMembership |
                m.ctmClinician = req.reqCaller and
                m.ctmPatient   = req.reqTargetPatient and
                m.ctmStatus    = Active)
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md FR-007, SC-003, SC-011; contracts/http-api.md byte-equivalent not-found
pred NoInformationLeakage {
    some req: AccessRequest |
        req.reqAuthStatus = Authenticated and
        req.reqOutcome in (Denied + NotFoundOrDenied)
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and
         req.reqOutcome in (Denied + NotFoundOrDenied)) implies
            req.reqResponse = NotFoundResponse
    // IG endpoint: non-AuditOfficers also receive NotFoundResponse
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and
         req.reqKind = PostAuditSearch and
         req.reqCaller.userRole != AuditOfficer) implies
            req.reqResponse = NotFoundResponse
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
    some AccessRequest
    all req: AccessRequest |
        req.reqAuthStatus = Unauthenticated implies
            (no req.reqAuditEntry and no req.reqOutcome and no req.reqResponse)
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002 (role comes from identity context, one role per user)
pred FR_002_OneRolePerUser {
    some User
    all u: User | one u.userRole
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006 (care-team membership is necessary and sufficient for Permitted)
pred FR_006_CareTeamGating {
    some req: AccessRequest |
        req.reqAuthStatus = Authenticated and
        req.reqKind = PostRecordsLookup
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and req.reqKind = PostRecordsLookup) implies {
            (req.reqOutcome = Permitted) iff
                (req.reqCaller.userRole in
                     (Doctor + Nurse + Pharmacist + ClinicalAdmin) and
                 some m: CareTeamMembership |
                     m.ctmClinician = req.reqCaller and
                     m.ctmPatient   = req.reqTargetPatient and
                     m.ctmStatus    = Active)
        }
}
assert FR_006_CareTeamGating { FR_006_CareTeamGating }
check FR_006_CareTeamGating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007, SC-003 (denied and not-found produce identical response shape)
pred FR_007_ByteEquivalentRefusal {
    some req: AccessRequest |
        req.reqAuthStatus = Authenticated and
        req.reqOutcome in (Denied + NotFoundOrDenied)
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated) implies {
            (req.reqOutcome in (Denied + NotFoundOrDenied)) iff
                (req.reqResponse = NotFoundResponse)
        }
}
assert FR_007_ByteEquivalentRefusal { FR_007_ByteEquivalentRefusal }
check FR_007_ByteEquivalentRefusal for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008, SC-001, SC-002 (always-on audit for every dispatched request)
pred FR_008_AlwaysOnAudit {
    some req: AccessRequest | req.reqAuthStatus = Authenticated
    all req: AccessRequest |
        req.reqAuthStatus = Authenticated implies (one req.reqAuditEntry)
    // No AuditEntry exists that is not linked to an AccessRequest
    all ae: AuditEntry | (some req: AccessRequest | req.reqAuditEntry = ae)
}
assert FR_008_AlwaysOnAudit { FR_008_AlwaysOnAudit }
check FR_008_AlwaysOnAudit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009 (every audit entry carries all mandatory fields)
pred FR_009_AuditEntryShape {
    some req: AccessRequest | req.reqAuthStatus = Authenticated
    all req: AccessRequest |
        req.reqAuthStatus = Authenticated implies {
            one req.reqAuditEntry.aeClinician
            one req.reqAuditEntry.aeSnapshotRole
            one req.reqAuditEntry.aePatient
            one req.reqAuditEntry.aeOutcome
            one req.reqAuditEntry.aeAuthBasis
        }
}
assert FR_009_AuditEntryShape { FR_009_AuditEntryShape }
check FR_009_AuditEntryShape for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010, SC-006 (audit entries are immutable; no entry shared or replaced)
pred FR_010_AuditAppendOnly {
    some AuditEntry
    all disj req1, req2: AccessRequest |
        (one req1.reqAuditEntry and one req2.reqAuditEntry) implies
            req1.reqAuditEntry != req2.reqAuditEntry
    all ae: AuditEntry | (some req: AccessRequest | req.reqAuditEntry = ae)
}
assert FR_010_AuditAppendOnly { FR_010_AuditAppendOnly }
check FR_010_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011, SC-011 (IG audit endpoint hidden from non-AuditOfficer roles)
pred FR_011_IGEndpointHiddenFromClinicians {
    some req: AccessRequest |
        req.reqAuthStatus = Authenticated and
        req.reqKind = PostAuditSearch and
        req.reqCaller.userRole != AuditOfficer
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and
         req.reqKind = PostAuditSearch and
         req.reqCaller.userRole != AuditOfficer) implies
            req.reqResponse = NotFoundResponse
}
assert FR_011_IGEndpointHiddenFromClinicians { FR_011_IGEndpointHiddenFromClinicians }
check FR_011_IGEndpointHiddenFromClinicians for 5

// FEATURE-SPECIFIC  ANCHOR: FR-013, SC-007 (record content never served without a matching audit entry)
pred FR_013_AuditBeforeRecordServed {
    some req: AccessRequest |
        req.reqAuthStatus = Authenticated and
        req.reqResponse = RecordContent
    all req: AccessRequest |
        (req.reqAuthStatus = Authenticated and req.reqResponse = RecordContent) implies
            one req.reqAuditEntry
}
assert FR_013_AuditBeforeRecordServed { FR_013_AuditBeforeRecordServed }
check FR_013_AuditBeforeRecordServed for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_IGLeakageViolation { some req: AccessRequest | req.reqAuthStatus = Authenticated and req.reqKind = PostAuditSearch and req.reqCaller.userRole = Doctor and req.reqResponse = RecordContent }

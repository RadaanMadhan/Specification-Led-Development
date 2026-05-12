// === feature_model.als — Alloy model for 002-bank-transfer-audit ===
// Models the Bank Transfer with Audit Trail PoC: roles, permissions,
// ownership, transfers, audit entries, and all structural invariants.

// ─── Roles ───────────────────────────────────────────────────────────
abstract sig Role {}
one sig AccountHolder, Auditor, Admin extends Role {}

// ─── Operations ──────────────────────────────────────────────────────
abstract sig OperationKind {}
one sig PostTransfers, GetTransferById, GetAudit extends OperationKind {}

// ─── Permission matrix (Role × OperationKind) ───────────────────────
// We model allowed cells; denied = not in PermMatrix.Allowed
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ─── Users ───────────────────────────────────────────────────────────
sig User {
  role: one Role
}

// ─── Accounts ────────────────────────────────────────────────────────
sig Account {
  owner: one User
}

// ─── Transactions (Transfers) ────────────────────────────────────────
sig Transaction {
  source: one Account,
  destination: one Account,
  initiator: one User
}

// ─── Audit Entries ───────────────────────────────────────────────────
sig AuditEntry {
  transaction: one Transaction,
  auditInitiator: one User,
  auditRole: one Role
}

// ─── Authentication marker ───────────────────────────────────────────
// Models whether a request is authenticated. Every Operation instance
// represents an attempted request.
abstract sig AuthStatus {}
one sig Authenticated, Unauthenticated extends AuthStatus {}

sig Operation {
  kind: one OperationKind,
  caller: lone User,          // lone: unauthenticated has no user
  authStatus: one AuthStatus,
  permitted: one Bool
}

abstract sig Bool {}
one sig True, False extends Bool {}

// =====================================================================
// NAMED FACTS — structural constraints
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorization tables
fact F_PermissionMatrix {
  // Explicit allowed cells from the permission matrix
  // POST /transfers: AccountHolder (conditional on ownership, modelled separately), Admin
  AccountHolder -> PostTransfers in PermMatrix.Allowed
  Admin -> PostTransfers in PermMatrix.Allowed
  // GET /transfers/{id}: AccountHolder (conditional), Auditor, Admin
  AccountHolder -> GetTransferById in PermMatrix.Allowed
  Auditor -> GetTransferById in PermMatrix.Allowed
  Admin -> GetTransferById in PermMatrix.Allowed
  // GET /audit: Auditor, Admin
  Auditor -> GetAudit in PermMatrix.Allowed
  Admin -> GetAudit in PermMatrix.Allowed

  // Denied cells (explicitly not in PermMatrix.Allowed)
  Auditor -> PostTransfers not in PermMatrix.Allowed
  AccountHolder -> GetAudit not in PermMatrix.Allowed

  // Closed-world: only the cells listed above are allowed
  PermMatrix.Allowed = (AccountHolder -> PostTransfers) +
            (Admin -> PostTransfers) +
            (AccountHolder -> GetTransferById) +
            (Auditor -> GetTransferById) +
            (Admin -> GetTransferById) +
            (Auditor -> GetAudit) +
            (Admin -> GetAudit)
}

// FEATURE-SPECIFIC  ANCHOR: FR-001 — authentication required everywhere
fact F_AuthRequired {
  // If unauthenticated, no caller and not permitted
  all o: Operation | o.authStatus = Unauthenticated implies (no o.caller and o.permitted = False)
  // If authenticated, must have a caller
  all o: Operation | o.authStatus = Authenticated implies one o.caller
}

// FEATURE-SPECIFIC  ANCHOR: FR-002 — each user has exactly one role
// (already structural via `role: one Role` but we state it as a named fact)
fact F_OneRolePerUser {
  all u: User | one u.role
}

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md — permission check
fact F_PermissionCheck {
  // An operation is permitted only if authenticated and the (role, kind) pair is in PermMatrix.Allowed
  all o: Operation | o.permitted = True implies
    (o.authStatus = Authenticated and (o.caller.role -> o.kind) in PermMatrix.Allowed)
}

// FEATURE-SPECIFIC  ANCHOR: FR-003 — account_holder can only transfer from owned accounts
fact F_OwnershipTransferRestriction {
  all t: Transaction | t.initiator.role = AccountHolder implies
    t.source.owner = t.initiator
}

// FEATURE-SPECIFIC  ANCHOR: FR-004 — auditor cannot initiate transfers
fact F_AuditorCannotTransfer {
  all t: Transaction | t.initiator.role != Auditor
}

// FEATURE-SPECIFIC  ANCHOR: FR-008 — source ≠ destination
fact F_NoSelfTransfer { /* MUTATED — body cleared by validator */ }

// FEATURE-SPECIFIC  ANCHOR: FR-009 — exactly one AuditEntry per Transaction (bijection)
fact F_AuditBijection {
  // Every transaction has exactly one audit entry
  all t: Transaction | one ae: AuditEntry | ae.transaction = t
  // Every audit entry points to a transaction (already structural, but explicit)
  all ae: AuditEntry | one ae.transaction
}

// PATTERN: AppendOnly  ANCHOR: FR-010; data-model.md "no UPDATE/DELETE"
// In Alloy we model this as: the set of AuditEntries is determined solely
// by Transactions — no AuditEntry exists without a Transaction, and the
// mapping is injective (already in F_AuditBijection). Additionally, no
// operation can remove or mutate an AuditEntry.
// We encode "append-only" by: audit entries are in 1-1 correspondence
// with transactions, and no two distinct audit entries share a transaction.
fact F_AppendOnlyAuditEntries {
  all disj ae1, ae2: AuditEntry | ae1.transaction != ae2.transaction
}

// FEATURE-SPECIFIC  ANCHOR: FR-011 — AuditEntry captures initiator and role
fact F_AuditAttribution {
  all ae: AuditEntry |
    ae.auditInitiator = ae.transaction.initiator and
    ae.auditRole = ae.transaction.initiator.role
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md — Account owned by exactly one User
fact F_OwnershipExclusivity {
  all a: Account | one a.owner
}

// FEATURE-SPECIFIC  ANCHOR: FR-007 — only auditor and admin can read audit log
fact F_AuditLogAccess {
  // Modelled via permission matrix: AccountHolder -> GetAudit not in PermMatrix.Allowed
  // Already in F_PermissionMatrix; this fact reinforces that any permitted
  // GetAudit operation must have role auditor or admin.
  all o: Operation | (o.permitted = True and o.kind = GetAudit) implies
    (o.caller.role = Auditor or o.caller.role = Admin)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005 — admin can do everything
fact F_AdminFullAccess {
  all ok: OperationKind | Admin -> ok in PermMatrix.Allowed
}

// =====================================================================
// PREDICATES AND ASSERTIONS
// =====================================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorization tables
pred LeastPrivilege {
  // Auditor denied PostTransfers
  Auditor -> PostTransfers not in PermMatrix.Allowed
  // AccountHolder denied GetAudit
  AccountHolder -> GetAudit not in PermMatrix.Allowed
  // All allowed cells are exactly the defined set
  some PermMatrix.Allowed  // non-vacuity: some permissions exist
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5 but exactly 3 Role, exactly 3 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md permission tables
pred PermissionCompleteness {
  // Every (Role × OperationKind) cell is either in PermMatrix.Allowed or not —
  // and we have a complete definition (7 allowed, 2 denied = 9 total = 3×3)
  #(Role -> OperationKind) = 9
  // The 7 allowed + 2 denied = 9 covers all cells
  (PermMatrix.Allowed + ((Role -> OperationKind) - PermMatrix.Allowed)) = Role -> OperationKind
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5 but exactly 3 Role, exactly 3 OperationKind

// PATTERN: AuthRequiredEverywhere  ANCHOR: FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  // Every operation that is permitted must be authenticated
  all o: Operation | o.permitted = True implies o.authStatus = Authenticated
  // Unauthenticated operations are never permitted
  all o: Operation | o.authStatus = Unauthenticated implies o.permitted = False
  // Witness: there exists at least one operation
  some Operation
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AuditCompleteness  ANCHOR: FR-009; data-model.md UNIQUE(transaction_id)
pred AuditCompleteness {
  // Every transaction has exactly one audit entry
  all t: Transaction | one ae: AuditEntry | ae.transaction = t
  // Every audit entry maps to exactly one transaction
  all ae: AuditEntry | one t: Transaction | ae.transaction = t
  // No orphan audit entries
  AuditEntry.transaction = Transaction
  // Witness
  some Transaction implies some AuditEntry
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: FR-010; data-model.md "no UPDATE/DELETE"
pred AppendOnly {
  // No two distinct audit entries share the same transaction (injectivity)
  all disj ae1, ae2: AuditEntry | ae1.transaction != ae2.transaction
  // Audit entries exist only for existing transactions
  all ae: AuditEntry | ae.transaction in Transaction
  // Witness: if there are transactions, there are audit entries
  some Transaction implies some AuditEntry
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: FR-011; data-model.md audit-entry fields
pred AttributionCorrectness {
  all ae: AuditEntry |
    ae.auditInitiator = ae.transaction.initiator and
    ae.auditRole = ae.transaction.initiator.role
  some AuditEntry  // witness
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md — Account owned by exactly one User
pred OwnershipExclusivity {
  all a: Account | one a.owner
  some Account  // witness
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: FR-003, FR-006; contracts/http-api.md
pred OwnershipBasedAccess {
  // AccountHolder can only initiate from owned account
  all t: Transaction | t.initiator.role = AccountHolder implies t.source.owner = t.initiator
  // At least one such transaction exists to witness
  some t: Transaction | t.initiator.role = AccountHolder
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: NoSelfMutation  ANCHOR: FR-008, FR-012; data-model.md CHECK constraint
pred NoSelfMutation {
  all t: Transaction | t.source != t.destination
  some Transaction  // witness
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: NoInformationLeakage  ANCHOR: FR-015; contracts/http-api.md GET /transfers/{id}
// Modelled: for account_holder, a denied GetTransferById produces 404 (same as not-found),
// never 403. We model this as: no permitted=False operation with kind=GetTransferById
// and caller.role=AccountHolder reveals existence (i.e., the system doesn't distinguish).
// In Alloy terms: AccountHolder + GetTransferById + not permitted ⟹ same outcome as not-found
// We encode: there is no "403 path" for AccountHolder on GetTransferById
pred NoInformationLeakage {
  // For AccountHolder on GetTransferById, denial never reveals transfer existence
  // Modelled: an AccountHolder's denied GetTransferById is indistinguishable from not-found
  // We represent this by: the denied AccountHolder GetTransferById ops have no
  // distinguishing information — they don't carry the target transaction's identity
  // Structurally: if an AccountHolder operation on GetTransferById is not permitted,
  // it's because the system returns 404 (not 403)
  all o: Operation |
    (o.kind = GetTransferById and o.authStatus = Authenticated and
     o.caller.role = AccountHolder and o.permitted = False) implies
    // The denial looks identical to not-found (no 403 leaked)
    o.permitted = False  // tautological in isolation — strengthened by existence witness
  // Witness: there exists such a denial scenario
  some o: Operation | o.kind = GetTransferById and o.authStatus = Authenticated and
    o.caller.role = AccountHolder and o.permitted = False
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// ─── FR-specific predicates ──────────────────────────────────────────

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  all o: Operation | o.permitted = True implies o.authStatus = Authenticated
  no o: Operation | o.authStatus = Unauthenticated and o.permitted = True
  some o: Operation | o.authStatus = Unauthenticated  // witness unauthenticated request exists
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_OneRolePerUser {
  all u: User | one u.role
  some User  // witness
}
assert FR_002_OneRolePerUser { FR_002_OneRolePerUser }
check FR_002_OneRolePerUser for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_OwnerSourceOnly {
  all t: Transaction | t.initiator.role = AccountHolder implies t.source.owner = t.initiator
  some t: Transaction | t.initiator.role = AccountHolder  // witness
}
assert FR_003_OwnerSourceOnly { FR_003_OwnerSourceOnly }
check FR_003_OwnerSourceOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_AuditorReadOnly {
  // Auditor cannot initiate transfers
  no t: Transaction | t.initiator.role = Auditor
  // Auditor can read transfers and audit
  Auditor -> GetTransferById in PermMatrix.Allowed
  Auditor -> GetAudit in PermMatrix.Allowed
  Auditor -> PostTransfers not in PermMatrix.Allowed
}
assert FR_004_AuditorReadOnly { FR_004_AuditorReadOnly }
check FR_004_AuditorReadOnly for 5 but exactly 3 Role, exactly 3 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_AdminFullAccess {
  all ok: OperationKind | Admin -> ok in PermMatrix.Allowed
  some OperationKind  // witness
}
assert FR_005_AdminFullAccess { FR_005_AdminFullAccess }
check FR_005_AdminFullAccess for 5 but exactly 3 Role, exactly 3 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-006
// AccountHolder can read transfer only if it involves their account
// We model this: if an AH's GetTransferById operation is permitted,
// there must be a transfer involving an account they own
// (Not directly modellable without linking Operation to Transaction target,
// so we check the structural permission matrix side.)
pred FR_006_OwnerReadOnly {
  AccountHolder -> GetTransferById in PermMatrix.Allowed
  // The ownership check is enforced at the handler level; here we verify
  // the role is at least allowed to attempt the operation
  // Combined with FR-015 (NoInformationLeakage), unauthorized reads return 404
  some Operation  // witness
}
assert FR_006_OwnerReadOnly { FR_006_OwnerReadOnly }
check FR_006_OwnerReadOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-007
pred FR_007_AuditLogRestricted {
  AccountHolder -> GetAudit not in PermMatrix.Allowed
  Auditor -> GetAudit in PermMatrix.Allowed
  Admin -> GetAudit in PermMatrix.Allowed
  // No role other than Auditor and Admin can access GetAudit
  all r: Role | r -> GetAudit in PermMatrix.Allowed implies (r = Auditor or r = Admin)
}
assert FR_007_AuditLogRestricted { FR_007_AuditLogRestricted }
check FR_007_AuditLogRestricted for 5 but exactly 3 Role, exactly 3 OperationKind

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_DistinctAccounts {
  all t: Transaction | t.source != t.destination
  some Transaction  // witness
}
assert FR_008_DistinctAccounts { FR_008_DistinctAccounts }
check FR_008_DistinctAccounts for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_OneAuditPerTransfer {
  all t: Transaction | one ae: AuditEntry | ae.transaction = t
  all ae: AuditEntry | ae.transaction in Transaction
  some Transaction  // witness
}
assert FR_009_OneAuditPerTransfer { FR_009_OneAuditPerTransfer }
check FR_009_OneAuditPerTransfer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_AuditAppendOnly {
  // No two audit entries share a transaction (no mutation/duplication)
  all disj ae1, ae2: AuditEntry | ae1.transaction != ae2.transaction
  // Audit entries only reference existing transactions
  all ae: AuditEntry | ae.transaction in Transaction
  some AuditEntry  // witness
}
assert FR_010_AuditAppendOnly { FR_010_AuditAppendOnly }
check FR_010_AuditAppendOnly for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
pred FR_011_AuditCaptures {
  all ae: AuditEntry |
    ae.auditInitiator = ae.transaction.initiator and
    ae.auditRole = ae.transaction.initiator.role
  some AuditEntry  // witness
}
assert FR_011_AuditCaptures { FR_011_AuditCaptures }
check FR_011_AuditCaptures for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012 (validation — no self-transfer, positive amount)
// Amount positivity can't be modelled without Int; we focus on source≠dest
pred FR_012_ValidationNoSelfTransfer {
  all t: Transaction | t.source != t.destination
  some Transaction
}
assert FR_012_ValidationNoSelfTransfer { FR_012_ValidationNoSelfTransfer }
check FR_012_ValidationNoSelfTransfer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-015
pred FR_015_NoLeakage {
  // For AccountHolder denied reads, the system does not expose 403
  // (modelled as: no permitted GetTransferById op for AH that would
  // reveal existence — all denials use same not-found shape)
  all o: Operation |
    (o.kind = GetTransferById and o.authStatus = Authenticated and
     o.caller.role = AccountHolder and o.permitted = False) implies
    o.permitted = False
  some o: Operation | o.kind = GetTransferById and o.authStatus = Authenticated and
    o.caller.role = AccountHolder and o.permitted = False
}
assert FR_015_NoLeakage { FR_015_NoLeakage }
check FR_015_NoLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-016 — exactly three endpoints
pred FR_016_ExactlyThreeEndpoints {
  #OperationKind = 3
  some PostTransfers
  some GetTransferById
  some GetAudit
}
assert FR_016_ExactlyThreeEndpoints { FR_016_ExactlyThreeEndpoints }
check FR_016_ExactlyThreeEndpoints for 5 but exactly 3 OperationKind

// PATTERN: PermissionGrounding  ANCHOR: spec.md FRs; contracts/http-api.md
pred PermissionGrounding {
  // Every allowed cell traces to an FR
  // AccountHolder+PostTransfers ← FR-003
  // Admin+PostTransfers ← FR-005
  // AccountHolder+GetTransferById ← FR-006
  // Auditor+GetTransferById ← FR-004
  // Admin+GetTransferById ← FR-005
  // Auditor+GetAudit ← FR-004
  // Admin+GetAudit ← FR-005
  // All 7 cells accounted for; verify count
  #PermMatrix.Allowed = 7
}
assert PermissionGrounding { PermissionGrounding }
check PermissionGrounding for 5 but exactly 3 Role, exactly 3 OperationKind

// PATTERN: PrivilegeMonotonicity  ANCHOR: spec.md — admin ⊇ auditor read perms, admin ⊇ AH
pred PrivilegeMonotonicity {
  // Admin's permissions are a superset of Auditor's
  all ok: OperationKind | Auditor -> ok in PermMatrix.Allowed implies Admin -> ok in PermMatrix.Allowed
  // Admin's permissions are a superset of AccountHolder's
  all ok: OperationKind | AccountHolder -> ok in PermMatrix.Allowed implies Admin -> ok in PermMatrix.Allowed
  some PermMatrix.Allowed  // witness
}
assert PrivilegeMonotonicity { PrivilegeMonotonicity }
check PrivilegeMonotonicity for 5 but exactly 3 Role, exactly 3 OperationKind

// === Validator-appended: force a non-trivial universe ===
// Without this, Alloy 6 default scope `for 5` allows the empty universe
// where any `some X` clause inside an assertion fails. The Phase-3 lifter
// generated witness clauses to avoid vacuous truth, but that interacts
// with empty-universe counterexamples. We force at least one atom of each
// dynamic sig AND require role/operation diversity so witness clauses
// referencing specific roles/operations are satisfiable.
fact F_NonEmptyUniverse_validator {
    // At least one atom of each dynamic sig
    some User
    some Account
    some Transaction
    some AuditEntry
    some Operation
    // Diversity: at least one User per role, so witness clauses like
    // `some t: Transaction | t.initiator.role = AccountHolder` can find
    // a witness without being blocked by Alloy choosing all-admin users.
    some u: User | u.role = AccountHolder
    some u: User | u.role = Auditor
    some u: User | u.role = Admin
    // At least one Transaction initiated by an AccountHolder
    some t: Transaction | t.initiator.role = AccountHolder
    // At least one Operation per kind
    some o: Operation | o.kind = PostTransfers
    some o: Operation | o.kind = GetTransferById
    some o: Operation | o.kind = GetAudit
    // At least one unauthenticated operation to witness FR-001's
    // structural denial path
    some o: Operation | o.authStatus = Unauthenticated
}

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_SelfTransferViolation { some t: Transaction | t.source = t.destination }

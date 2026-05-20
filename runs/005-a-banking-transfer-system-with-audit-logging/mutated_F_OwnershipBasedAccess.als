// === feature_model.als — Alloy model for 005-a-banking-transfer-system-with-audit-logging ===

// ============================================================
// SIGNATURES
// ============================================================

abstract sig Role {}
one sig Customer, Admin extends Role {}

abstract sig OperationKind {}
one sig PostTransfers, GetTransferById, PostReverse,
        GetBalance, GetTransactions,
        GetAuditEntries, GetAuditVerify, PostStepUp extends OperationKind {}

abstract sig AuthStatus {}
one sig Authenticated, Unauthenticated, Locked extends AuthStatus {}

abstract sig AccountStatus {}
one sig Active, Frozen, Closed extends AccountStatus {}

abstract sig TransferStatus {}
one sig Initiated, Validated, Completed, Failed, Reversed extends TransferStatus {}

abstract sig EventType {}
one sig EvInitiated, EvValidated, EvDebited, EvCredited, EvCompleted,
        EvRejected, EvFailed, EvRolledBack, EvReversalInitiated,
        EvReversalCompleted, EvVelocityAlert, EvStepUpRequested,
        EvStepUpCompleted, EvFraudSignal extends EventType {}

sig User {
    roles: some Role,
    authStatus: one AuthStatus,
    owns: set Account
}

sig Account {
    owner: one User,
    ledgerBalance: one Int,
    availableBalance: one Int,
    dailyLimit: one Int,
    status: one AccountStatus
}

sig Transfer {
    source: one Account,
    destination: one Account,
    amount: one Int,
    transferStatus: one TransferStatus,
    initiatedBy: one User,
    auditEntries: set AuditEntry,
    originalTransaction: lone Transfer,
    fraudSignal: lone FraudSignal
}

sig AuditEntry {
    transaction: one Transfer,
    eventType: one EventType,
    actor: one User,
    seqNum: one Int,
    prevHash: lone AuditEntry,
    fraudFlag: one Bool
}

sig FraudSignal {
    fsTransfer: one Transfer,
    fsAccount: one Account,
    riskScore: one Int
}

abstract sig Bool {}
one sig True, False extends Bool {}

// Permission relation: which (Role, OperationKind) pairs are allowed
sig AllowedPair {
    role: one Role,
    operation: one OperationKind
}

// ============================================================
// NAMED FACTS — Structural Rules
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorization matrix
fact F_LeastPrivilege {
    // Customer allowed: PostTransfers, GetTransferById, GetBalance, GetTransactions, PostStepUp
    // Customer denied: PostReverse, GetAuditEntries, GetAuditVerify
    // Admin allowed: PostTransfers, GetTransferById, PostReverse, GetBalance, GetTransactions, GetAuditEntries, GetAuditVerify
    // Admin denied: PostStepUp

    // Exactly the allowed pairs exist
    all ap: AllowedPair |
        (ap.role = Customer and ap.operation in (PostTransfers + GetTransferById + GetBalance + GetTransactions + PostStepUp))
        or
        (ap.role = Admin and ap.operation in (PostTransfers + GetTransferById + PostReverse + GetBalance + GetTransactions + GetAuditEntries + GetAuditVerify))

    // All allowed pairs are present
    some ap: AllowedPair | ap.role = Customer and ap.operation = PostTransfers
    some ap: AllowedPair | ap.role = Customer and ap.operation = GetTransferById
    some ap: AllowedPair | ap.role = Customer and ap.operation = GetBalance
    some ap: AllowedPair | ap.role = Customer and ap.operation = GetTransactions
    some ap: AllowedPair | ap.role = Customer and ap.operation = PostStepUp
    some ap: AllowedPair | ap.role = Admin and ap.operation = PostTransfers
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetTransferById
    some ap: AllowedPair | ap.role = Admin and ap.operation = PostReverse
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetBalance
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetTransactions
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetAuditEntries
    some ap: AllowedPair | ap.role = Admin and ap.operation = GetAuditVerify
}

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorization matrix
fact F_PermissionCompleteness {
    // Every Role x OperationKind cell is either allowed or denied — no undefined.
    // Denied means no AllowedPair exists for it.
    // We ensure the set of AllowedPair covers exactly the specified cells.
    // (Implicitly: any cell NOT in AllowedPair is denied.)
    // Completeness means we have exactly 12 allowed cells (5 customer + 7 admin)
    #AllowedPair = 12
}

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-010; contracts/http-api.md Authentication section
fact F_AuthRequiredEverywhere {
    // Only authenticated users can initiate transfers
    all t: Transfer | t.initiatedBy.authStatus = Authenticated
    // Only authenticated users appear as actors in audit entries
    all ae: AuditEntry | ae.actor.authStatus = Authenticated
}

// PATTERN: NoSelfMutation  ANCHOR: spec.md edge cases; data-model.md Transfer validation sourceAccountId != destinationAccountId
fact F_NoSelfTransfer {
    all t: Transfer | t.source != t.destination
}

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-004; data-model.md AuditEntry -> Transfer 1:N
fact F_AuditCompleteness {
    // Every transfer has at least one audit entry
    all t: Transfer | some ae: AuditEntry | ae.transaction = t
    // Audit entries link back consistently
    all ae: AuditEntry | ae in ae.transaction.auditEntries
    all t: Transfer, ae: AuditEntry | ae in t.auditEntries iff ae.transaction = t
}

// PATTERN: AppendOnly  ANCHOR: spec.md FR-004; data-model.md "append-only; updates and deletes are prohibited"
fact F_AppendOnlyAuditEntries {
    // Modeled: each AuditEntry belongs to exactly one Transfer and has a unique seqNum
    // No two audit entries share the same sequence number
    all disj ae1, ae2: AuditEntry | ae1.seqNum != ae2.seqNum
}

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md AuditEntry.actorId -> User.id; spec.md FR-004
fact F_AttributionCorrectness {
    // The actor recorded in every audit entry for a transfer is the user who initiated that transfer
    // (For simplicity in this model, we enforce actor = initiatedBy)
    all ae: AuditEntry | ae.actor = ae.transaction.initiatedBy
}

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Account.ownerId -> User.id; "belongs to one User"
fact F_OwnershipExclusivity {
    // Each account has exactly one owner and the owner relation is consistent
    all a: Account | a.owner.owns = a.owner.owns  // always true, placeholder for bidir
    all a: Account | a in a.owner.owns
    all u: User, a: Account | a in u.owns iff a.owner = u
}

// PATTERN: OwnershipBasedAccess  ANCHOR: spec.md; contracts/http-api.md "own accounts only" / "own transfers only"
fact F_OwnershipBasedAccess { /* MUTATED — body cleared by validator */ }

// PATTERN: ConservationOfValue  ANCHOR: spec.md FR-001; "source.balance' + dest.balance' = source.balance + dest.balance"
fact F_ConservationOfValue {
    // Transfer amount must be positive
    all t: Transfer | t.amount > 0
    // Non-negative balances
    all a: Account | a.ledgerBalance >= 0 and a.availableBalance >= 0
    // Available balance <= ledger balance
    all a: Account | a.availableBalance =< a.ledgerBalance
}

// FEATURE-SPECIFIC  ANCHOR: FR-002 — sufficient funds check
fact F_SufficientFunds {
    // A completed transfer must not overdraw the source
    // The source account's available balance must be >= 0 (modeled as non-negative)
    // and there should be enough to cover the transfer
    all t: Transfer | t.transferStatus = Completed implies t.source.availableBalance >= 0
}

// FEATURE-SPECIFIC  ANCHOR: FR-003 — unique transaction reference
fact F_UniqueTransactionId {
    // Each transfer is a distinct atom (Alloy sigs are distinct by construction)
    // But we also ensure no two transfers share the same source, destination, and amount trivially
    // (This is inherent in UUID uniqueness; in Alloy, distinct sig atoms are distinct.)
}

// FEATURE-SPECIFIC  ANCHOR: FR-005 — cryptographic hash chain
fact F_HashChainIntegrity {
    // prevHash forms a chain: no cycles
    no ae: AuditEntry | ae in ae.^prevHash
    // The first entry (lowest seqNum) has no prevHash
    all ae: AuditEntry | (no ae2: AuditEntry | ae2.seqNum < ae.seqNum) implies no ae.prevHash
    // Non-first entries have exactly one prevHash
    all ae: AuditEntry | (some ae2: AuditEntry | ae2.seqNum < ae.seqNum) implies one ae.prevHash
}

// FEATURE-SPECIFIC  ANCHOR: FR-006 — daily transfer limits
fact F_DailyLimitEnforcement {
    // Daily limit must be positive
    all a: Account | a.dailyLimit > 0
}

// FEATURE-SPECIFIC  ANCHOR: FR-009 — reversal via compensating transaction
fact F_ReversalCompensating {
    // A transfer with an originalTransaction is a reversal
    all t: Transfer | some t.originalTransaction implies {
        // The reversal swaps source and destination of the original
        t.source = t.originalTransaction.destination
        t.destination = t.originalTransaction.source
        t.amount = t.originalTransaction.amount
        // Original must have been completed
        t.originalTransaction.transferStatus in (Completed + Reversed)
    }
    // No self-referential reversals
    all t: Transfer | t.originalTransaction != t
    // At most one reversal per original
    all disj t1, t2: Transfer | t1.originalTransaction = t2.originalTransaction implies
        no t1.originalTransaction
}

// FEATURE-SPECIFIC  ANCHOR: FR-010 — fail-closed on audit unavailability
fact F_FailClosedAudit {
    // No completed transfer without at least one audit entry
    all t: Transfer | t.transferStatus = Completed implies some t.auditEntries
}

// FEATURE-SPECIFIC  ANCHOR: data-model.md FraudSignal constraints
fact F_FraudSignalConstraints {
    // Each transfer has at most one fraud signal
    all t: Transfer | lone fs: FraudSignal | fs.fsTransfer = t
    // FraudSignal links back to the transfer
    all fs: FraudSignal | fs = fs.fsTransfer.fraudSignal
    all t: Transfer, fs: FraudSignal | fs = t.fraudSignal iff fs.fsTransfer = t
    // FraudSignal account must be the source account of the transfer
    all fs: FraudSignal | fs.fsAccount = fs.fsTransfer.source
    // Risk score between 0 and 6 (scaled for small scope)
    all fs: FraudSignal | fs.riskScore >= 0
}

// FEATURE-SPECIFIC  ANCHOR: data-model.md Account.accountStatus
fact F_ActiveAccountsOnly {
    // Only active accounts participate in transfers
    all t: Transfer | t.source.status = Active and t.destination.status = Active
}

// FEATURE-SPECIFIC  ANCHOR: spec.md — at least some structure exists
fact F_NonEmptyUniverse {
    some Transfer
    some AuditEntry
    some User
    some Account
}

// ============================================================
// PREDICATES AND ASSERTIONS
// ============================================================

// PATTERN: LeastPrivilege  ANCHOR: contracts/http-api.md authorization matrix
pred LeastPrivilege {
    // Customer denied: PostReverse, GetAuditEntries, GetAuditVerify
    no ap: AllowedPair | ap.role = Customer and ap.operation in (PostReverse + GetAuditEntries + GetAuditVerify)
    // Admin denied: PostStepUp
    no ap: AllowedPair | ap.role = Admin and ap.operation = PostStepUp
    // At least some allowed pairs exist
    some AllowedPair
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 5 but exactly 2 Role, exactly 8 OperationKind

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorization matrix
pred PermissionCompleteness {
    // All 12 allowed cells exist and no extra
    #AllowedPair = 12
    // Customer has exactly 5 allowed operations
    #{ap: AllowedPair | ap.role = Customer} = 5
    // Admin has exactly 7 allowed operations
    #{ap: AllowedPair | ap.role = Admin} = 7
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 5 but exactly 2 Role, exactly 8 OperationKind, exactly 12 AllowedPair

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-010; contracts/http-api.md
pred AuthRequiredEverywhere {
    some Transfer
    all t: Transfer | t.initiatedBy.authStatus = Authenticated
    all ae: AuditEntry | ae.actor.authStatus = Authenticated
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: NoSelfMutation  ANCHOR: spec.md edge cases; data-model.md
pred NoSelfMutation {
    some Transfer
    all t: Transfer | t.source != t.destination
}
assert NoSelfMutation { NoSelfMutation }
check NoSelfMutation for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-004; data-model.md
pred AuditCompleteness {
    some Transfer
    all t: Transfer | some ae: AuditEntry | ae.transaction = t
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-004; data-model.md "append-only"
pred AppendOnly {
    some AuditEntry
    all disj ae1, ae2: AuditEntry | ae1.seqNum != ae2.seqNum
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AttributionCorrectness  ANCHOR: data-model.md AuditEntry.actorId
pred AttributionCorrectness {
    some AuditEntry
    all ae: AuditEntry | ae.actor = ae.transaction.initiatedBy
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: data-model.md Account.ownerId
pred OwnershipExclusivity {
    some Account
    all a: Account | one a.owner
    all a: Account | a in a.owner.owns
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: OwnershipBasedAccess  ANCHOR: contracts/http-api.md "own accounts only"
pred OwnershipBasedAccess {
    some t: Transfer | Customer in t.initiatedBy.roles
    all t: Transfer | Customer in t.initiatedBy.roles implies t.source in t.initiatedBy.owns
}
assert OwnershipBasedAccess { OwnershipBasedAccess }
check OwnershipBasedAccess for 5

// PATTERN: ConservationOfValue  ANCHOR: spec.md FR-001
pred ConservationOfValue {
    some Transfer
    all t: Transfer | t.amount > 0
    all a: Account | a.ledgerBalance >= 0 and a.availableBalance >= 0
    all a: Account | a.availableBalance =< a.ledgerBalance
}
assert ConservationOfValue { ConservationOfValue }
check ConservationOfValue for 5

// PATTERN: NoInformationLeakage  ANCHOR: spec.md edge cases; contracts/http-api.md 404 responses
pred NoInformationLeakage {
    // Access denial for ownership-based operations does not distinguish
    // "exists but not yours" vs "does not exist" — both return 404.
    // Modeled: a customer cannot observe transfers on accounts they don't own.
    some Transfer
    all t: Transfer, u: User |
        (Customer in u.roles and t.source not in u.owns and t.destination not in u.owns)
        implies t.initiatedBy != u
}
assert NoInformationLeakage { NoInformationLeakage }
check NoInformationLeakage for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AtomicTransfer {
    // A completed transfer must have audit entries for both debit and credit events
    some t: Transfer | t.transferStatus = Completed
    all t: Transfer | t.transferStatus = Completed implies {
        some ae1: t.auditEntries | ae1.eventType = EvDebited
        some ae2: t.auditEntries | ae2.eventType = EvCredited
    }
}
assert FR_001_AtomicTransfer { FR_001_AtomicTransfer }
check FR_001_AtomicTransfer for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_SufficientFunds {
    some Transfer
    all t: Transfer | t.transferStatus = Completed implies t.source.availableBalance >= 0
}
assert FR_002_SufficientFunds { FR_002_SufficientFunds }
check FR_002_SufficientFunds for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_UniqueTransactionRef {
    // In Alloy, distinct atoms are distinct identities.
    // We assert that at least two transfers exist and they are distinct.
    some Transfer
    all disj t1, t2: Transfer | t1 != t2
}
assert FR_003_UniqueTransactionRef { FR_003_UniqueTransactionRef }
check FR_003_UniqueTransactionRef for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
pred FR_004_AuditForEveryEvent {
    some Transfer
    all t: Transfer | some t.auditEntries
}
assert FR_004_AuditForEveryEvent { FR_004_AuditForEveryEvent }
check FR_004_AuditForEveryEvent for 5

// FEATURE-SPECIFIC  ANCHOR: FR-005
pred FR_005_HashChain {
    some AuditEntry
    // No cycles in hash chain
    no ae: AuditEntry | ae in ae.^prevHash
}
assert FR_005_HashChain { FR_005_HashChain }
check FR_005_HashChain for 5

// FEATURE-SPECIFIC  ANCHOR: FR-006
pred FR_006_DailyLimit {
    some Account
    all a: Account | a.dailyLimit > 0
}
assert FR_006_DailyLimit { FR_006_DailyLimit }
check FR_006_DailyLimit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_BalanceConsistency {
    some Account
    all a: Account | a.availableBalance =< a.ledgerBalance
    all a: Account | a.availableBalance >= 0
}
assert FR_008_BalanceConsistency { FR_008_BalanceConsistency }
check FR_008_BalanceConsistency for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
pred FR_009_ReversalCompensating {
    // If a reversal exists, it swaps source/dest of original
    all t: Transfer | some t.originalTransaction implies {
        t.source = t.originalTransaction.destination
        t.destination = t.originalTransaction.source
        t.amount = t.originalTransaction.amount
    }
    // Check non-vacuity: there is some universe with transfers
    some Transfer
}
assert FR_009_ReversalCompensating { FR_009_ReversalCompensating }
check FR_009_ReversalCompensating for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
pred FR_010_FailClosedAudit {
    some Transfer
    all t: Transfer | t.transferStatus = Completed implies some t.auditEntries
}
assert FR_010_FailClosedAudit { FR_010_FailClosedAudit }
check FR_010_FailClosedAudit for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_OwnershipBypass { some t: Transfer | Customer in t.initiatedBy.roles and t.source not in t.initiatedBy.owns }

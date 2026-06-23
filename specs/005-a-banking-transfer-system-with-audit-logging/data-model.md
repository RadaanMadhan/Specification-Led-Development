# Data Model: Banking Transfer System with Audit Logging

**Spec**: spec.md
**Created**: 2026-05-18

## Entities

### User

Represents a banking customer or bank administrator who interacts with the system. Users are authenticated via an external identity provider; this system manages authorization through role assignments. Each user may own multiple accounts and initiate transfers or administrative actions.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| email | string(email) | Yes | User's email address, used for notifications and as a login reference |
| fullName | string | Yes | User's legal full name |
| roles | set(enum(CUSTOMER, ADMIN)) | Yes | Authorization roles assigned to the user |
| authenticationStatus | enum(AUTHENTICATED, UNAUTHENTICATED, LOCKED) | Yes | Current authentication state as reported by the external IdP |
| dailyTransferTotal | integer | Yes | Running cumulative transfer amount (in minor units/cents) for the current calendar day, reset at midnight UTC |
| createdAt | datetime | Yes | Timestamp when the user record was created |
| updatedAt | datetime | Yes | Timestamp of the last modification to the user record |

**Validation Rules**:
- `email` must be a valid email format and unique across all User records.
- `roles` must contain at least one role.
- `dailyTransferTotal` must be ≥ 0.
- `authenticationStatus` defaults to `UNAUTHENTICATED` on creation.
- Only users with `authenticationStatus = AUTHENTICATED` may initiate transfers or administrative actions.

---

### Account

Represents a bank account belonging to a single user. Balances are stored as integer minor units (cents) to eliminate floating-point precision errors. The `version` field supports optimistic concurrency control to handle concurrent transfer attempts safely.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| ownerId | UUID (-> User.id) | Yes | The user who owns this account |
| accountNumber | string | Yes | Human-readable account number |
| ledgerBalance | integer | Yes | Total posted balance in minor units (cents); reflects all completed transactions |
| availableBalance | integer | Yes | Usable balance in minor units (cents); ledger balance minus pending holds |
| currency | string | Yes | ISO 4217 currency code (e.g., `USD`); single currency per deployment |
| dailyLimit | integer | Yes | Maximum cumulative transfer amount (minor units) allowed per calendar day |
| accountStatus | enum(ACTIVE, FROZEN, CLOSED) | Yes | Operational status of the account |
| version | integer | Yes | Optimistic locking version; incremented on every balance-modifying operation |
| createdAt | datetime | Yes | Timestamp when the account was created |
| updatedAt | datetime | Yes | Timestamp of the last modification |

**Validation Rules**:
- `ledgerBalance` and `availableBalance` must be ≥ 0 (no negative balances).
- `availableBalance` must be ≤ `ledgerBalance`.
- `dailyLimit` must be > 0.
- `accountNumber` must be unique across all Account records.
- `currency` must be a valid ISO 4217 code.
- `version` must be ≥ 1 and is used for optimistic concurrency checks; a stale version on update results in a `CONCURRENT_MODIFICATION` rejection.
- Only accounts with `accountStatus = ACTIVE` may participate in transfers (as source or destination).

---

### Transfer

Represents a fund movement between two accounts. Each transfer — whether successful, failed, or reversed — is assigned a unique transaction reference ID at creation time. Reversals are modeled as separate compensating Transfer records linked back to the original via `originalTransactionId`.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier and transaction reference ID |
| sourceAccountId | UUID (-> Account.id) | Yes | Account from which funds are debited |
| destinationAccountId | UUID (-> Account.id) | Yes | Account to which funds are credited |
| amount | integer | Yes | Transfer amount in minor units (cents) |
| currency | string | Yes | ISO 4217 currency code; must match both accounts' currency |
| status | enum(INITIATED, VALIDATED, COMPLETED, FAILED, REVERSED) | Yes | Current lifecycle state of the transfer |
| failureReasonCode | enum(INSUFFICIENT_FUNDS, DAILY_LIMIT_EXCEEDED, SAME_ACCOUNT_TRANSFER, CONCURRENT_MODIFICATION, CREDIT_FAILED, AUDIT_UNAVAILABLE, EXTERNAL_TRANSFER_NOT_SUPPORTED, VELOCITY_ALERT, REVERSAL_WINDOW_EXPIRED, ALREADY_REVERSED) | No | Reason code populated when status is `FAILED` |
| originalTransactionId | UUID (-> Transfer.id) | No | Reference to the original transfer when this record is a compensating reversal |
| initiatedBy | UUID (-> User.id) | Yes | User who initiated the transfer (customer or admin for reversals) |
| createdAt | datetime | Yes | Timestamp when the transfer was initiated |
| completedAt | datetime | No | Timestamp when the transfer reached a terminal state (COMPLETED, FAILED, or REVERSED) |

**Validation Rules**:
- `amount` must be > 0.
- `sourceAccountId` and `destinationAccountId` must not be equal; reject with `SAME_ACCOUNT_TRANSFER`.
- `currency` must match the currency of both the source and destination accounts.
- `failureReasonCode` is required when `status` is `FAILED` and must be null when `status` is `COMPLETED`.
- `originalTransactionId` must be non-null if and only if this transfer is a compensating reversal.
- A reversal is only permitted when the original transfer has `status = COMPLETED` and was created within the configurable reversal window (default 30 days).
- A transfer whose original has `status = REVERSED` must be rejected with `ALREADY_REVERSED`.
- `completedAt` must be ≥ `createdAt` when populated.

---

### AuditEntry

An immutable, append-only record capturing a single lifecycle event within a transfer. Entries form a cryptographic hash chain: each entry's `currentHash` is computed over its payload plus `prevHash`, enabling tamper detection. Audit entries must never be updated or deleted.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| transactionId | UUID (-> Transfer.id) | Yes | The transfer this event belongs to |
| eventType | enum(INITIATED, VALIDATED, DEBITED, CREDITED, COMPLETED, REJECTED, FAILED, ROLLED_BACK, REVERSAL_INITIATED, REVERSAL_COMPLETED, VELOCITY_ALERT, STEP_UP_REQUESTED, STEP_UP_COMPLETED, FRAUD_SIGNAL) | Yes | Classification of the lifecycle event |
| actorId | UUID (-> User.id) | Yes | User or administrator who triggered the event |
| timestamp | datetime | Yes | Exact time the event occurred |
| beforeState | string | Yes | JSON snapshot of relevant entity state before the event (e.g., account balances) |
| afterState | string | Yes | JSON snapshot of relevant entity state after the event |
| reasonCode | string | No | Machine-readable reason when the event represents a failure or rejection |
| fraudSignal | boolean | Yes | Flag indicating whether this event is associated with a fraud signal |
| prevHash | string | No | Hash of the immediately preceding AuditEntry in the chain; null for the first entry in the chain |
| currentHash | string | Yes | Cryptographic hash computed over this entry's payload and `prevHash` |
| sequenceNumber | integer | Yes | Monotonically increasing sequence number within the global audit chain |

**Validation Rules**:
- Records are append-only; updates and deletes are prohibited at the application and database level.
- `currentHash` must equal the cryptographic hash (SHA-256) of the concatenation of `id`, `transactionId`, `eventType`, `actorId`, `timestamp`, `beforeState`, `afterState`, `reasonCode`, `fraudSignal`, and `prevHash`.
- `prevHash` must reference the `currentHash` of the AuditEntry with `sequenceNumber = this.sequenceNumber - 1`; null only when `sequenceNumber = 1`.
- `sequenceNumber` must be globally unique and monotonically increasing.
- `fraudSignal` defaults to `false`.
- `beforeState` and `afterState` must be valid JSON.

---

### FraudSignal

A generated risk indicator associated with a specific transfer attempt. Captures the computed risk score, the rules that triggered the signal, and the resulting action. Used for compliance reporting, model calibration, and real-time fraud prevention decisioning.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| transactionId | UUID (-> Transfer.id) | Yes | The transfer this signal evaluates |
| accountId | UUID (-> Account.id) | Yes | The source account under evaluation |
| riskScore | integer | Yes | Computed risk score from 0 (no risk) to 1000 (highest risk) |
| triggerRules | set(enum(VELOCITY, AMOUNT_DEVIATION, DESTINATION_NOVELTY, DAILY_LIMIT_PROXIMITY)) | Yes | Set of rules that contributed to the signal |
| action | enum(ALLOW, STEP_UP, BLOCK) | Yes | Resulting action taken based on the risk evaluation |
| stepUpCompleted | boolean | No | Whether the user successfully completed step-up authentication; null if action is not `STEP_UP` |
| createdAt | datetime | Yes | Timestamp when the signal was generated |

**Validation Rules**:
- `riskScore` must be between 0 and 1000 inclusive.
- `triggerRules` must contain at least one rule when `action` is `STEP_UP` or `BLOCK`.
- `stepUpCompleted` must be non-null only when `action = STEP_UP`.
- Each Transfer may have at most one FraudSignal.
- `action = BLOCK` must result in the associated Transfer being set to `status = FAILED` with an appropriate `failureReasonCode`.

---

## Relationships

- **User** 1:N **Account** (a user owns one or more bank accounts)
- **User** 1:N **Transfer** (a user initiates zero or more transfers)
- **Account** 1:N **Transfer (as source)** (an account is the source of zero or more transfers)
- **Account** 1:N **Transfer (as destination)** (an account is the destination of zero or more transfers)
- **Transfer** 1:N **AuditEntry** (a transfer has one or more audit log entries capturing its lifecycle)
- **Transfer** 1:1 **FraudSignal** (a transfer has at most one associated fraud signal)
- **Transfer** 1:1 **Transfer (reversal)** (a completed transfer may have at most one compensating reversal transfer linked via `originalTransactionId`)
- **User** 1:N **AuditEntry** (a user is the actor in zero or more audit entries)
- **Account** 1:N **FraudSignal** (an account may have zero or more fraud signals across its transfers)

## Indexes

- `User.email` (unique; fast lookup for login and notification workflows)
- `Account.ownerId` (fast retrieval of all accounts belonging to a user)
- `Account.accountNumber` (unique; lookup by human-readable account number)
- `Transfer.sourceAccountId` (query transfers debiting a specific account; daily limit calculation)
- `Transfer.destinationAccountId` (query transfers crediting a specific account)
- `Transfer.initiatedBy` (retrieve all transfers initiated by a specific user)
- `Transfer.originalTransactionId` (locate compensating reversal for a given transfer)
- `Transfer.status, Transfer.createdAt` (filter transfers by status within date ranges)
- `Transfer.sourceAccountId, Transfer.createdAt` (compute daily transfer totals for limit enforcement)
- `AuditEntry.transactionId` (retrieve full audit trail for a specific transfer)
- `AuditEntry.actorId` (query all audit events by a specific user)
- `AuditEntry.eventType, AuditEntry.timestamp` (filter audit log by event type and date range)
- `AuditEntry.sequenceNumber` (unique; hash chain traversal and integrity verification)
- `AuditEntry.timestamp` (range queries for compliance and reporting)
- `FraudSignal.transactionId` (unique; lookup fraud signal for a specific transfer)
- `FraudSignal.accountId, FraudSignal.createdAt` (account risk profile computation and reporting)
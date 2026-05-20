# Feature Specification: Prevent Negative Wallet

**Feature Branch**: `056-prevent-negative-wallet`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Prevent negative balances in digital wallets unless the user has an approved overdraft line of credit."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prevent Unauthorized Transaction (Priority: P1)

As a user without an approved overdraft, I want my transactions to be declined if my balance is insufficient, so that I don't incur unauthorized negative balances.

**Why this priority**: Core safety feature to prevent debt.

**Independent Test**: Perform a purchase attempt with a balance of $10 and a transaction amount of $20. Expected outcome: Transaction declined.

**Acceptance Scenarios**:

1. **Given** a user has $10 balance and no overdraft, **When** a $20 transaction is attempted, **Then** the transaction is declined and balance remains $10.

---

### User Story 2 - Authorize Transaction via Overdraft (Priority: P2)

As a user with an approved overdraft line of credit, I want my transactions to be approved even if my balance is insufficient, up to my overdraft limit, so that I can make essential purchases.

**Why this priority**: Business value for users who need flexibility.

**Independent Test**: Perform a purchase attempt with a balance of $10, a transaction amount of $20, and an overdraft limit of $50. Expected outcome: Transaction approved, new balance -$10.

**Acceptance Scenarios**:

1. **Given** a user has $10 balance and $50 overdraft limit, **When** a $20 transaction is attempted, **Then** the transaction is approved and balance becomes -$10.
2. **Given** a user has $10 balance and $5 overdraft limit, **When** a $20 transaction is attempted, **Then** the transaction is declined.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST check both the current wallet balance and the overdraft status/limit before authorizing any transaction.
- **FR-002**: System MUST decline any transaction that exceeds the available funds if the user has no approved overdraft.
- **FR-003**: System MUST allow transactions that exceed the available funds if the user has an approved overdraft, provided the resulting balance does not exceed the overdraft limit.
- **FR-004**: System MUST maintain the accurate balance (positive or negative) in the user's wallet.
- **FR-005**: System MUST provide a clear reason to the user when a transaction is declined.

### Key Entities

- **Wallet**: Represents the user's digital balance.
- **Transaction**: Represents a request to transfer funds.
- **User**: The owner of the wallet.
- **OverdraftPolicy**: Defines whether a user has overdraft enabled and the maximum overdraft limit.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of transactions resulting in a negative balance must correspond to users with a valid, approved overdraft line of credit.
- **SC-002**: 100% of transactions where the resulting balance would exceed the overdraft limit are successfully declined.
- **SC-003**: Transaction processing time does not increase by more than 50ms due to the new balance/overdraft validation logic.

## Assumptions

- Overdraft status and limits are provided by an existing account management system.
- Wallet balance updates are atomic to prevent race conditions (implementation detail to be handled by backend).
- The system has access to a real-time ledger or balance service.

## Formal Requirements & Business KPI Mapping

```alloy
sig User {
    wallet: one Wallet,
    overdraft: one OverdraftPolicy
}
sig Wallet {
    var balance: Int
}
sig OverdraftPolicy {
    enabled: one Bool,
    limit: Int
}

fact {
    -- Overdraft limit cannot be negative
    all o: OverdraftPolicy | o.limit >= 0
}

-- Predicate to check if a transaction is authorized
pred canAuthorize(u: User, amount: Int) {
    let currentBalance = u.wallet.balance |
    let newBalance = currentBalance - amount |
    (u.overdraft.enabled = True => newBalance >= -u.overdraft.limit else newBalance >= 0)
}
```

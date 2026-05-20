# Feature Specification: Overdraft Protection

**Feature Branch**: `074-overdraft-protection`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Implement an overdraft protection flow: If a transaction exceeds the balance, check a linked savings account before declining."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Transaction Success with Overdraft (Priority: P1)

A customer initiates a transaction that exceeds their current account balance. The system automatically checks for a linked savings account and, if available, uses it to cover the shortfall, allowing the transaction to proceed.

**Why this priority**: Core functionality of the feature.

**Independent Test**: Initiate a transaction exceeding balance with a linked savings account. Verify transaction completes and balance covers the shortfall via savings transfer.

**Acceptance Scenarios**:

1. **Given** a customer with a balance of $50 and a linked savings account with $100, **When** they attempt a $75 transaction, **Then** the system transfers $25 from savings, and the transaction is approved.
2. **Given** a customer with a balance of $50 and no linked savings account, **When** they attempt a $75 transaction, **Then** the transaction is declined.

---

### User Story 2 - Transaction Failure (Priority: P2)

If the linked savings account does not have sufficient funds to cover the transaction shortfall, the transaction is declined.

**Why this priority**: Ensures system integrity and prevents negative balances.

**Independent Test**: Initiate a transaction exceeding combined balance. Verify transaction is declined.

**Acceptance Scenarios**:

1. **Given** a customer with a balance of $50 and a linked savings account with $10, **When** they attempt a $75 transaction, **Then** the transaction is declined due to insufficient total funds.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST verify if a transaction exceeds the primary account balance before processing.
- **FR-002**: System MUST identify if a linked savings account exists for the customer.
- **FR-003**: System MUST check if the linked savings account has sufficient funds to cover the shortfall.
- **FR-004**: System MUST automatically transfer funds from the savings account to the primary account to cover the shortfall if criteria are met.
- **FR-005**: System MUST decline the transaction if no linked savings account exists or if the combined funds are insufficient.

### Key Entities

- **Customer**: Holds primary and savings accounts.
- **PrimaryAccount**: Used for daily transactions, has a balance.
- **SavingsAccount**: Linked to primary account, has a balance.
- **Transaction**: Requested movement of funds, has an amount and status.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of transactions exceeding balance are correctly evaluated for overdraft protection.
- **SC-002**: Transaction approval rate for customers with sufficient combined funds (primary + savings) increases by 15%.
- **SC-003**: No account balance becomes negative due to processed transactions.

## Assumptions

- Overdraft protection is enabled by default for all customers with a linked savings account.
- Savings accounts can be linked or unlinked independently of the overdraft feature.
- There are no fees associated with this automatic overdraft transfer for the MVP version.

## Formal Requirements & Business KPI Mapping

```alloy
// Requirements
one sig FR_001, FR_002, FR_003, FR_004, FR_005 extends Requirement {}

// Stories
one sig Story_TransactionSuccess, Story_TransactionFailure extends Story {}

// Actions
sig RequestTransaction extends Action { amount: Int }

// Overdraft Logic
pred canCover(c: Customer, t: RequestTransaction) {
    // Primary balance sufficient
    c.primary.balance >= t.amount or
    // Savings can cover shortfall
    (some s: c.savings | 
        s.balance >= (t.amount - c.primary.balance))
}

// KPI Mapping
// KPI-FR-001: Verified via scenario coverage of overdraft logic
// KPI-FR-004: Verified if scenario transition results in balanced transfer
```

# Feature Specification: Overdraft Protection

**Feature Branch**: `021-overdraft-protection`  
**Created**: 19/05/2026  
**Status**: Draft  
**Input**: User description: "Implement an overdraft protection flow: If a transaction exceeds the balance, check a linked savings account before declining."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Automatic Overdraft Protection (Priority: P1)

As a customer with a linked savings account, if a transaction exceeds my primary account balance, I want the system to automatically use funds from my savings account so that the transaction is successful and I avoid the inconvenience of a decline.

**Why this priority**: Directly addresses the primary business goal of preventing transaction declines for eligible customers, increasing transaction success rates.

**Independent Test**: Perform a transaction exceeding primary account balance while having sufficient funds in a linked savings account. Verify transaction succeeds and funds are deducted from savings.

**Acceptance Scenarios**:

1. **Given** primary balance is $50, savings balance is $100, **When** user attempts a $70 transaction, **Then** transaction is authorized, primary balance becomes $0, and savings balance becomes $80.
2. **Given** primary balance is $50, savings balance is $10, **When** user attempts a $70 transaction, **Then** transaction is declined.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Reduce transaction decline rate | `fact { all t: Transaction | t.amount > t.source.balance implies (t.source.linkedSavings.balance >= (t.amount - t.source.balance) implies authorized(t)) }` | Transaction success rate analytics |

---

### User Story 2 - Insufficient Combined Funds (Priority: P2)

As a customer, I want to be informed when a transaction is declined because neither my primary nor my linked savings account has sufficient funds, so I understand why the transaction failed.

**Why this priority**: Ensures clear user feedback when even overdraft protection cannot cover the transaction.

**Independent Test**: Attempt a transaction greater than the sum of primary and savings account balances. Verify transaction is declined.

**Acceptance Scenarios**:

1. **Given** primary balance is $20, savings balance is $30, **When** user attempts a $60 transaction, **Then** transaction is declined.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Improve user clarity on declines | `fact { all t: Transaction | (t.amount > (t.source.balance + t.source.linkedSavings.balance)) implies declined(t) }` | User support feedback sentiment |
---

### Edge Cases

- What happens if the savings account is not active? (Assume declined)
- What if there are multiple linked savings accounts? (The system will check ONLY the primary linked savings account.)
- How does the system handle concurrent transactions?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST identify if a transaction exceeds primary account balance.
- **FR-002**: System MUST check the linked savings account for available funds if a transaction exceeds the primary account balance.
- **FR-003**: System MUST transfer necessary funds from the linked savings account to the primary account to cover the transaction amount if funds are available.
- **FR-004**: System MUST decline the transaction if the combined funds in primary and linked savings are insufficient.
- **FR-005**: System MUST log all overdraft protection events.

### Key Entities

- **Account**: Represents primary or savings accounts, with attributes for current balance and status.
- **Transaction**: Represents the payment attempt, with source, amount, and status (Authorized/Declined).
- **Customer**: Holds the relationship between primary and linked savings accounts.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 95% of transactions that would have been declined due to insufficient primary balance are successful due to overdraft protection (where savings funds exist).
- **SC-002**: Transaction authorization latency increases by less than 100ms when overdraft protection is invoked.
- **SC-003**: 100% of declined transactions provide a clear reason to the user.

## Assumptions

- Customers have at most one linked savings account used for overdraft protection.
- Transfers between savings and primary accounts are instantaneous.
- The system has real-time access to balance information for both accounts.

## Formal Requirements & Business KPI Mapping
```alloy
sig Account {
    balance: Int
}

sig Customer {
    primary: one Account,
    savings: lone Account
}

// Constraint: primary and savings must be distinct
fact { all c: Customer | no c.savings or c.primary != c.savings }

// Constraint: primary account belongs to only one customer
fact { all a: Account | lone a.~primary }

abstract sig Status {}
one sig Authorized, Declined extends Status {}

sig Transaction {
    amount: Int,
    source: one Account,
    status: Status
}

fact {
    all a: Account | a.balance >= 0
    
    // Transactions only on primary accounts
    all t: Transaction | t.source in Customer.primary
    
    // Transaction authorization logic
    all t: Transaction | {
        let src = t.source |
        let cust = src.~primary | 
        let savings = cust.savings |
        
        // 1. Transaction authorized if primary covers it
        (t.amount <= src.balance) => (t.status = Authorized)
        
        // 2. Transaction authorized if primary+savings covers it
        else (some savings and (src.balance + savings.balance >= t.amount)) => (t.status = Authorized)
        
        // 3. Otherwise declined
        else (t.status = Declined)
    }
}
```
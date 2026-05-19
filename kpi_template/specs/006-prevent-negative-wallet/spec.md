# Feature Specification: Prevent Negative Wallet Balances

**Feature Branch**: `003-prevent-negative-wallet`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Prevent negative balances in digital wallets unless the user has an approved overdraft line of credit."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Payment within Available Funds (Priority: P1)

As a wallet user, I want to initiate a payment that does not exceed my current balance, so that I can pay for services without issue.

**Why this priority**: Core functionality; ensures standard transactions continue to work.

**Independent Test**: Perform a transaction for $50 when the balance is $100. Verify the transaction succeeds and balance updates to $50.

**Acceptance Scenarios**:

1. **Given** a wallet balance of $100, **When** a payment of $50 is initiated, **Then** the payment succeeds, and the balance becomes $50.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain positive wallet experience | `fact { all p: Payment | p.amount <= p.wallet.balance }` | Successful transaction rate |

---

### User Story 2 - Rejected Payment without Overdraft (Priority: P1)

As a wallet user, I want my payment to be rejected if it exceeds my balance and I do not have an approved overdraft, so that I do not incur debt unintentionally.

**Why this priority**: Prevents unauthorized negative balances.

**Independent Test**: Perform a transaction for $150 when the balance is $100 and no overdraft exists. Verify the transaction is rejected.

**Acceptance Scenarios**:

1. **Given** a wallet balance of $100 and no overdraft, **When** a payment of $150 is initiated, **Then** the payment is rejected, and the balance remains $100.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Prevent unauthorized debt | `fact { all w: Wallet | no w.overdraft implies w.balance >= 0 }` | Rate of unauthorized overdraft attempts |

---

### User Story 3 - Payment with Approved Overdraft (Priority: P2)

As a wallet user with an approved overdraft line of credit, I want to initiate a payment that exceeds my balance, so that I can complete necessary transactions.

**Why this priority**: Enables critical functionality for authorized users.

**Independent Test**: Perform a transaction for $150 when the balance is $100 and an overdraft limit of $100 is approved. Verify the transaction succeeds and balance becomes -$50.

**Acceptance Scenarios**:

1. **Given** a wallet balance of $100, an approved overdraft of $100, **When** a payment of $150 is initiated, **Then** the payment succeeds, and the balance becomes -$50.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Enable authorized overdrafts | `fact { all w: Wallet | w.overdraft.approved implies w.balance >= w.overdraft.limit }` | Successful overdraft transactions |

---

### Edge Cases

- What happens when a user attempts a payment that exceeds both balance and overdraft limit? (Should be rejected)
- What happens when a user has no overdraft initially but gets approved during a transaction attempt? (Assumption: Overdraft status must be approved *prior* to payment).
- What happens when overdraft limit is exactly $0? (Should behave like no overdraft).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST check if a payment exceeds the current balance.
- **FR-002**: If payment exceeds balance, System MUST check if the user has an approved overdraft line of credit.
- **FR-003**: System MUST reject payments exceeding the balance if no approved overdraft exists.
- **FR-004**: If an approved overdraft exists, System MUST reject payments only if the total exceeds (balance + overdraft limit).
- **FR-005**: System MUST update the balance (possibly to negative) after a successful overdraft transaction.

### Key Entities *(include if feature involves data)*

- **Wallet**: Represents the user's funds, balance, and overdraft status.
- **Payment**: Represents the transaction attempt with an amount.
- **Overdraft**: Represents the line of credit, including an approved status and a limit.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 0% of wallets without approved overdrafts are allowed to have a negative balance.
- **SC-002**: 100% of payment attempts exceeding balance for users without overdraft are correctly rejected.
- **SC-003**: 100% of payments within (balance + overdraft limit) for users with overdraft are allowed.

## Assumptions

- Overdraft approval status and limit are managed by a separate service.
- Wallet balances are real-time.
- The system has access to user overdraft status before processing a payment.

## Formal Requirements & Business KPI Mapping
```alloy
sig Wallet {
    balance: Int,
    overdraft: lone Overdraft
}

sig Overdraft {
    approved: one Bool,
    limit: one Int
}

sig Payment {
    amount: one Int,
    wallet: one Wallet
}

fact NoNegativeBalanceWithoutOverdraft {
    all w: Wallet | no w.overdraft or w.overdraft.approved = False implies w.balance >= 0
}
```

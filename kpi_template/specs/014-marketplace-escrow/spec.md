# Feature Specification: Marketplace Escrow System

**Feature Branch**: `011-marketplace-escrow`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "funds are held in a smart contract and only released to the seller after the buyer marks the item as 'Received'."

## Clarifications

### Session 2026-05-19
- Q: Should there be a timeout mechanism to automatically release funds or allow dispute? → A: 7-day timeout mechanism to automatically release funds.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Secure Escrow Purchase (Priority: P1)

As a buyer, I want my funds to be held securely in escrow when I purchase an item, so that I am protected until I receive the item.

**Why this priority**: Core functionality of the escrow system.

**Independent Test**: Can be fully tested by verifying that funds are deducted from the buyer and held in the escrow contract upon purchase, without yet being sent to the seller.

**Acceptance Scenarios**:

1. **Given** a buyer purchases an item, **When** the transaction is initiated, **Then** funds are transferred to the escrow smart contract.
2. **Given** funds are in escrow, **When** the seller checks their pending balance, **Then** the funds are not yet available for withdrawal.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure funds protection | `fact { all p: Payment | p.status = Escrow implies p.amount in Contract.balance }` | Audit contract balance vs locked payments |

---

### User Story 2 - Confirm Receipt of Item (Priority: P2)

As a buyer, I want to mark an item as 'Received', so that I can signal the release of funds to the seller.

**Why this priority**: Essential step to trigger fund release.

**Independent Test**: Verify that marking an item as received updates the escrow state to 'Released'.

**Acceptance Scenarios**:

1. **Given** an item purchased and held in escrow, **When** the buyer marks it as 'Received', **Then** the escrow status updates to 'Released'.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Timely confirmation | `fact { all p: Payment | p.status = Released implies p.received = True }` | Track time from purchase to receipt confirmation |

---

### User Story 3 - Release Funds to Seller (Priority: P3)

As a seller, I want to receive funds automatically once the buyer marks the item as received, so that I get paid securely.

**Why this priority**: Completes the transaction lifecycle.

**Independent Test**: Verify that funds are transferred to the seller's wallet after the 'Received' status is confirmed.

**Acceptance Scenarios**:

1. **Given** an escrow marked as 'Released', **When** the transaction is processed, **Then** funds are transferred from the escrow contract to the seller's wallet.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure seller payment | `fact { all p: Payment | p.status = Released implies p.amount in Seller.wallet }` | Verify transaction completion on blockchain |

---

## Edge Cases

- What happens when a buyer never marks the item as 'Received'? Funds are automatically released to the seller after 7 days.
- What happens if the smart contract fails to execute the transfer?
- What happens if the buyer attempts to mark as 'Received' without purchasing?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST hold funds in escrow smart contract upon buyer purchase.
- **FR-002**: System MUST ONLY release funds to seller after buyer marks as 'Received'.
- **FR-003**: Buyer MUST be able to mark an item as 'Received' via the marketplace UI.
- **FR-004**: System MUST ensure that funds are irretrievable by the buyer once escrowed, until a potential dispute resolution or receipt confirmation.
- **FR-005**: System MUST automatically release escrowed funds to the seller 7 days after the item was purchased if the buyer has not marked it as 'Received'.

### Key Entities

- **Payment**: Represents the transaction, amount, and escrow state (Escrow, Released, Refunded).
- **EscrowContract**: Smart contract holding the funds.
- **User**: Can act as a Buyer or Seller.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of funds are protected in the escrow contract until 'Received' is confirmed or the 7-day timeout passes.
- **SC-002**: 100% of funds are released to the seller within 1 minute of confirmation or timeout.
- **SC-003**: 0% of funds are released to sellers without buyer confirmation (or timeout/dispute resolution).

## Assumptions

- Smart contract platform supports automated fund transfers based on event triggers.
- Buyer authentication is handled by the existing marketplace system.
- Market participants trust the escrow smart contract logic.

## Formal Requirements & Business KPI Mapping
```alloy
abstract sig Status {}
one sig Escrow, Released, Refunded extends Status {}

sig User {}

sig Payment {
    buyer: one User,
    seller: one User,
    amount: one Int,
    var status: one Status,
    var received: one Bool
}

sig EscrowContract {
    var balance: one Int
}

pred ReleaseFunds[p: Payment] {
    p.status = Escrow
    (p.received = True or (Time > PurchaseTime + 7days))
    p.status' = Released
    p.amount' = p.amount
    // Transfer logic
}
```

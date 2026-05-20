# Feature Specification: Marketplace Escrow System

**Feature Branch**: `064-marketplace-escrow`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Build a marketplace escrow system: funds are held in a smart contract and only released to the seller after the buyer marks the item as 'Received'."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Secure Funds Escrow (Priority: P1)

As a buyer, I want my payment to be held securely in an escrow contract until I confirm receipt of the item, so that I am protected against non-delivery or fraudulent items.

**Why this priority**: This is the core functionality required to establish trust between the buyer and the seller in a marketplace.

**Independent Test**: Can be fully tested by initiating a purchase, verifying funds are locked in the escrow contract, and then confirming the buyer can only release funds after marking the item as received.

**Acceptance Scenarios**:

1. **Given** a buyer has initiated a purchase, **When** the buyer transfers funds, **Then** the escrow contract successfully locks the funds and marks the order status as 'Pending Receipt'.
2. **Given** funds are locked in escrow, **When** the buyer marks the item as 'Received', **Then** the escrow contract releases the funds to the seller and marks the order as 'Completed'.

---

### User Story 2 - Seller Payout (Priority: P2)

As a seller, I want to automatically receive funds from the escrow contract once the buyer confirms receipt, so that I am assured of timely and secure payment.

**Why this priority**: Ensures the seller is compensated for the item sold, completing the transaction loop.

**Independent Test**: Can be fully tested by verifying the seller's balance increases correctly after the buyer confirms receipt of the item.

**Acceptance Scenarios**:

1. **Given** an order is 'Pending Receipt', **When** the buyer marks the item as 'Received', **Then** the escrow contract transfers the locked funds to the seller's account.

---

### Edge Cases

- What happens when a buyer fails to mark an item as 'Received' within a specified timeframe? [NEEDS CLARIFICATION: Is there a timeout period for automatic release or dispute?]
- How does the system handle a dispute where the buyer claims the item is damaged or not as described? [NEEDS CLARIFICATION: Is a dispute resolution mechanism needed?]
- What happens if the smart contract transaction fails during the release of funds?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST enable a buyer to initiate an escrow-protected purchase.
- **FR-002**: System MUST hold funds in a secure, immutable escrow contract upon purchase initiation.
- **FR-003**: System MUST allow the buyer to mark an order status as 'Received'.
- **FR-004**: System MUST trigger the release of locked funds from the escrow contract to the seller upon the buyer confirming receipt.
- **FR-005**: System MUST maintain the order status and track the escrow state throughout the lifecycle of the transaction.

### Key Entities

- **Buyer**: The party purchasing the item, responsible for transferring funds to escrow and confirming receipt.
- **Seller**: The party selling the item, entitled to receive funds upon successful confirmation by the buyer.
- **Item**: The good or service being sold in the marketplace.
- **EscrowContract**: The smart contract component responsible for securely holding and conditionally releasing funds.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of funds designated for escrow are held securely until the 'Received' trigger is met.
- **SC-002**: Escrow funds are released to the seller within 1 minute of the buyer marking the item as 'Received'.
- **SC-003**: 99% of successful transactions achieve fund release without system intervention.
- **SC-004**: Zero unauthorized fund releases occur during the escrow period.

## Assumptions

- The marketplace platform provides the interface for buyers and sellers to interact with the escrow system.
- The smart contract implementation is secure and audited.
- Buyer has sufficient funds to initiate the purchase.
- Seller has an associated account to receive the funds.

## Formal Requirements & Business KPI Mapping

```alloy
sig User {}

abstract sig Status {}
one sig PendingReceipt extends Status {}
one sig Completed extends Status {}

sig Order {
    buyer: User,
    seller: User,
    var status: Status,
    var escrowLocked: one Int
}

// Fact: Escrow can only be released if status becomes Completed
fact EscrowLogic {
    all o: Order |
        (o.status = PendingReceipt) implies (o.escrowLocked > 0)
        (o.status = Completed) implies (o.escrowLocked = 0)
}

pred markReceived[o: Order] {
    o.status = PendingReceipt
    o.status' = Completed
    o.escrowLocked' = 0
    // All other orders unchanged
    all o2: Order - o | o2.status' = o2.status and o2.escrowLocked' = o2.escrowLocked
}

run markReceived for 3
```

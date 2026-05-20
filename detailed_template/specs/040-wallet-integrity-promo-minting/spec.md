# Feature Specification: Wallet Integrity and Promotional Minting

**Feature Branch**: `037-wallet-integrity-promo-minting`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Ensure that the sum of all individual user wallet balances exactly equals the central treasury balance at all times. Also, users can mint their own promotional tokens up to $50 without interacting with the treasury."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Maintain Wallet Integrity (Priority: P1)

As a system administrator, I want to ensure that the sum of all user wallet balances always equals the central treasury balance so that financial integrity is maintained.

**Why this priority**: Ensuring financial consistency is fundamental to preventing fraud and system insolvency.

**Independent Test**: Perform a transaction between a user and the treasury, then verify that `sum(all User.wallet.balance) == Treasury.balance`.

**Acceptance Scenarios**:

1. **Given** a set of users and a central treasury, **When** any transaction affecting user wallets occurs, **Then** the sum of all user wallet balances remains exactly equal to the central treasury balance.
2. **Given** a transaction attempt that would violate the equality constraint, **When** the transaction is processed, **Then** the transaction is rejected.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure financial consistency | `fact { sum(User.wallet.balance) == Treasury.balance }` | Periodic automated balance reconciliation |

---

### User Story 2 - Mint Promotional Tokens (Priority: P2)

As a user, I want to mint up to $50 in promotional tokens without interacting with the central treasury so that I can have immediate buying power for promotional purposes.

**Why this priority**: This feature provides user flexibility and incentive mechanisms independent of the treasury, albeit within strict limits.

**Independent Test**: Mint $20 in tokens and verify that the user's promo balance is $20, and the central treasury balance remains unchanged.

**Acceptance Scenarios**:

1. **Given** a user has minted $0 in promo tokens, **When** the user mints $30 in promo tokens, **Then** the user has $30 in promo tokens, and the central treasury is unaffected.
2. **Given** a user has minted $45 in promo tokens, **When** the user attempts to mint $10 in promo tokens, **Then** the transaction is rejected because it exceeds the $50 limit.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain treasury integrity while allowing limited minting | `fact { User.promo_minted <= 50 }` | Monitor treasury balance constancy during promo minting |

---

### Edge Cases

- What happens if a user attempts to mint a negative amount of promotional tokens?
- How does the system handle a scenario where a transaction would violate the balance equality invariant (e.g., concurrent balance updates)?
- What is the lifecycle of promotional tokens if a user account is deleted?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST maintain an invariant where the sum of all individual user wallet balances equals the central treasury balance.
- **FR-002**: System MUST permit users to mint promotional tokens.
- **FR-003**: System MUST enforce a maximum lifetime minting limit of $50 per user for promotional tokens.
- **FR-004**: System MUST ensure that promotional token minting does not affect the central treasury balance.
- **FR-005**: System MUST differentiate between regular wallet balances and promotional token balances.

### Key Entities

- **User**: Represents an account holder with a wallet balance and a promotional token balance.
- **Wallet**: Stores the regular balance of a user.
- **Central Treasury**: Holds the total funds corresponding to the sum of all user wallet balances.
- **Promotional Token**: A specific type of token minted by the user, subject to individual limits.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The balance equality invariant is maintained with 100% accuracy during all transaction types.
- **SC-002**: Users can successfully mint promotional tokens up to $50 without any treasury interaction.
- **SC-003**: Any minting attempt exceeding the $50 limit is rejected by the system.
- **SC-004**: Treasury balance remains unchanged during promotional token minting operations.

## Assumptions

- Promotional tokens are tracked separately from regular wallet balances and do not contribute to the "wallet balance" used in the treasury integrity invariant.
- "Mint" refers to the creation of promotional tokens within the user's own promotional balance.
- There is a mechanism in place to track the lifetime total of minted promotional tokens per user.

## Formal Requirements & Business KPI Mapping
```alloy
-- Alloy model placeholder for Wallet Integrity and Promo Minting
sig User {
    wallet_balance: Int,
    promo_minted: Int
}
sig Treasury {
    balance: Int
}

fact Integrity {
    all t: Treasury | t.balance = sum(u: User | u.wallet_balance)
}

fact PromoLimit {
    all u: User | u.promo_minted <= 50
}
```

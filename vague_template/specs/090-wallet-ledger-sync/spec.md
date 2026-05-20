# Feature Specification: Wallet and Treasury Integrity

**Feature Branch**: `090-wallet-ledger-sync`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Ensure that the sum of all individual user wallet balances exactly equals the central treasury balance at all times. Also, users can mint their own promotional tokens up to $50 without interacting with the treasury."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Mint Promotional Tokens (Priority: P1)

As a user, I want to mint promotional tokens to my wallet so that I can use them for transactions without reducing the central treasury.

**Why this priority**: Core functional requirement for promotional activity.

**Independent Test**: Perform minting of $20 and verify wallet balance increases without any changes to the Central Treasury.

**Acceptance Scenarios**:

1. **Given** a user with a wallet balance of $100, **When** the user mints $30 in promotional tokens, **Then** the wallet balance becomes $130, and the Central Treasury remains at its previous total.
2. **Given** a user with a wallet balance of $100, **When** the user attempts to mint $60 in promotional tokens, **Then** the transaction is rejected, and the wallet balance remains $100.

---

### User Story 2 - Verify Treasury Integrity (Priority: P1)

As a system administrator, I want to ensure that the sum of all user wallets always matches the Central Treasury balance to maintain financial integrity.

**Why this priority**: Critical requirement for system financial accuracy.

**Independent Test**: Perform various transactions (deposits, withdrawals, minting) and verify that the sum of all individual wallets equals the central treasury balance.

**Acceptance Scenarios**:

1. **Given** the current sum of all user wallets equals the Central Treasury balance, **When** a user performs a standard transaction (non-promotional), **Then** the system ensures both the user wallet and the Central Treasury balance are updated such that the sum remains equal.
2. **Given** a discrepancy in total balances, **When** the system runs an integrity check, **Then** an alert is raised to the system administrator.

### Edge Cases

- What happens when a user attempts to withdraw funds that would cause their wallet balance to go negative?
- How does the system handle concurrent transactions trying to update the Central Treasury?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST ensure that the sum of all individual user wallet balances equals the Central Treasury balance at all times, excluding promotional token balances.
- **FR-002**: Users MUST be allowed to mint promotional tokens up to a maximum limit of $50 per user account.
- **FR-003**: Promotional token minting MUST NOT interact with or reduce the Central Treasury balance.
- **FR-004**: System MUST reject any promotional token minting request that exceeds the $50 limit.

### Key Entities

- **User Wallet**: Holds the balance for an individual user, including standard funds and promotional tokens.
- **Central Treasury**: Holds the total balance of all standard funds for all users.
- **Promotional Token**: A specific type of token that can be minted by users up to a limit.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The difference between the sum of all user wallets (excluding promotional tokens) and the Central Treasury balance is $0 at all times.
- **SC-002**: 100% of promotional token minting requests above the $50 limit are blocked.
- **SC-003**: Promotional token minting actions have 0% impact on the Central Treasury balance.

## Assumptions

- Standard transactions interact with the Central Treasury, while promotional minting does not.
- Promotional tokens are tracked within the user's wallet but are distinguished from standard funds.
- System integrity checks occur periodically or on transaction commit.

## Formal Requirements & Business KPI Mapping
```alloy
sig User {
    wallet: Int,
    promoBalance: Int
}

one sig Treasury {
    balance: Int
}

// Ensure the sum of all individual user wallets (standard funds) 
// equals the central treasury balance
fact IntegrityConstraint {
    sum u: User | u.wallet = Treasury.balance
}

// Promotional tokens do not interact with the treasury
pred MintPromoToken[u: User, amount: Int] {
    amount <= 50
    u.promoBalance' = u.promoBalance + amount
    u.wallet' = u.wallet
    Treasury.balance' = Treasury.balance
}

assert TreasuryMatchesWallets {
    all u: User | u.wallet = Treasury.balance
}
```

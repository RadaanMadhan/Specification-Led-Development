# Feature Specification: API Key Limit for Standard SaaS

**Feature Branch**: `049-api-key-limit-standard`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Enforce that standard tier SaaS accounts can only have a maximum of 3 active API keys at any given time."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create API Key (Priority: P1)

As a standard tier SaaS account owner, I want to create a new API key so that I can integrate my applications with the service.

**Why this priority**: Core functionality; required for the feature to be useful.

**Independent Test**: Attempt to create a 4th API key while already possessing 3 active keys; expect failure.

**Acceptance Scenarios**:

1. **Given** a standard tier account with 2 active API keys, **When** the user creates a new API key, **Then** the key is successfully created.
2. **Given** a standard tier account with 3 active API keys, **When** the user attempts to create a new API key, **Then** the creation request is rejected with an error message indicating the limit has been reached.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain account security and service limits | `fact { all a: Account | a.tier = Standard implies #a.apiKeys.active <= 3 }` | API creation request success/failure rate per account tier |

---

### User Story 2 - Deactivate API Key (Priority: P2)

As a standard tier SaaS account owner, I want to deactivate an existing API key so that I can make space to create a new one.

**Why this priority**: Essential to manage the limited resource (3 keys).

**Independent Test**: Deactivate an active key, then create a new key; expect success.

**Acceptance Scenarios**:

1. **Given** a standard tier account with 3 active API keys, **When** the user deactivates one key, **Then** the account now has 2 active keys and 1 inactive key.
2. **Given** a standard tier account with 2 active keys and 1 inactive key, **When** the user attempts to create a new API key, **Then** the key is successfully created (total 3 active).

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Empower users to manage their limits | `pred deactivateKey(a: Account, k: APIKey) { k in a.apiKeys.active and k.active' = False }` | API key deactivation count |

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST enforce a maximum of 3 active API keys for accounts with the "Standard" tier.
- **FR-002**: System MUST reject any attempt to create a new API key if the account already has 3 active API keys.
- **FR-003**: System MUST provide a clear error message when the API key creation limit is reached.
- **FR-004**: System MUST treat "active" and "inactive" API keys distinctly for limit calculation.

### Key Entities

- **Account**: Represents the SaaS account, including its tier (e.g., Standard, Premium) and list of API keys.
- **APIKey**: Represents a single API key, with an attribute indicating whether it is currently active or inactive.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of standard tier accounts are prevented from exceeding 3 active API keys.
- **SC-002**: API key creation requests return a descriptive error message when the limit is reached within 500ms.
- **SC-003**: 95% of users can successfully manage their key limit by deactivating and creating new keys without support intervention.

## Assumptions

- "Active" API keys are explicitly tracked and distinguished from "inactive" (revoked/deactivated) keys.
- "Standard" tier accounts are clearly identifiable in the system.
- The limit applies strictly to the number of *active* keys, not the total number of keys (active + inactive) ever created.

## Formal Requirements & Business KPI Mapping
```alloy
sig Account {
    tier: Tier,
    apiKeys: set APIKey
}

enum Tier { Standard, Premium }

sig APIKey {
    active: one Bool
}

sig Bool {}
one sig True, False extends Bool {}

fact LimitConstraint {
    all a: Account | a.tier = Standard implies #{k: a.apiKeys | k.active = True} <= 3
}
```

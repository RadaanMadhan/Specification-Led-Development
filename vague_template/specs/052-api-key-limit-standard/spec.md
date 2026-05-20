# Feature Specification: API Key Limit Standard

**Feature Branch**: `052-api-key-limit-standard`
**Created**: 2026-05-19
**Status**: Draft
**Input**: User description: "Enforce that standard tier SaaS accounts can only have a maximum of 3 active API keys at any given time."

## User Scenarios & Testing

### User Story 1 - Create New API Key (Priority: P1)

As a standard tier SaaS account user, I want to create new API keys, but I should be prevented from exceeding the maximum of 3 active keys.

**Why this priority**: Directly enforces the core requirement and protects system integrity.

**Independent Test**: Attempt to create a 4th API key while already having 3 active keys and verify the request is rejected.

**Acceptance Scenarios**:

1. **Given** a standard tier account with 2 active API keys, **When** the user creates a new API key, **Then** the creation is successful and the user has 3 active keys.
2. **Given** a standard tier account with 3 active API keys, **When** the user attempts to create a new API key, **Then** the creation request is rejected with an error message indicating the limit has been reached.

---

### User Story 2 - Manage API Keys (Priority: P2)

As a standard tier SaaS account user, I want to view my active API keys and delete keys I no longer need, so that I can manage my quota effectively.

**Why this priority**: Essential for users to manage their limited quota.

**Independent Test**: Delete an active API key and verify that the user can subsequently create a new API key (if they were at the limit).

**Acceptance Scenarios**:

1. **Given** a standard tier account with 3 active API keys, **When** the user deletes one API key, **Then** the user has 2 active API keys and can successfully create a new API key.

---

### Edge Cases

- What happens when a user attempts to create an API key while having 3 keys, but one is pending deletion?
- How does the system handle concurrent API key creation requests that push the count from 3 to 4?

## Requirements

### Functional Requirements

- **FR-001**: System MUST identify the account tier for every API key creation request.
- **FR-002**: System MUST count the number of currently active API keys for a standard tier account.
- **FR-003**: System MUST reject any request to create an API key if the active key count for a standard tier account is 3.
- **FR-004**: System MUST return a clear error message to the user when the API key limit is reached.
- **FR-005**: System MUST allow users to list their active API keys.
- **FR-006**: System MUST allow users to delete active API keys.

### Key Entities

- **API Key**: A unique credential for accessing SaaS services, associated with a SaaS account.
- **SaaS Account**: Represents the customer organization, with an associated tier (e.g., standard).

## Success Criteria

### Measurable Outcomes

- **SC-001**: No standard tier account can exceed 3 active API keys at any time.
- **SC-002**: API key creation requests that exceed the limit return an error within 500ms.
- **SC-003**: Users receive a clear, actionable error message when the limit is reached, resulting in zero support tickets related to "API key limit confusion".

## Assumptions

- Account tier information is available and reliable.
- "Active" API keys are those not revoked or deleted.
- The definition of "standard tier" is predefined in the system.

## Formal Requirements & Business KPI Mapping
```alloy
sig Account {
    tier: one Tier
}

enum Tier { Standard, Premium }

sig ApiKey {
    account: one Account,
    status: one Status
}

enum Status { Active, Revoked }

// Constraint: Standard accounts have at most 3 active keys
fact MaxActiveKeysForStandard {
    all a: Account | a.tier = Standard => 
        #{k: ApiKey | k.account = a and k.status = Active} <= 3
}
```

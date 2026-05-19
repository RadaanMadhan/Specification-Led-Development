# Feature Specification: Digital Asset Ownership Limit

**Feature Branch**: `006-digital-asset-ownership-limit`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: Ensure a digital asset (NFT or ticket) can only have one owner at any exact moment in time.

## User Scenarios & Testing

### User Story 1 - Prevent Simultaneous Ownership (Priority: P1)

As a digital asset manager, I want to ensure that any given digital asset (NFT or ticket) has exactly one owner at any point in time, so that ownership disputes are eliminated and transfer of value is secure.

**Why this priority**: Core functionality; ensures fundamental integrity of the digital asset system.

**Independent Test**: Can be tested by initiating two simultaneous transfer requests for the same asset ID to different users and verifying that the system accepts only one and rejects the other.

**Acceptance Scenarios**:

1. **Given** an asset is owned by User A, **When** User A initiates a transfer to User B, **Then** the transfer is accepted, and User B becomes the sole owner.
2. **Given** an asset is owned by User A, **When** User A initiates two simultaneous transfers to User B and User C, **Then** the system accepts the first request and rejects the second request.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure unique ownership | `fact { all a: Asset | lone a.owner }` | Telemetry on transfer collision events |

---

### User Story 2 - Verify Ownership Status (Priority: P2)

As a potential buyer, I want to verify the current owner of an asset, so that I can ensure I am transacting with the authorized owner.

**Why this priority**: Ensures transparency and trust for users transacting with the asset.

**Independent Test**: Can be tested by querying the asset status before and after a transfer, verifying that the owner ID is correctly updated to the new owner.

**Acceptance Scenarios**:

1. **Given** an asset is owned by User A, **When** a user queries the owner of the asset, **Then** the system returns User A as the owner.
2. **Given** the asset is transferred to User B, **When** a user queries the owner, **Then** the system returns User B as the owner.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain transaction trust | `pred OwnershipStatus { ... }` | Survey on user transaction satisfaction |

## Requirements

### Functional Requirements

- **FR-001**: System MUST associate each Digital Asset with exactly one Owner ID.
- **FR-002**: System MUST reject any attempt to transfer an asset if the sender is not the current owner.
- **FR-003**: System MUST atomically update ownership records to ensure no race conditions allow duplicate ownership.
- **FR-004**: System MUST record the history of ownership changes for auditing purposes.

### Key Entities

- **Digital Asset**: Represents an NFT or ticket. Key attributes: Asset ID, Type (NFT/Ticket), Current Owner ID.
- **Owner**: Represents a user or entity that can hold an asset. Key attributes: Owner ID, Name/Details.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Zero reported incidents of an asset having more than one owner simultaneously.
- **SC-002**: 100% of transfer requests are processed with strict serialization, ensuring no race conditions.
- **SC-003**: Ownership verification query response time is under 200ms for 99% of requests.

## Assumptions

- There exists an authentication system to identify users (Owners).
- Digital assets have unique, immutable identifiers.
- Transfer requests are handled by a central, authoritative system.

## Formal Requirements & Business KPI Mapping
```alloy
sig Asset {
    owner: one Owner
}
sig Owner {}

fact UniqueOwnership {
    all a: Asset | one a.owner
}

assert NoDoubleOwnership {
    all a: Asset | lone a.owner
}
```

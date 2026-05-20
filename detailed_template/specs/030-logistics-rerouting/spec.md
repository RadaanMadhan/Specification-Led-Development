# Feature Specification: Logistics Re-routing System

**Feature Branch**: `027-logistics-rerouting`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Design a dynamic re-routing system for logistics. If a truck breaks down, its packages must be reassigned to the nearest available trucks without exceeding any truck's maximum weight capacity."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Automatic Package Re-assignment (Priority: P1)

As a logistics operations manager, I want the system to automatically re-assign packages from a broken-down truck to the nearest available trucks, so that delivery timelines are maintained and packages are not left stranded.

**Why this priority**: This is the core functionality requested and directly addresses the business need for maintaining logistics flow during vehicle failures.

**Independent Test**: Can be fully tested by simulating a truck breakdown in the system and verifying that its packages are distributed to other trucks within their weight limits, and that the original truck's package list becomes empty.

**Acceptance Scenarios**:

1. **Given** a truck (A) breaks down with a set of packages (P), **When** the breakdown is reported, **Then** the system identifies the nearest available trucks (B, C) with sufficient remaining capacity, and re-assigns packages (P) to them.
2. **Given** a truck (A) breaks down with packages (P), **When** no available trucks have sufficient capacity, **Then** the system alerts operations staff to intervene.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain package delivery flow | `fact { all p: Package | one t: Truck | p in t.packages }` | Log breakdown to resolution time |
| Respect truck capacity | `fact { all t: Truck | sum[t.packages.weight] <= t.maxCapacity }` | Telemetry on capacity checks |

---

### User Story 2 - Operations Notification (Priority: P2)

As a logistics operations staff member, I want to be notified when the re-routing is completed or if it fails, so that I can take appropriate manual action if necessary.

**Why this priority**: Essential for visibility and handling edge cases where automatic re-routing is impossible.

**Independent Test**: Can be tested by triggering a breakdown and verifying that a notification is sent to the configured operations channel with the status of the re-routing.

**Acceptance Scenarios**:

1. **Given** a truck breakdown, **When** re-routing is successful, **Then** the system sends a notification listing the new truck assignments.
2. **Given** a truck breakdown, **When** re-routing fails (e.g., due to lack of capacity), **Then** the system sends a critical alert to operations staff.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Rapid issue response | `fact { Breakdown implies Notification }` | Notification delivery latency |

## Edge Cases

- What happens when no available trucks exist?
- How does the system handle scenarios where the nearest trucks have insufficient capacity, but trucks slightly further away do?
- How does the system handle stale location data for trucks?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST automatically detect or receive a "truck breakdown" event.
- **FR-002**: System MUST calculate the remaining weight capacity for all active, available trucks.
- **FR-003**: System MUST identify available trucks based on their proximity to the broken-down truck.
- **FR-004**: System MUST re-assign packages such that no truck's maximum weight capacity is exceeded.
- **FR-005**: System MUST prioritize re-assigning packages to the *nearest* available trucks.
- **FR-006**: System MUST handle scenarios where total remaining capacity of available trucks is less than the weight of the packages needing re-assignment by notifying operations staff.

### Key Entities

- **Truck**: A vehicle with a maximum weight capacity and current location.
- **Package**: An item with a specific weight that needs to be delivered.
- **BreakdownEvent**: A signal indicating a specific truck is no longer operational.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of packages from a broken-down truck are re-assigned to available trucks, provided total system capacity allows it.
- **SC-002**: No truck exceeds its maximum weight capacity after re-assignment.
- **SC-003**: Re-routing calculation and assignment completion occurs within 30 seconds of breakdown detection.
- **SC-004**: Operations staff receive a notification within 1 minute of a breakdown event.

## Assumptions

- Truck location data is accurate and near-real-time.
- Package weight data is accurate and available at the time of breakdown.
- "Available" trucks are defined as trucks that are currently active and in the same logistics region.
- Trucks do not have constraints other than weight (e.g., volume, package type compatibility) for the purpose of this v1 requirement.

## Formal Requirements & Business KPI Mapping
```alloy
sig Package {
    weight: Int
}

sig Truck {
    maxCapacity: Int,
    packages: set Package
}

// Ensure weight is positive
fact {
    all p: Package | p.weight > 0
    all t: Truck | t.maxCapacity >= 0
}

// Constraint: Truck capacity cannot be exceeded
fact {
    all t: Truck | sum[t.packages.weight] <= t.maxCapacity
}

// Dummy predicate for re-routing logic
pred reRoute[brokenTruck: Truck, availableTrucks: set Truck, updatedTrucks: Truck -> set Package] {
    // Basic structural constraint: packages from broken truck are reassigned
    brokenTruck.packages in (updatedTrucks[availableTrucks] + updatedTrucks[brokenTruck])
}

run {} for 5
```

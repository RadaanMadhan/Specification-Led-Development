# Feature Specification: Logistics Dynamic Re-routing

**Feature Branch**: `080-logistics-dynamic-rerouting`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Design a dynamic re-routing system for logistics. If a truck breaks down, its packages must be reassigned to the nearest available trucks without exceeding any truck's maximum weight capacity."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Truck Breakdown Re-routing (Priority: P1)

As a logistics manager, I want the system to automatically reassign packages from a broken-down truck to the nearest available trucks, so that delivery timelines are maintained and packages are delivered without delay.

**Why this priority**: This is the core functionality requested by the user.

**Independent Test**: Simulate a truck breakdown at a specific location. Verify that the system identifies the breakdown, calculates the nearest available trucks with capacity, and reassigns the packages correctly.

**Acceptance Scenarios**:

1. **Given** a truck (Truck A) breaks down with a set of packages, **When** the system detects the breakdown, **Then** the system identifies the nearest operational trucks (Truck B, Truck C) that have sufficient remaining weight capacity to accommodate all of Truck A's packages.
2. **Given** multiple available trucks, **When** reassignment is calculated, **Then** the system assigns packages to trucks based on proximity (nearest first) without exceeding any truck's maximum weight capacity.
3. **Given** no trucks have enough capacity, **When** reassignment is attempted, **Then** the system alerts the logistics manager that manual intervention is required.

---

### User Story 2 - Driver Notification (Priority: P2)

As a driver, I want to be notified of new packages assigned to my truck due to re-routing, so that I can update my delivery route accordingly.

**Why this priority**: Necessary for the logistics workflow to be functional.

**Independent Test**: Trigger a package reassignment and verify that the drivers of the target trucks receive a notification.

**Acceptance Scenarios**:

1. **Given** a package has been reassigned to Truck B, **When** the reassignment is committed, **Then** the driver of Truck B receives a notification with the new package details and updated route.

---

### Edge Cases

- What happens when a truck breaks down in a remote area with no nearby operational trucks?
- What happens if the reassignment process fails for one or more packages due to unforeseen system errors?
- How does the system handle concurrent breakdowns of multiple trucks?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST detect when a truck breaks down and initiates the re-routing workflow.
- **FR-002**: System MUST identify operational trucks in the vicinity of the broken-down truck.
- **FR-003**: System MUST calculate the remaining weight capacity of available trucks (Truck Max Weight - Current Load).
- **FR-004**: System MUST assign packages to the nearest available trucks without exceeding their maximum weight capacity.
- **FR-005**: System MUST notify affected drivers of new package assignments.

### Key Entities

- **Truck**: Represents a delivery vehicle with location, current load, max weight capacity, and status (operational/broken-down).
- **Package**: Represents an item to be delivered, with weight information.
- **Logistics System**: Orchestrates the breakdown detection, re-routing calculation, and notifications.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of packages from a broken-down truck are reassigned if sufficient total capacity exists in nearby trucks.
- **SC-002**: Reassignment calculation completes in under 30 seconds for up to 100 packages.
- **SC-003**: No truck exceeds its maximum weight capacity after reassignment.
- **SC-004**: Drivers are notified of new assignments within 2 minutes of the breakdown being detected.

## Assumptions

- Trucks have real-time GPS tracking enabled.
- The weight of each package is known and recorded in the system.
- Trucks operate within a defined service area where "nearest" can be reliably calculated based on distance or time.
- Drivers have access to a mobile application to receive notifications.

## Formal Requirements & Business KPI Mapping

```alloy
sig Location {}

sig Package {
    weight: Int
}

sig Truck {
    location: Location,
    maxWeight: Int,
    currentPackages: set Package,
    status: one Status
}

enum Status { Operational, BrokenDown }

pred isAtCapacity[t: Truck] {
    sum[t.currentPackages.weight] > t.maxWeight
}

pred canAccommodate[t: Truck, p: set Package] {
    sum[t.currentPackages.weight] + sum[p.weight] <= t.maxWeight
}

// Requirement: Packages from broken-down truck reassigned without exceeding capacity
assert ReassignmentValid {
    all broken: Truck | broken.status = BrokenDown =>
        all p: broken.currentPackages =>
            some target: Truck | target.status = Operational && canAccommodate[target, p]
}

check ReassignmentValid for 5
```

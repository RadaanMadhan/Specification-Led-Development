# Feature Specification: Restrict Driver Multi-Vehicle

**Feature Branch**: `053-restrict-driver-multi-vehicle`  
**Created**: 20 May 2026
**Status**: Draft  
**Input**: User description: Ensure that a single delivery driver is not assigned more than one vehicle at the same time.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prevent Multi-Vehicle Assignment (Priority: P1)

As a system, I need to ensure that a driver cannot be assigned to a second vehicle if they are already assigned to one, to prevent scheduling conflicts and resource misuse.

**Why this priority**: This is the core requirement that directly addresses the business rule.

**Independent Test**: Attempt to assign a second vehicle to a driver who already has one and verify that the system rejects the request.

**Acceptance Scenarios**:

1. **Given** a driver is already assigned to Vehicle A, **When** the system receives a request to assign Vehicle B to the same driver, **Then** the request is rejected and the driver remains assigned to Vehicle A.

---

### User Story 2 - Allow Reassignment (Priority: P2)

As an administrator, I need to unassign a driver from a vehicle to allow them to be assigned to a different vehicle.

**Why this priority**: Essential for operational flexibility when a vehicle becomes unavailable or the driver is reassigned.

**Independent Test**: Unassign a vehicle from a driver and then assign a new vehicle, verifying success.

**Acceptance Scenarios**:

1. **Given** a driver is assigned to Vehicle A, **When** the system unassigns Vehicle A, and then assigns Vehicle B, **Then** the assignment is successful and the driver is assigned to Vehicle B.

---

### Edge Cases

- What happens when a vehicle is assigned to a driver who is already unassigned? (System should allow it)
- How does the system handle concurrent assignment requests for the same driver? (System should process them sequentially or reject subsequent requests)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST track the current vehicle assignment for each driver.
- **FR-002**: System MUST reject any vehicle assignment request for a driver who is already assigned to a vehicle.
- **FR-003**: System MUST provide a clear error message when a vehicle assignment request is rejected.
- **FR-004**: System MUST allow the unassignment of a vehicle from a driver.

### Key Entities

- **Driver**: Represents a delivery person.
- **Vehicle**: Represents a delivery vehicle.
- **Assignment**: Represents the relationship between a Driver and a Vehicle at a given time.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 0% of drivers are assigned more than one vehicle at the same time.
- **SC-002**: 100% of vehicle assignment attempts for already-assigned drivers are rejected.
- **SC-003**: Assignment rejection error messages are provided to the user within 500ms.

## Assumptions

- Driver and Vehicle entities exist in the system.
- The assignment system is centralized.

## Formal Requirements & Business KPI Mapping

```alloy
// Alloy model for restricting driver multi-vehicle assignment
sig Driver {
    assigned: lone Vehicle
}
sig Vehicle {}

pred assign[d: Driver, v: Vehicle] {
    no d.assigned
    d.assigned' = v
}

pred unassign[d: Driver] {
    d.assigned' = none
}

// KPI: Drivers assigned at most one vehicle
assert AtMostOneVehicle {
    all d: Driver | lone d.assigned
}
check AtMostOneVehicle for 5
```

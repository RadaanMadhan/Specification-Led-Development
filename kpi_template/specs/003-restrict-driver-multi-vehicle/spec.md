# Feature Specification: Restrict Driver to Single Vehicle Assignment

**Feature Branch**: `050-restrict-driver-multi-vehicle`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: Ensure that a single delivery driver is not assigned more than one vehicle at the same time.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prevent Multiple Vehicle Assignment (Priority: P1)

As a dispatch manager, I want to ensure that a delivery driver is only assigned to one active vehicle at a time, so that I can maintain accountability and prevent scheduling conflicts.

**Why this priority**: This is the core requirement directly addressing the business goal of preventing resource contention and ensuring accurate tracking.

**Independent Test**: Attempt to assign a second active vehicle to a driver who is already assigned to one active vehicle. The system should reject the assignment.

**Acceptance Scenarios**:

1. **Given** a driver is not currently assigned to any vehicle, **When** I assign the driver to a vehicle, **Then** the assignment is successful.
2. **Given** a driver is currently assigned to one active vehicle, **When** I attempt to assign the driver to another vehicle, **Then** the assignment is rejected with an error message indicating the driver already has an active assignment.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure driver-vehicle assignment integrity | `fact { all d: Driver | lone d.activeVehicle }` | Monitoring assignment rejection rate |

---

### Edge Cases

- What happens when a vehicle becomes inactive or the assignment is closed? (The driver should be free to be assigned to a new vehicle).
- How does the system handle concurrent assignment attempts? (System should enforce consistency).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST restrict the number of active vehicle assignments for any single delivery driver to a maximum of one.
- **FR-002**: The system MUST validate existing active assignments before creating a new driver-vehicle assignment.
- **FR-003**: The system MUST provide an error message when a driver is already assigned to an active vehicle and a new assignment is requested.
- **FR-004**: The system MUST allow re-assignment only if the previous active vehicle assignment has been closed or marked inactive.

### Key Entities

- **Driver**: Represents the person responsible for vehicle operation.
- **Vehicle**: Represents the transport unit available for assignment.
- **Assignment**: Represents the active link between a Driver and a Vehicle.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of attempts to assign an already-assigned driver to a second vehicle are blocked.
- **SC-002**: Dispatch managers report a reduction in vehicle assignment conflicts due to system enforcement.

## Assumptions

- An "active" assignment is defined by the status of the assignment entity.
- The system has access to the current state of driver-vehicle assignments.

## Formal Requirements & Business KPI Mapping
```alloy
sig Driver {
    activeVehicle: lone Vehicle
}

sig Vehicle {}

fact SingleAssignment {
    all v: Vehicle | lone d: Driver | d.activeVehicle = v
}
```
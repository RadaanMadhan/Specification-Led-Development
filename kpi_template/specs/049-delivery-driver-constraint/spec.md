# Feature Specification: Delivery-Driver Constraint

**Feature Branch**: `[046-delivery-driver-constraint]`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "A delivery cannot be dispatched unless a driver is assigned. Drivers can only be assigned after the delivery is dispatched."

## Clarifications
### Session 2026-05-19
- Q: Clarify circular dependency between dispatch and driver assignment → A: The dispatch process allows for a preliminary driver assignment.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Assign and Dispatch (Priority: P1)

As a delivery manager, I need to ensure that deliveries are only dispatched when a driver is ready and assigned, while maintaining proper state transitions for the delivery process.

**Why this priority**: Core functionality of the delivery management system.

**Independent Test**: Verify that a delivery cannot be transitioned to a "dispatched" state without an assigned driver and that the system enforces the correct assignment logic.

**Acceptance Scenarios**:

1. **Given** a delivery exists, **When** the manager makes a preliminary driver assignment, **Then** the driver is linked to the delivery.
2. **Given** a delivery has a preliminary driver assignment, **When** the manager attempts to dispatch, **Then** the system proceeds with dispatch.
3. **Given** a delivery is dispatched, **When** the manager attempts to update or finalize the driver assignment, **Then** the system updates the driver assignment.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| *Ensure all dispatched deliveries have drivers* | *fact { all d: Delivery | d.dispatched implies some d.driver }* | *Telemetry on dispatch actions* |

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow preliminary driver assignment to a delivery before it is dispatched.
- **FR-002**: System MUST ensure that a delivery cannot be set to a "dispatched" state unless a driver (preliminary or otherwise) is assigned.
- **FR-003**: System MUST allow updating or finalizing the driver assignment for a delivery after it has been dispatched.

### Key Entities

- **Delivery**: Represents the shipment, its status (e.g., pending, dispatched), and the assigned driver.
- **Driver**: Represents the personnel responsible for the delivery.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of dispatched deliveries have an assigned driver recorded in the system.
- **SC-002**: Delivery dispatch time (from order placement) remains within organizational standards.
- **SC-003**: Zero instances of dispatched deliveries without an assigned driver.

## Assumptions

- Delivery states (e.g., 'pending', 'dispatched') are managed by an existing workflow engine.
- Driver records are available in the system before a delivery is ready for assignment.
- A "delivery" is the central unit of work for this constraint.

## Formal Requirements & Business KPI Mapping

```alloy
sig Driver {}
sig Delivery {
    var driver: lone Driver,
    var dispatched: one Bool
}
enum Bool { True, False }

-- Constraint: A delivery cannot be dispatched unless a driver is assigned.
fact {
    all d: Delivery | d.dispatched = True implies some d.driver
}
```

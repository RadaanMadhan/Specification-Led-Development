# Feature Specification: delivery-dispatch-driver-assignment

**Feature Branch**: `099-delivery-dispatch-driver-assignment`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "A delivery cannot be dispatched unless a driver is assigned. Drivers can only be assigned after the delivery is dispatched."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Dispatch Delivery with Assigned Driver (Priority: P1)

As a dispatcher, I want to dispatch a delivery that has a driver assigned, so that the delivery process can begin.

**Why this priority**: Core functionality of dispatching a delivery.

**Independent Test**: Can be tested by creating a delivery, assigning a driver, and attempting dispatch.

**Acceptance Scenarios**:

1. **Given** a delivery has a driver assigned, **When** dispatcher attempts to dispatch, **Then** delivery is successfully dispatched.
2. **Given** a delivery has no driver assigned, **When** dispatcher attempts to dispatch, **Then** dispatch is blocked.

---

### User Story 2 - Assign Driver to Dispatched Delivery (Priority: P2)

As a dispatcher, I want to assign a driver to a delivery that has already been dispatched, so that the delivery can be fulfilled.

**Why this priority**: Necessary for operational flow.

**Independent Test**: Can be tested by creating a delivery, dispatching it, and assigning a driver.

**Acceptance Scenarios**:

1. **Given** a delivery has been dispatched, **When** dispatcher assigns a driver, **Then** driver is successfully assigned to the delivery.

---

### Edge Cases

- What happens when a driver is reassigned?
- How does the system handle concurrent dispatch requests?
- What happens if a delivery is cancelled after dispatch?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST prevent delivery dispatch if no driver is pre-assigned or assigned.
- **FR-002**: System MUST allow driver assignment at any time, including prior to dispatching (pre-assignment) or after dispatching.

### Key Entities

- **Delivery**: Represents the shipment, with attributes like status and assigned driver.
- **Driver**: Represents the person assigned to a delivery.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of dispatches require a valid driver assignment (or clarification of policy).
- **SC-002**: 95% of driver assignments to dispatched deliveries are processed within 1 second.
- **SC-003**: Reduction in 'orphan' deliveries (dispatched but unassigned, or assigned but not dispatched) to 0.

## Assumptions

- Delivery status tracking exists independently of this feature.
- Driver records are available and valid in the system.
- Dispatch is a discrete action initiated by a dispatcher.

## Formal Requirements & Business KPI Mapping

```alloy
sig Driver {}

abstract sig DeliveryStatus {}
one sig Created, Dispatched extends DeliveryStatus {}

sig Delivery {
    var status: one DeliveryStatus,
    var assignedDriver: lone Driver
}

-- Fact: Dispatch requires an assigned driver (pre-assigned or assigned)
pred DispatchPossible[d: Delivery] {
    some d.assignedDriver
}

-- Operation: Dispatch
pred dispatch[d: Delivery] {
    DispatchPossible[d]
    d.status' = Dispatched
    d.assignedDriver' = d.assignedDriver
}

-- Operation: Assign Driver (allowed at any time)
pred assignDriver[d: Delivery, dr: Driver] {
    d.assignedDriver' = dr
    d.status' = d.status
}

-- Scenario: Pre-assignment allowed
run {
    some d: Delivery, dr: Driver | {
        assignDriver[d, dr]
        dispatch[d]
    }
}
```
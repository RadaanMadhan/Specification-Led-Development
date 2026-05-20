# Feature Specification: Inventory Dispatch Rule

**Feature Branch**: `013-perishable-dispatch-rule`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Perishable goods must only be assigned to delivery trucks marked as 'Refrigerated'."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Assign Perishable Goods (Priority: P1)

As a dispatcher, I want to ensure that perishable goods are assigned only to refrigerated trucks so that goods remain in good condition.

**Why this priority**: Directly implements the core constraint and ensures product safety.

**Independent Test**: Attempt to assign a perishable good to a standard truck. Verify that the system prevents the assignment and displays a clear error message.

**Acceptance Scenarios**:

1. **Given** a perishable good is selected for dispatch, **When** the dispatcher attempts to assign it to a standard truck, **Then** the system rejects the assignment and informs the user.
2. **Given** a perishable good is selected for dispatch, **When** the dispatcher attempts to assign it to a refrigerated truck, **Then** the system successfully processes the assignment.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure safety of perishable goods | `fact { all g: Goods | g.type = Perishable implies g.assignedTruck.type = Refrigerated }` | Telemetry on dispatch rejections |

---

### User Story 2 - Assign Non-Perishable Goods (Priority: P2)

As a dispatcher, I want to be able to assign non-perishable goods to any available truck so that I can optimize dispatch efficiency.

**Why this priority**: Essential for routine dispatch operations not involving perishable goods.

**Independent Test**: Assign a non-perishable good to both a standard truck and a refrigerated truck. Verify that both assignments succeed.

**Acceptance Scenarios**:

1. **Given** a non-perishable good is selected for dispatch, **When** the dispatcher assigns it to a standard truck, **Then** the assignment is successful.
2. **Given** a non-perishable good is selected for dispatch, **When** the dispatcher assigns it to a refrigerated truck, **Then** the assignment is successful.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Optimize fleet utilization | `fact { all g: Goods | g.type = NonPerishable implies g.assignedTruck in (Refrigerated + Standard) }` | Fleet utilization metrics |

### Edge Cases

- What happens when a good's perishable status changes during assignment? (Assume assignment locked to status at time of selection).
- How does system handle trucks with mixed cargo? (Out of scope for this rule, assume rule applies to the whole cargo of the truck).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST classify goods as either 'Perishable' or 'Non-Perishable'.
- **FR-002**: System MUST classify trucks as either 'Refrigerated' or 'Standard'.
- **FR-003**: System MUST prevent assignment of 'Perishable' goods to 'Standard' trucks.
- **FR-004**: System MUST allow assignment of 'Non-Perishable' goods to both 'Refrigerated' and 'Standard' trucks.

### Key Entities

- **Good**: Represents the item being dispatched. Key attribute: type (Perishable / Non-Perishable).
- **Truck**: Represents the delivery vehicle. Key attribute: type (Refrigerated / Standard).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of perishable goods assigned to refrigerated trucks.
- **SC-002**: 0% of perishable goods assigned to non-refrigerated trucks.
- **SC-003**: Dispatch system rejects invalid assignments within 1 second.

## Assumptions

- Inventory and Fleet management systems are integrated.
- Goods classification (Perishable/Non-Perishable) is accurate and available in the inventory system.
- Truck classification (Refrigerated/Standard) is accurate and available in the fleet management system.

## Formal Requirements & Business KPI Mapping
```alloy
sig Goods {
  type: GoodsType
}
abstract sig GoodsType {}
one sig Perishable, NonPerishable extends GoodsType {}

sig Truck {
  type: TruckType
}
abstract sig TruckType {}
one sig Refrigerated, Standard extends TruckType {}

sig Assignment {
  good: Goods,
  truck: Truck
}

fact DispatchRule {
  all a: Assignment | 
    a.good.type = Perishable implies a.truck.type = Refrigerated
}
```

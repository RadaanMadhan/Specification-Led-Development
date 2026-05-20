# Feature Specification: Perishable Inventory Dispatch Rule

**Feature Branch**: `066-perishable-inventory-rule`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Perishable goods must only be assigned to delivery trucks marked as 'Refrigerated'."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Dispatching Perishable Goods (Priority: P1)

As a dispatcher, I want to ensure that perishable goods are assigned only to appropriate delivery vehicles, so that product quality is maintained during transit.

**Why this priority**: Ensures product integrity and reduces spoilage, which is critical for perishable items.

**Independent Test**: Attempt to assign a perishable item to a standard (non-refrigerated) truck and verify the system blocks the action.

**Acceptance Scenarios**:

1. **Given** a perishable item in inventory, **When** the dispatcher attempts to assign it to a 'Standard' truck, **Then** the system displays an error and prevents the assignment.
2. **Given** a perishable item in inventory, **When** the dispatcher attempts to assign it to a 'Refrigerated' truck, **Then** the system successfully completes the assignment.

---

### User Story 2 - Dispatching Non-Perishable Goods (Priority: P2)

As a dispatcher, I want to assign non-perishable goods to any available truck, so that I have maximum flexibility in dispatching.

**Why this priority**: Optimizes fleet utilization for goods that do not require specialized transport.

**Independent Test**: Assign a non-perishable item to both 'Standard' and 'Refrigerated' trucks and verify both actions succeed.

**Acceptance Scenarios**:

1. **Given** a non-perishable item in inventory, **When** the dispatcher attempts to assign it to a 'Standard' truck, **Then** the system successfully completes the assignment.
2. **Given** a non-perishable item in inventory, **When** the dispatcher attempts to assign it to a 'Refrigerated' truck, **Then** the system successfully completes the assignment.

---

### Edge Cases

- What happens when a truck's refrigerated status changes (e.g., maintenance)?
- How does the system handle bulk assignment of mixed goods (perishable and non-perishable) to the same vehicle?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST identify if an inventory item is classified as 'Perishable'.
- **FR-002**: System MUST identify if a delivery truck is classified as 'Refrigerated'.
- **FR-003**: System MUST validate that if an item is 'Perishable', the assigned truck MUST be 'Refrigerated'.
- **FR-004**: System MUST reject any dispatch assignment that violates the perishable-to-refrigerated requirement.

### Key Entities

- **Inventory Item**: An item for dispatch, with attribute `isPerishable` (Boolean).
- **Delivery Truck**: A vehicle for transport, with attribute `isRefrigerated` (Boolean).
- **Dispatch Assignment**: A link between an Inventory Item and a Delivery Truck.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of dispatch assignments for 'Perishable' items are to 'Refrigerated' trucks.
- **SC-002**: System blocks 100% of invalid dispatch attempts (Perishable to Non-refrigerated) within 1 second.
- **SC-003**: Dispatcher error rate related to incompatible vehicle assignment is reduced to 0%.

## Assumptions

- Inventory Management system provides the `isPerishable` attribute.
- Fleet Management system provides the `isRefrigerated` attribute.
- 'Perishable' items cannot be reassigned to non-refrigerated trucks once assigned.
- Mixed cargo handling is outside the scope of this initial rule.

## Formal Requirements & Business KPI Mapping
```alloy
sig InventoryItem {
    isPerishable: one Bool
}

sig DeliveryTruck {
    isRefrigerated: one Bool
}

sig DispatchAssignment {
    item: one InventoryItem,
    truck: one DeliveryTruck
}

fact DispatchRule {
    all a: DispatchAssignment | 
        a.item.isPerishable = True implies a.truck.isRefrigerated = True
}
```
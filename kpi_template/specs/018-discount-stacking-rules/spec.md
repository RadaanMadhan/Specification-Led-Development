# Feature Specification: Discount Stacking Rules

**Feature Branch**: `015-discount-stacking-rules`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Users can apply multiple discounts, but a 'Percentage Off' cannot be combined with a 'Buy One Get One' offer."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Apply Multiple Compatible Discounts (Priority: P1)

Users can apply multiple compatible discounts to a single cart to maximize savings, provided they do not violate stacking rules.

**Why this priority**: Core functionality that enables the primary benefit of discount stacking.

**Independent Test**: Add two compatible discounts (e.g., two different 'Percentage Off' discounts, or a 'Percentage Off' and a 'Fixed Amount' discount) to a cart and verify both are applied.

**Acceptance Scenarios**:

1. **Given** a cart with eligible items, **When** a user applies a 'Percentage Off' discount A and a 'Percentage Off' discount B, **Then** both discounts are applied to the order.
2. **Given** a cart with eligible items, **When** a user applies a 'Percentage Off' discount and a 'Fixed Amount' discount, **Then** both discounts are applied to the order.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Increase customer conversion | fact { all c: Cart | count(c.discounts) > 1 implies (no d1, d2: c.discounts | d1.type = Percentage and d2.type = BOGO) } | User feedback on discount application |

---

### User Story 2 - Prevent Incompatible Discount Stacking (Priority: P1)

The system prevents users from combining 'Percentage Off' and 'Buy One Get One' (BOGO) discounts in the same transaction to maintain business margin control.

**Why this priority**: Essential business rule to prevent excessive discounting.

**Independent Test**: Attempt to apply a 'Buy One Get One' discount when a 'Percentage Off' discount is already applied, and verify it is rejected with an informative error message.

**Acceptance Scenarios**:

1. **Given** a cart with a 'Percentage Off' discount already applied, **When** the user attempts to apply a 'Buy One Get One' discount, **Then** the system rejects the BOGO discount and notifies the user.
2. **Given** a cart with a 'Buy One Get One' discount already applied, **When** the user attempts to apply a 'Percentage Off' discount, **Then** the system rejects the Percentage Off discount and notifies the user.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain profit margins | fact { all c: Cart | some d1, d2: c.discounts | d1.type = Percentage and d2.type = BOGO implies false } | Monitor failed discount application attempts |

---

### Edge Cases

- What happens when a user tries to remove a discount?
- How does the system handle discounts that are automatically applied vs. user-entered?
- What happens if a cart is updated (items added/removed) making a previously applied discount invalid?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow application of multiple compatible discounts.
- **FR-002**: System MUST identify and categorize discount types (Percentage Off, Buy One Get One, Fixed Amount).
- **FR-003**: System MUST validate compatibility of new discounts against already applied discounts in the cart.
- **FR-004**: System MUST reject incompatible discounts with a clear, user-friendly error message.

### Key Entities *(include if feature involves data)*

- **Discount**: Represents a promotional offer (attributes: type, value, compatibility rules).
- **Cart**: Represents the user's current shopping session (attributes: items, applied discounts).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of attempts to combine 'Percentage Off' and 'Buy One Get One' discounts are blocked.
- **SC-002**: 100% of allowed compatible discount combinations are successfully applied.
- **SC-003**: User error rate for discount application decreases by 20% due to clear rejection messages.

## Assumptions

- 'Percentage Off' and 'Buy One Get One' are the only currently defined discount types requiring stacking restriction.
- The system has a centralized discount validation engine.
- A user session represents a single cart transaction.

## Formal Requirements & Business KPI Mapping

```alloy
// Alloy model for Discount Stacking Rules

enum DiscountType { PercentageOff, BOGO, FixedAmount }

sig Discount {
    type: DiscountType
}

sig Cart {
    discounts: set Discount
}

// Rule: A 'Percentage Off' cannot be combined with a 'Buy One Get One' offer
fact NoPercentageBOGOStacking {
    all c: Cart |
        let dTypes = c.discounts.type |
            not (PercentageOff in dTypes and BOGO in dTypes)
}

// Dummy predicate to allow for checking satisfiability
pred show() {
    #Cart > 0
    #Discount > 1
}
run show for 5
```

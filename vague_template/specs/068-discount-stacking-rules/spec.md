# Feature Specification: Discount Stacking Rule

**Feature Branch**: `068-discount-stacking-rules`
**Created**: 2026-05-20
**Status**: Draft
**Input**: User description: "Users can apply multiple discounts, but a 'Percentage Off' cannot be combined with a 'Buy One Get One' offer."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Apply Multiple Compatible Discounts (Priority: P1)

As a customer, I want to apply multiple discounts to my order, such as a 'Percentage Off' and a 'Flat Amount Off', so that I can maximize my savings.

**Why this priority**: Core functionality allowing customers to benefit from stacking multiple compatible discounts.

**Independent Test**: Add two compatible discounts (e.g., 'Percentage Off' and 'Flat Amount Off') to the cart and verify both are applied correctly to the order total.

**Acceptance Scenarios**:

1. **Given** a shopping cart with items, **When** I apply a 'Percentage Off' discount and a 'Flat Amount Off' discount, **Then** both discounts are applied to the order total.

---

### User Story 2 - Prevent Incompatible Discount Stacking (Priority: P1)

As a customer, if I have already applied a 'Percentage Off' discount, I should not be allowed to apply a 'Buy One Get One' (BOGO) offer to the same order.

**Why this priority**: Enforces the business rule preventing invalid stacking combinations.

**Independent Test**: Apply a 'Percentage Off' discount to the cart, then attempt to apply a 'BOGO' offer and verify that the system rejects the second discount with a clear message.

**Acceptance Scenarios**:

1. **Given** a cart with an active 'Percentage Off' discount, **When** I attempt to add a 'BOGO' offer, **Then** the BOGO offer is rejected and I am informed that it cannot be combined with the existing 'Percentage Off' discount.
1. **Given** a cart with an active 'BOGO' offer, **When** I attempt to add a 'Percentage Off' discount, **Then** the 'Percentage Off' discount is rejected and I am informed that it cannot be combined with the existing 'BOGO' offer.

### Edge Cases

- What happens when a discount code expires while being applied?
- How does the system handle an item removal that triggers a BOGO offer invalidation?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow stacking of compatible discount types (e.g., 'Percentage Off' + 'Flat Amount Off').
- **FR-002**: System MUST forbid stacking of 'Percentage Off' discounts with 'Buy One Get One' (BOGO) offers.
- **FR-003**: System MUST provide clear, user-friendly feedback when a discount cannot be applied due to stacking rules.
- **FR-004**: System MUST maintain the state of active discounts in the cart.

### Key Entities

- **Discount**: Represents a type of discount (Percentage, Flat Amount, BOGO).
- **Cart**: Represents the customer's shopping basket containing items and applied discounts.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Invalid discount combinations are rejected 100% of the time based on defined rules.
- **SC-002**: Valid discount stacking combinations are applied correctly within 1 second of user action.
- **SC-003**: Users receive a clear error message explaining why a discount was not applied in 100% of invalid stacking attempts.

## Assumptions

- 'Percentage Off', 'Flat Amount Off', and 'BOGO' are the defined discount types in the system.
- An existing mechanism for applying and validating discounts exists.
- The UI handles display of error messages based on system responses.

## Formal Requirements & Business KPI Mapping

```alloy
abstract sig DiscountType {}
one sig PercentageOff, FlatAmountOff, BOGO extends DiscountType {}

sig Discount {
    type: DiscountType
}

sig Cart {
    discounts: set Discount
}

pred validStacking(c: Cart) {
    -- A cart cannot contain both PercentageOff and BOGO discounts
    not (some d1, d2: c.discounts | 
        d1.type = PercentageOff and d2.type = BOGO
    )
}

run {} for 5
```

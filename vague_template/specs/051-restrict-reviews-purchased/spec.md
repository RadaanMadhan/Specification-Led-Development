# Feature Specification: Restrict Reviews to Purchased Products

**Feature Branch**: `051-restrict-reviews-purchased`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: Implement a rule where users cannot review a product they have not purchased.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Review Purchased Product (Priority: P1)

As a customer who has purchased a product, I want to be able to leave a review so that I can share my experience.

**Why this priority**: Core functionality of the review system.

**Independent Test**: Perform a purchase, navigate to the product page, and successfully submit a review.

**Acceptance Scenarios**:

1. **Given** I have purchased Product A, **When** I navigate to the review page for Product A, **Then** I am able to submit a review.
2. **Given** I have purchased Product A, **When** I submit a valid review, **Then** the review is saved and displayed on the product page.

---

### User Story 2 - Prevent Non-Purchased Product Review (Priority: P1)

As a system, I want to restrict review submission to verified purchasers so that the reviews reflect actual product usage.

**Why this priority**: Directly implements the requested restriction.

**Independent Test**: Navigate to a product page that has not been purchased and attempt to submit a review; verify that the action is blocked.

**Acceptance Scenarios**:

1. **Given** I have not purchased Product B, **When** I navigate to the review page for Product B, **Then** I am informed that I cannot review this product.
2. **Given** I have not purchased Product B, **When** I attempt to submit a review for Product B, **Then** the submission is blocked and an error message is displayed.

---

### Edge Cases

- What happens when a user purchases a product but returns it? Reviews are allowed only if the return was initiated after the review was submitted.
- How does the system handle bulk purchases?
- What happens if a purchase is made but the order is still "pending"?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST verify the user's purchase history against the requested product before allowing a review submission.
- **FR-002**: System MUST reject review submissions from users who have not completed an order for the product.
- **FR-003**: System MUST display a clear and helpful error message explaining why a user cannot review a product they haven't purchased.
- **FR-004**: System MUST maintain the integrity of the review database by enforcing this restriction at the API/service level.

### Key Entities

- **Review**: Represents the user's feedback, associated with a user, a product, and optionally an order ID.
- **Order**: Represents a completed transaction, linking a user to one or more products.
- **Product**: Represents the item being reviewed.
- **User**: Represents the customer who may have purchased products.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of review submissions successfully validated against purchase history.
- **SC-002**: 0% of published reviews are from users without a verified purchase record for the product.
- **SC-003**: User satisfaction with review integrity increases.

## Assumptions

- We have a robust system to track order completion and link it to user accounts.
- Products have a unique identifier that can be used across orders and reviews.
- Reviews are only allowed after a purchase is fully completed (order status check).

## Formal Requirements & Business KPI Mapping
```alloy
sig User {}
sig Product {}
sig Order {
  user: User,
  products: set Product,
  status: OrderStatus
}
enum OrderStatus { Completed, Pending, Cancelled }

sig Review {
  user: User,
  product: Product
}

-- Constraint: Only users who have a completed order for a product can review it
fact RestrictReviewsToPurchased {
  all r: Review | some o: Order | 
    o.user = r.user and 
    r.product in o.products and 
    o.status = Completed
}
```
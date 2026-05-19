# Feature Specification: Restrict Product Reviews to Purchasers

**Feature Branch**: `048-restrict-reviews-purchased`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Implement a rule where users cannot review a product they have not purchased."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Review Purchased Product (Priority: P1)

As a customer who has purchased a product, I want to leave a review for that product so that I can share my experience.

**Why this priority**: Core functionality that maintains the integrity of the review system.

**Independent Test**: Given a user has a completed purchase for a product, attempt to submit a review for that product and verify it is accepted.

**Acceptance Scenarios**:

1. **Given** a user has a "completed" purchase for "Product A", **When** the user submits a review for "Product A", **Then** the review is accepted and stored.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain review integrity | `fact { all r: Review | r.author in r.product.purchasers }` | Review database audit logs |

---

### User Story 2 - Prevent Review of Non-Purchased Product (Priority: P1)

As a user who has not purchased a product, I want to be prevented from leaving a review for that product so that only verified purchasers can provide feedback.

**Why this priority**: Critical for preventing fraudulent reviews.

**Independent Test**: Given a user has no purchase history for "Product B", attempt to submit a review for "Product B" and verify it is rejected.

**Acceptance Scenarios**:

1. **Given** a user has no purchase history for "Product B", **When** the user attempts to submit a review for "Product B", **Then** the system rejects the submission with a clear error message.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Prevent fraudulent reviews | `fact { no r: Review | r.author not in r.product.purchasers }` | Telemetry on blocked review attempts |

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST verify that the user has a valid, completed purchase record for a product before accepting a review for that product.
- **FR-002**: System MUST display an error message if a user attempts to review a product they have not purchased.
- **FR-003**: System MUST identify "completed" purchases based on defined status criteria (e.g., delivered or confirmed).

### Key Entities

- **User**: The actor initiating the review.
- **Product**: The item being reviewed.
- **Purchase**: The transaction record linking User to Product.
- **Review**: The feedback content submitted by the User.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of published reviews are validated against purchase history.
- **SC-002**: Unauthorized review attempts are blocked with a clear user-facing explanation in under 500ms.
- **SC-003**: Support tickets related to fraudulent or unverified reviews reduced to near zero.

## Assumptions

- User authentication is handled by an existing system.
- "Purchase" implies a successfully completed transaction.
- Product reviews are linked to specific product identifiers.

## Formal Requirements & Business KPI Mapping
```alloy
sig User {}
sig Product { purchasers: set User }
sig Review { author: User, product: Product }

fact {
  all r: Review | r.author in r.product.purchasers
}
```

# Feature Specification: Restrict Guest Checkout

**Feature Branch**: `001-restrict-guest-checkout`
**Created**: 2026-05-19
**Status**: Draft
**Input**: User description: "Add a restriction so that guest users cannot access the checkout page without an email address."

## User Scenarios & Testing

### User Story 1 - Restrict Checkout Access (Priority: P1)

Guest users who haven't provided an email address are prevented from accessing the checkout page.

**Why this priority**: Directly addresses the core requirement to restrict unauthorized/unidentified guest access.

**Independent Test**: Navigate to the checkout page as a guest without an email. Confirm redirection to email capture form.

**Acceptance Scenarios**:

1. **Given** a guest user has no email on file, **When** they attempt to access the checkout page, **Then** they are redirected to an email collection page.
2. **Given** a guest user is on the email collection page, **When** they enter a valid email address, **Then** they are granted access to the checkout page.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure all checkouts are associated with an email | `fact { all c: Checkout | some u: GuestUser | c.user = u and some u.email }` | Telemetry on checkout access events |

---

### User Story 2 - Email Validation (Priority: P2)

Guest users must provide a valid email format before proceeding to checkout.

**Why this priority**: Essential to ensure the email captured is usable.

**Independent Test**: Enter an invalid email on the collection page. Confirm error message and inability to proceed.

**Acceptance Scenarios**:

1. **Given** a guest user is entering an email, **When** they provide an invalid email format, **Then** an error message is displayed and they remain on the collection page.
2. **Given** a guest user is entering an email, **When** they provide a valid email format, **Then** they are successfully redirected to the checkout page.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Improve contact data quality | `fact { all e: Email | isValid(e) }` | Validation success rate |

## Requirements

### Functional Requirements

- **FR-001**: System MUST identify the email status of a guest user.
- **FR-002**: System MUST restrict access to the checkout page for guests without an email.
- **FR-003**: System MUST provide an email collection interface.
- **FR-004**: System MUST validate the format of the entered email.

### Key Entities

- **GuestUser**: Represents a visitor to the site.
- **Checkout**: The process of completing a purchase.
- **Email**: Contact information required for purchase.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Guest checkout abandonment due to email collection is tracked and stays below 5%.
- **SC-002**: 100% of guest checkouts have a valid email address associated.
- **SC-003**: User feedback on email collection is positive.

## Assumptions

- A guest user session can be tracked.
- An email collection page exists or can be easily added.
- The checkout page is protected behind this requirement.

## Formal Requirements & Business KPI Mapping
```alloy
sig GuestUser { email: lone Email }
sig Email {}
sig Checkout { user: one GuestUser }
fact { all c: Checkout | some c.user.email }
```
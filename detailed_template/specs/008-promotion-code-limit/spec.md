# Feature Specification: Promotion Code Application Limit

**Feature Branch**: `004-promotion-code-limit`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: Ensure a promotion code cannot be applied more than once per customer account.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Redeem New Promotion Code (Priority: P1)

As a customer, I want to redeem a promotion code that I haven't used before, so I can receive the associated discount.

**Why this priority**: Core functionality; ensures customers can still use valid promotions.

**Independent Test**: Can be tested by applying a valid, unused code to a customer account and verifying the discount is applied.

**Acceptance Scenarios**:

1. **Given** a customer account has not used promotion code "SAVE10", **When** the customer applies "SAVE10", **Then** the promotion code is successfully applied and the discount is granted.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure correct discount application | fact { no c: CustomerAccount | redeemedCode(c, p) } | Telemetry on successful redemption |

---

### User Story 2 - Prevent Reuse of Used Promotion Code (Priority: P1)

As a customer, I should be prevented from using a promotion code that I have already redeemed in the past, to prevent abuse.

**Why this priority**: Essential to satisfy the feature requirement.

**Independent Test**: Can be tested by applying a previously used promotion code and verifying it is rejected.

**Acceptance Scenarios**:

1. **Given** a customer account has already used promotion code "SAVE10", **When** the customer attempts to apply "SAVE10" again, **Then** the system rejects the code with a clear error message.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Prevent promotion abuse | fact { all c: CustomerAccount, p: PromotionCode | redeemedCode(c, p) implies not canRedeem(c, p) } | Count of rejected redemption attempts |

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST track redemption history for each customer account per promotion code.
- **FR-002**: System MUST validate if a promotion code has already been redeemed by the customer account before application.
- **FR-003**: System MUST deny promotion code application if it has been used by the customer account previously.
- **FR-004**: System MUST record the redemption event upon successful application.

### Key Entities

- **PromotionCode**: Represents the discount offer, identified by a unique code.
- **CustomerAccount**: Represents the registered user, identified by a unique ID.
- **RedemptionRecord**: Represents the association between a customer and a redeemed promotion code, with a timestamp.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of previously redeemed promotion codes are rejected when re-applied to the same customer account.
- **SC-002**: 0% of valid, unused promotion codes are erroneously rejected.
- **SC-003**: The time taken to validate promotion code application is under 500ms for 99% of requests.

## Assumptions

- A customer account is uniquely identified in the system.
- Promotion codes are uniquely identified in the system.
- The system has access to a reliable redemption history database.

## Formal Requirements & Business KPI Mapping
```alloy
sig CustomerAccount {
  redeemed: set PromotionCode
}
sig PromotionCode {}

pred canRedeem(c: CustomerAccount, p: PromotionCode) {
  p not in c.redeemed
}

assert NoReuse {
  all c: CustomerAccount, p: PromotionCode | 
    p in c.redeemed implies not canRedeem(c, p)
}
check NoReuse for 5
```

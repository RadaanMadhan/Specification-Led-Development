# Feature Specification: Restrict Promotion Code Usage

**Feature Branch**: `###-restrict-promotion-code-usage`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Ensure a promotion code cannot be applied more than once per customer account."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Apply Promotion Code (Priority: P1)

As a customer, I want to apply a promotion code to my order so that I can receive a discount.

**Why this priority**: Core functionality for promotion codes.

**Independent Test**: Can be fully tested by applying a valid promotion code to an order.

**Acceptance Scenarios**:

1.  **Given** I am a logged-in customer and have a valid promotion code, **When** I apply the promotion code to my order, **Then** the discount is applied to my order total, and the promotion code is marked as used for my account.
2.  **Given** I am a logged-in customer and have an invalid promotion code, **When** I apply the promotion code to my order, **Then** an error message is displayed, and no discount is applied.

---

### User Story 2 - Reapply Used Promotion Code (Priority: P1)

As a customer, I want to be prevented from reapplying a promotion code that I have already successfully used.

**Why this priority**: Prevents abuse and ensures fair usage of promotion codes.

**Independent Test**: Can be fully tested by attempting to apply an already used promotion code.

**Acceptance Scenarios**:

1.  **Given** I am a logged-in customer and have previously used a specific promotion code successfully, **When** I attempt to apply the same promotion code again to a new order, **Then** an error message is displayed indicating the code has already been used, and no discount is applied.

---

### User Story 3 - Multiple Promotion Codes for Different Accounts (Priority: P2)

As a customer, I want to be able to use a promotion code if another customer has used it, as long as I have not.

**Why this priority**: Ensures that the restriction is per customer, not global per code.

**Independent Test**: Can be fully tested by having two different customer accounts try to use the same promotion code.

**Acceptance Scenarios**:

1.  **Given** two distinct logged-in customers (Customer A and Customer B) and a valid promotion code, **When** Customer A applies the promotion code and it is successfully used, **And** Customer B then attempts to apply the same promotion code, **Then** Customer B is able to apply the promotion code and receive the discount, and the promotion code is marked as used for Customer B's account.

---

### Edge Cases

- What happens if a customer applies a promotion code, but the order fails or is cancelled before completion?
- How is a promotion code tracked as "used" to prevent reapplication?
- What if a customer tries to use a promotion code that has reached its global usage limit?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST prevent a customer account from successfully applying the same promotion code more than once.
- **FR-002**: The system MUST maintain a record of which promotion codes have been successfully applied by each customer account.
- **FR-003**: The system MUST validate the eligibility of a promotion code for a given customer account, considering past usage.
- **FR-004**: The system MUST provide a clear error message to the customer if they attempt to reapply an already used promotion code.
- **FR-005**: The system MUST ensure that the usage of a promotion code by one customer does not prevent another, eligible customer from using the same code.

### Key Entities *(include if feature involves data)*

- **Customer**: Represents an individual user with an account.
- **Promotion Code**: Represents a code offering a discount. Key attributes: code, discount value, usage limits (global/per customer).
- **Promotion Code Usage Record**: Represents the successful application of a promotion code by a customer. Key attributes: customer ID, promotion code ID, date used.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Less than 0.1% of customer support tickets are related to issues with promotion code reapplication.
- **SC-002**: The system successfully prevents reapplication of a promotion code by the same customer in 100% of attempts.
- **SC-003**: Promotion code usage tracking and validation adds no more than 50ms latency to the order placement process.

## Assumptions

- An existing customer authentication and account system is in place.
- A mechanism for applying promotion codes to orders already exists.
- Promotion codes have an inherent "validity" (e.g., active, expired, maximum uses) that is checked before the per-customer usage.

## Formal Requirements & Business KPI Mapping

```alloy
// Define the Customer signature
sig Customer {
}

// Define the PromotionCode signature
sig PromotionCode {
}

// Define the PromotionCodeUsage signature, representing a customer applying a promotion code
sig PromotionCodeUsage {
    customer: one Customer,
    code: one PromotionCode
}

// Constraint: A customer can use a specific promotion code at most once.
// This means that for any given customer and promotion code, there can be at most one usage record.
fact {
    all c: Customer, pc: PromotionCode | lone (PromotionCodeUsage.customer.c & PromotionCodeUsage.code.pc)
}

// Predicate to simulate applying a promotion code
pred applyPromotionCode(c: Customer, pc: PromotionCode) {
    // If the code has not been used by this customer before, then a new usage record can be created.
    // This predicate doesn't actually "create" a new usage, but rather describes a state where
    // a usage exists after an application, given that it didn't exist before for this customer.
    no (PromotionCodeUsage.customer.c & PromotionCodeUsage.code.pc) => 
    some pu: PromotionCodeUsage | pu.customer = c and pu.code = pc
}

// Predicate to simulate attempting to reapply a promotion code
pred reapplyPromotionCode(c: Customer, pc: PromotionCode) {
    // If the code has been used by this customer before, then no new usage record can be created.
    some (PromotionCodeUsage.customer.c & PromotionCodeUsage.code.pc) => 
    no disj pu1, pu2: PromotionCodeUsage | pu1.customer = c and pu1.code = pc and pu2.customer = c and pu2.code = pc
}

// Example scenario to check the property:
// A customer applies a code, and then tries to apply it again.
// The second application should not result in a second usage record for the same customer and code.
run {
    // Initial state: a customer and a promotion code exist
    some c: Customer, pc: PromotionCode | {
        // Customer applies the code for the first time
        applyPromotionCode[c, pc]
        // Customer tries to apply the same code again
        // This second application should not create a second usage instance for c and pc
        reapplyPromotionCode[c, pc]
    }
} for 3

// Assert to explicitly check that a customer cannot use the same code twice
assert cannotUseCodeTwice {
    all c: Customer, pc: PromotionCode | lone {pu: PromotionCodeUsage | pu.customer = c and pu.code = pc}
}

check cannotUseCodeTwice for 3
```
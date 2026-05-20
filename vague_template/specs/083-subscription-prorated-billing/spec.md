# Feature Specification: Subscription Prorated Billing

**Feature Branch**: `083-subscription-prorated-billing`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Model a subscription billing engine with prorated upgrades. If a user upgrades mid-month, their next invoice must calculate the exact days spent on Plan A vs Plan B."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prorated Upgrade Calculation (Priority: P1)

As a subscriber, when I upgrade my plan in the middle of a billing cycle, I want my next invoice to accurately reflect the prorated charges for the time I spent on the old plan and the new plan, so that I am billed fairly.

**Why this priority**: This is the core requirement and essential for maintaining financial trust with the user.

**Independent Test**: Can be tested by initiating an upgrade at a specific day within a known billing cycle and verifying that the invoice amounts match the calculated prorated charges.

**Acceptance Scenarios**:

1. **Given** a user is on Plan A ($30/month) with a 30-day billing cycle, **When** they upgrade to Plan B ($60/month) on day 15, **Then** the next invoice should reflect 15 days on Plan A and 15 days on Plan B, resulting in $45 total charge.

---

### Edge Cases

- What happens when a user upgrades on the last day of the billing cycle?
- How does the system handle leap years or months with different total days for proration?
- What happens if a user upgrades multiple times within a single billing cycle?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST track subscription start dates and plan types per user.
- **FR-002**: System MUST calculate daily usage rates for all plans based on monthly pricing.
- **FR-003**: System MUST identify the exact day an upgrade occurred.
- **FR-004**: System MUST calculate the prorated amount for Plan A: (Plan A Monthly Price / Total Days in Month) * Days Spent on Plan A.
- **FR-005**: System MUST calculate the prorated amount for Plan B: (Plan B Monthly Price / Total Days in Month) * Days Spent on Plan B.
- **FR-006**: System MUST generate an invoice itemizing the prorated costs for both plans.

### Key Entities

- **Subscription**: Represents the active plan for a user within a billing cycle.
- **Plan**: Defines the monthly cost and attributes of a service level.
- **Invoice**: A bill generated for a user, containing prorated line items.
- **LineItem**: An individual component of an invoice, specifically the charge for a duration on a plan.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Proration calculations MUST be accurate to 2 decimal places.
- **SC-002**: Invoices MUST be generated within 1 hour of the billing cycle close.
- **SC-003**: 100% of prorated upgrades MUST be successfully calculated without manual intervention.

## Assumptions

- A billing cycle is assumed to be 30 days for simplicity, but the system should support variable month lengths.
- The subscription billing system handles all currency conversions.

## Formal Requirements & Business KPI Mapping

```alloy
module subscription

sig Plan {
    price: one Int
}

sig Subscription {
    planA: one Plan,
    planB: one Plan,
    upgradeDay: one Int, // Day 1 to 30
    totalDaysInMonth: one Int // Usually 30
} {
    upgradeDay > 0
    upgradeDay <= totalDaysInMonth
}

// Prorated calculation
fun calculateProratedCharge(s: Subscription): Int {
    let daysOnA = s.upgradeDay - 1
    let daysOnB = s.totalDaysInMonth - daysOnA
    let chargeA = (s.planA.price * daysOnA) / s.totalDaysInMonth
    let chargeB = (s.planB.price * daysOnB) / s.totalDaysInMonth
    chargeA + chargeB
}

assert UpgradeCalculationIsReasonable {
    all s: Subscription |
        let charge = calculateProratedCharge[s] |
            charge >= 0
}
check UpgradeCalculationIsReasonable for 5
```

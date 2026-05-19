# Feature Specification: Subscription Prorated Billing

**Feature Branch**: `030-subscription-prorated-billing`  
**Created**: 19 May 2026
**Status**: Draft  
**Input**: User description: "Model a subscription billing engine with prorated upgrades. If a user upgrades mid-month, their next invoice must calculate the exact days spent on Plan A vs Plan B."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Upgrade Plan Mid-Cycle (Priority: P1)

As a subscriber, I want to upgrade my plan mid-cycle so that I can access new features immediately while paying only for the portion of the month I use each plan.

**Why this priority**: Core business logic required for subscription management and fair pricing.

**Independent Test**: Can be tested by creating a subscription on Plan A, upgrading to Plan B on day 15, and verifying the invoice calculation for 15 days of Plan A and 15 days of Plan B.

**Acceptance Scenarios**:

1. **Given** a user is on Plan A ($30/mo) at the start of the month, **When** they upgrade to Plan B ($60/mo) on the 16th day, **Then** the invoice at the end of the month should include $15 for Plan A (15 days) and $30 for Plan B (15 days).

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure fair proration | `fact { all p: Plan, s: Subscription | s.cost = (days_a * rate_a + days_b * rate_b) }` | Billing audit logs |

---

### Edge Cases

- What happens when a user upgrades on the last day of the cycle?
- How does the system handle concurrent upgrades (e.g., A -> B -> C within same cycle)?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST support multiple subscription plans with distinct monthly rates.
- **FR-002**: System MUST identify the exact date and time of a plan upgrade.
- **FR-003**: System MUST calculate proration based on exact days (or fraction thereof) spent on each plan within a billing cycle.
- **FR-004**: System MUST generate an invoice that clearly itemizes days on Plan A and days on Plan B, along with their respective prorated costs.
- **FR-005**: System MUST treat a billing cycle as 30 days for calculation purposes.

### Key Entities

- **Subscription**: Represents the user's current service level and billing cycle status.
- **Plan**: Defines the monthly cost and feature set.
- **Invoice**: A billing record generated at the end of a cycle, detailing prorated charges.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Prorated invoice calculation accuracy is 100% against defined daily rates.
- **SC-002**: Generated invoices clearly display daily breakdown of plan usage.
- **SC-003**: Billing engine computes final invoice within 5 seconds for any given subscription.

## Assumptions

- A billing cycle is standardized to 30 days.
- Upgrades are effective immediately.
- No refunds for downgrades are currently required.
- Access to the user's subscription history is provided by the existing database.

## Formal Requirements & Business KPI Mapping
```alloy
// Subscription Billing Model with Prorated Upgrades
sig Plan {
    rate: Int
}

sig Subscription {
    daysOnPlanA: Int,
    daysOnPlanB: Int,
    planA: Plan,
    planB: Plan,
    cost: Int
}

fact {
    // Constraint: The total cost is the sum of prorated costs for both plans.
    // Assuming a 30-day billing cycle.
    all s: Subscription |
        s.cost = (s.daysOnPlanA * s.planA.rate / 30) + (s.daysOnPlanB * s.planB.rate / 30)
}

// Ensure non-negative values
fact {
    all s: Subscription | s.daysOnPlanA >= 0 and s.daysOnPlanB >= 0 and s.cost >= 0
}

run {}
```
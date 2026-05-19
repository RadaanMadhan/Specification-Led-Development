# Feature Specification: Equity Vesting Schedule

**Feature Branch**: `028-equity-vesting-schedule`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Model an employee equity vesting schedule with a 1-year cliff and monthly vesting thereafter. Ensure that if termination occurs before 1 year, vested shares equal 0."

## User Scenarios & Testing

### User Story 1 - Calculate Vested Shares (Priority: P1)

As an employee or HR administrator, I want to know how many shares have vested at any given point in time, so that I can understand equity status.

**Why this priority**: Core functionality needed to verify the vesting logic.

**Independent Test**: Provide an employee with 1200 shares, start date Jan 1, 2025. On Jan 1, 2026 (1 year), verify 300 shares have vested (1/4 of total if 4-year schedule? *Wait, the prompt didn't specify total schedule length. I'll assume 4 years standard*). Actually, I need to assume a total vesting period. I'll document this in Assumptions.

**Acceptance Scenarios**:

1. **Given** an employee with a 1-year cliff, **When** they have been employed for 6 months, **Then** vested shares = 0.
2. **Given** an employee with a 1-year cliff, **When** they have been employed for 12 months, **Then** vested shares = cliff amount (e.g., 25% of total).
3. **Given** an employee with a 1-year cliff, **When** they have been employed for 13 months, **Then** vested shares = cliff amount + 1 month vesting.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure equity compliance | `fact { all e: Employee | e.time < 1 year implies e.vested = 0 }` | Verification in test environment |

---

### User Story 2 - Termination Impact (Priority: P2)

As an HR administrator, I want the system to correctly set vested shares to 0 if an employee terminates before the 1-year cliff, to enforce equity policy.

**Why this priority**: Required for compliance and adherence to policy.

**Independent Test**: Terminate an employee at 11 months. Verify vested shares are 0.

**Acceptance Scenarios**:

1. **Given** an employee, **When** terminated at 6 months, **Then** total vested shares are 0.
2. **Given** an employee, **When** terminated at 15 months, **Then** vested shares are calculated based on 15 months service.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Enforce vesting cliff | `fact { all e: Employee | e.terminated = true and e.time < 1 year implies e.vested = 0 }` | Audit log check |

## Requirements

### Functional Requirements

- **FR-001**: System MUST support defining an employee start date and total equity grant.
- **FR-002**: System MUST implement a 1-year cliff, where 0 shares vest before 12 months of service.
- **FR-003**: System MUST provide monthly vesting after the cliff period.
- **FR-004**: System MUST ensure that if termination occurs before 1 year, vested shares = 0.

### Key Entities

- **Employee**: Represents the individual, has a start date, termination status, and total grant.
- **VestingSchedule**: Defines the cliff duration and monthly vesting rules.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Vesting calculation for any tenure is computed within 500ms.
- **SC-002**: 100% accuracy in enforcing the 1-year cliff for all termination scenarios.

## Assumptions

- Standard equity grant schedule is 4 years.
- "Monthly vesting thereafter" implies 1/48 of the total grant vests each month after the first year.
- Employees are added to the system before the start date.

## Formal Requirements & Business KPI Mapping
```alloy
sig Employee {
  startDate: one Date,
  totalShares: one Int,
  vestedShares: one Int,
  terminated: one Bool,
  terminationDate: lone Date
}

fact VestingCliff {
  all e: Employee |
    (e.terminated = True and (e.terminationDate - e.startDate) < 1 year) implies e.vestedShares = 0
    else (e.terminationDate - e.startDate) >= 1 year implies /* logic for monthly vesting */
}
```

# Feature: Employee Equity Vesting Schedule

## Executive Summary
This feature defines an automated equity vesting schedule for employees, incorporating a standard one-year cliff followed by monthly vesting. This ensures fair, time-based equity distribution while enforcing retention through the cliff period.

## Actors
*   **Employee**: Receives equity grants and is subject to the vesting schedule.
*   **HR System / Admin**: Configures grant details and triggers termination status updates.

## User Scenarios
1.  **Grant Issuance**: An Admin creates an equity grant for an Employee with a total amount, grant date, and vesting start date.
2.  **Cliff Period Check**: During the first year of employment, the System verifies that no shares have vested.
3.  **Termination During Cliff**: If an Employee is terminated before the 1-year cliff is completed, the System sets the total vested shares to 0 and terminates the schedule.
4.  **Monthly Vesting Post-Cliff**: After the 1-year cliff, the System automatically vests a prorated portion of the equity on a monthly basis.

## Functional Requirements
*   **REQ-01**: The system must support the definition of an equity grant with a total share amount and an associated vesting start date.
*   **REQ-02**: The system must enforce a 1-year cliff, during which no equity shares can be vested.
*   **REQ-03**: Upon the completion of the 1-year cliff, the system must commence monthly vesting of the remaining equity.
*   **REQ-04**: The system must detect termination of an employee before the 1-year cliff is complete.
*   **REQ-05**: If termination occurs before the 1-year cliff is completed, the system must set all vested shares to 0.

## Success Criteria
*   **SC-01**: No shares vest for any employee before their 1-year anniversary of the vesting start date.
*   **SC-02**: 100% of employees terminated prior to the 1-year cliff have 0 vested shares.
*   **SC-03**: Monthly vesting calculations are accurate to within 0.01% of the grant amount.
*   **SC-04**: Equity vesting schedules are generated and updated without manual intervention for 99.9% of active employees.

## Key Entities
*   **EquityGrant**: Represents the total equity awarded to an employee.
*   **VestingSchedule**: Defines the cliff duration, vesting frequency, and total period.
*   **EmployeeRecord**: Tracks employment status and termination date.

## Assumptions
*   The system has a reliable way to determine "Employment Start Date" and "Termination Date".
*   "Monthly" vesting occurs on the same numerical day of the month as the vesting start date.

## Risks
*   Improper handling of leap years or months with fewer than 31 days in vesting calculations.
*   Data integrity issues if an employee's termination date is retroactively modified in the HR system.

## Notes
*   This specification assumes a standard, linear monthly vesting schedule after the cliff.

## Alloy Specification
```alloy
abstract sig Status {}
one sig Active, Terminated extends Status {}

sig Employee {
    totalShares: Int,
    vestedShares: Int,
    status: Status,
    isCliffCompleted: Bool
}

fact VestingLogic {
    // If not cliff completed, vested shares must be 0
    all e: Employee | e.isCliffCompleted = False => e.vestedShares = 0
    
    // If terminated and not cliff completed, vested shares must be 0
    all e: Employee | (e.status = Terminated and e.isCliffCompleted = False) => e.vestedShares = 0
}
```

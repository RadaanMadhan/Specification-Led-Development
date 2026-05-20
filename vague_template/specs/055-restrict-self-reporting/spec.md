# Feature Specification: Restrict Self-Reporting

**Feature Branch**: `055-restrict-self-reporting`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Create a rule that prevents an employee from reporting directly to themselves in the HR org chart."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prevent Self-Manager Assignment during Employee Creation (Priority: P1)

As an HR administrator, I want to be prevented from assigning a new employee as their own manager, so that the organization chart remains logically consistent and free of self-referencing cycles.

**Why this priority**: Ensuring data integrity from the point of creation is critical to prevent invalid states in the organization chart.

**Independent Test**: Attempt to create a new employee and set the `manager_id` to the `employee_id`. Verify that the system rejects the creation.

**Acceptance Scenarios**:

1. **Given** a new employee record creation request, **When** the `manager_id` is set to the same as the employee's `id` (or prospective `id`), **Then** the system rejects the creation and returns a validation error.
2. **Given** a new employee record creation request, **When** the `manager_id` is set to a different employee's `id`, **Then** the system successfully creates the employee record.

---

### User Story 2 - Prevent Self-Manager Assignment during Updates (Priority: P1)

As an HR administrator, I want to be prevented from updating an existing employee's manager to be themselves, so that I cannot accidentally create a self-reporting cycle.

**Why this priority**: Prevents existing records from being modified into an invalid state.

**Independent Test**: Attempt to update an existing employee's manager field to their own employee ID. Verify the system rejects the update.

**Acceptance Scenarios**:

1. **Given** an existing employee, **When** an administrator updates the `manager_id` to be equal to the employee's `id`, **Then** the system rejects the update and returns a validation error.
2. **Given** an existing employee, **When** an administrator updates the `manager_id` to a valid different manager, **Then** the system successfully updates the employee record.

---

### User Story 3 - Prevent Bulk Self-Manager Assignment (Priority: P2)

As an HR administrator performing bulk updates, I want the system to reject any updates that attempt to make employees report to themselves, so that bulk imports or updates do not corrupt the org chart.

**Why this priority**: Necessary for high-volume data operations.

**Independent Test**: Perform a bulk update with a mix of valid and invalid (self-reporting) manager assignments. Verify that invalid ones fail and valid ones succeed.

**Acceptance Scenarios**:

1. **Given** a bulk update request containing multiple employee records, **When** one or more records attempt to assign an employee to themselves as manager, **Then** the system rejects only the invalid records and processes the valid ones (or rejects the entire batch, depending on business policy - assuming per-record validation for now).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST validate that an employee's `manager_id` is not equal to their own `id`.
- **FR-002**: System MUST return an informative error message when a self-reporting assignment is attempted.
- **FR-003**: System MUST apply this validation on both individual record creation and record updates.

### Key Entities

- **Employee**: Represents a person in the organization.
  - `id`: Unique identifier for the employee.
  - `manager_id`: Identifier for the employee's manager (nullable).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of attempts to assign an employee as their own manager are blocked by the system.
- **SC-002**: No employee records in the database have `manager_id == id`.
- **SC-003**: Average time to identify and block an invalid self-reporting attempt is sub-second.

## Assumptions

- The organization chart allows an employee to have no manager (`manager_id` is null).
- Data integrity is enforced at the application/service level.

## Formal Requirements & Business KPI Mapping
```alloy
sig Employee {
    manager: lone Employee
}

fact NoSelfReporting {
    all e: Employee | e.manager != e
}
```

# Feature Specification: Prevent Self-Reporting

**Feature Branch**: `002-prevent-self-reporting`  
**Created**: 2026-05-19
**Status**: Draft  
**Input**: User description: "Create a rule that prevents an employee from reporting directly to themselves in the HR org chart."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prevent Invalid Reporting Assignment (Priority: P1)

As an HR Admin, I want to ensure that no employee is assigned as their own supervisor, so that the organizational hierarchy remains valid and accurate.

**Why this priority**: Ensuring hierarchical integrity is critical for reporting and organizational structure compliance.

**Independent Test**: Attempt to assign an employee's supervisor field to their own employee ID and verify that the system rejects the assignment.

**Acceptance Scenarios**:

1. **Given** an employee 'A' currently reports to employee 'B', **When** an HR Admin attempts to change 'A's supervisor to 'A', **Then** the system rejects the request and displays an error message indicating that an employee cannot report to themselves.
2. **Given** a new employee 'C' is being added to the system, **When** an HR Admin attempts to set the supervisor to 'C', **Then** the system rejects the request and displays an error message.

### Edge Cases

- **Empty Supervisor**: What happens when an employee has no supervisor? (System should allow an empty supervisor field, representing top-level management).
- **Bulk Updates**: How does the system handle bulk updates? (System must validate every employee-supervisor relationship in the bulk update request against the rule).

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain organizational hierarchy integrity | `fact { all e: Employee | e.supervisor != e }` | System logs of rejected assignment attempts |

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST validate the employee-supervisor assignment request before persisting to the database.
- **FR-002**: System MUST reject any attempt to assign an employee as their own direct supervisor.
- **FR-003**: System MUST provide a user-friendly error message when a self-reporting violation is attempted.

### Key Entities

- **Employee**: Represents a person in the organization with an ID and a supervisor reference.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 0 instances of an employee being their own supervisor exist in the organization chart.
- **SC-002**: 100% of attempts to assign an employee to report to themselves are rejected by the system at the time of entry.

## Assumptions

- The organization chart data structure supports a single supervisor reference per employee.
- The assignment interface for managers/supervisors is the primary entry point for this validation.

## Formal Requirements & Business KPI Mapping
```alloy
sig Employee {
  supervisor: lone Employee
}

fact {
  all e: Employee | e.supervisor != e
}
```

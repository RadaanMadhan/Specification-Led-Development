# Feature Specification: Maker-Checker Workflow

**Feature Branch**: `038-maker-checker-workflow`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Implement a Maker-Checker workflow. The Maker submits the transaction, the Checker approves it. The Maker can never be the Checker. However, Admins can act as both Maker and Checker simultaneously."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Submit Transaction (Priority: P1)

As a user with the "Maker" role, I want to submit a transaction so that it can be reviewed and approved.

**Why this priority**: Core functionality needed to initiate the workflow.

**Independent Test**: Verify that a transaction submitted by a Maker is created with "Pending" status and assigned to the correct Maker.

**Acceptance Scenarios**:

1. **Given** a user with "Maker" role, **When** they submit a new transaction, **Then** the transaction is recorded with "Pending" status.

### User Story 2 - Approve Transaction (Priority: P1)

As a user with the "Checker" role, I want to approve a "Pending" transaction so that it can proceed to completion.

**Why this priority**: Essential for completing the workflow.

**Independent Test**: Verify that a "Pending" transaction is marked as "Approved" when approved by a "Checker".

**Acceptance Scenarios**:

1. **Given** a "Pending" transaction submitted by Maker A, **When** a user with "Checker" role (who is not Maker A) approves it, **Then** the transaction status becomes "Approved".

### User Story 3 - Maker Approval Restriction (Priority: P1)

As a system, I want to prevent Makers from approving their own submitted transactions to ensure integrity.

**Why this priority**: Critical security/integrity requirement.

**Independent Test**: Verify that a "Maker" cannot approve a transaction they submitted.

**Acceptance Scenarios**:

1. **Given** a "Pending" transaction submitted by Maker A, **When** Maker A attempts to approve it, **Then** the system denies the action with an error.

### User Story 4 - Admin Override (Priority: P2)

As a user with the "Admin" role, I want to submit and approve transactions to facilitate system management.

**Why this priority**: Enables administrative flexibility as requested.

**Independent Test**: Verify that an "Admin" can submit and approve any transaction, regardless of who submitted it.

**Acceptance Scenarios**:

1. **Given** a "Pending" transaction submitted by Maker A, **When** an "Admin" approves it, **Then** the transaction status becomes "Approved".

### Edge Cases

- What happens if the Checker tries to approve an already approved transaction?
- What happens if a non-Admin, non-Checker tries to approve a transaction?
- What happens if a transaction is cancelled?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST support roles: "Maker", "Checker", and "Admin".
- **FR-002**: System MUST allow "Maker" to submit transactions, setting initial status to "Pending".
- **FR-003**: System MUST allow "Checker" to approve "Pending" transactions, updating status to "Approved".
- **FR-004**: System MUST NOT allow a user to approve a transaction if they are the original submitter (the Maker), unless they also have the "Admin" role.
- **FR-005**: System MUST allow "Admin" to approve any "Pending" transaction, regardless of submission origin.

### Key Entities

- **Transaction**: A request submitted for approval, containing reference to the creator (Maker).
- **User/Role**: Identifies the actor and their permission set (Maker, Checker, Admin).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of transactions submitted by a Maker must remain "Pending" until approved by a valid, authorized Checker or Admin.
- **SC-002**: 0% of transactions submitted by a Maker can be approved by the same Maker.
- **SC-003**: Admin actions in the workflow are traceable and logged for audit purposes (if logging capability is assumed).

## Assumptions

- Transactions can be uniquely identified.
- Users are authenticated and their roles are reliably provided by the system.
- "Approved" is the terminal state for this workflow scope.

## Formal Requirements & Business KPI Mapping

```alloy
abstract sig Role {}
one sig MakerRole, CheckerRole, AdminRole extends Role {}

sig User { roles: set Role }

enum Status { Pending, Approved }

sig Transaction {
    maker: one User,
    status: one Status,
    checker: lone User
}

fact {
    // Only Users with MakerRole can be makers
    all t: Transaction | MakerRole in t.maker.roles
    // Only Users with CheckerRole can be checkers
    all t: Transaction | t.checker != none implies CheckerRole in t.checker.roles

    // Constraint: Maker can never be the Checker, unless Admin
    all t: Transaction |
        (t.checker != none and AdminRole not in t.checker.roles)
        implies t.checker != t.maker
}

// Ensure at least one transaction can be approved
run {} for 3 but 2 Transaction
```


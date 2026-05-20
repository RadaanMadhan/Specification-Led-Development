# Feature Specification: Maker-Checker Workflow

**Feature Branch**: `091-maker-checker-workflow`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Implement a Maker-Checker workflow. The Maker submits the transaction, the Checker approves it. The Maker can never be the Checker. However, Admins can act as both Maker and Checker simultaneously."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Transaction Submission and Approval (Priority: P1)

As a standard user (Maker), I need to submit transactions so that they can be reviewed by a qualified reviewer (Checker).

**Why this priority**: Core functionality of the feature.

**Independent Test**: Maker submits a transaction, Checker reviews and approves it, and the transaction is successfully completed.

**Acceptance Scenarios**:

1. **Given** a user with Maker role, **When** they submit a transaction, **Then** the transaction status is "pending approval".
2. **Given** a transaction in "pending approval" status, **When** a user with Checker role approves it, **Then** the transaction status becomes "approved".

---

### User Story 2 - Transaction Rejection (Priority: P1)

As a Checker, I need to reject transactions that do not meet requirements.

**Why this priority**: Essential for maintaining data integrity.

**Independent Test**: Maker submits, Checker rejects, transaction is marked as rejected.

**Acceptance Scenarios**:

1. **Given** a transaction in "pending approval" status, **When** a user with Checker role rejects it, **Then** the transaction status becomes "rejected".

---

### User Story 3 - Segregation of Duties Enforcement (Priority: P1)

As a standard user (Maker), I must be prevented from approving my own submissions.

**Why this priority**: Fundamental security constraint for the feature.

**Independent Test**: Maker tries to approve their own transaction, system denies the action.

**Acceptance Scenarios**:

1. **Given** a transaction submitted by User A, **When** User A attempts to approve it, **Then** the system denies the action.

---

### User Story 4 - Administrator Override (Priority: P2)

As an Administrator, I need to be able to submit and approve my own transactions to facilitate emergency changes or administrative tasks.

**Why this priority**: Allows administrative flexibility.

**Independent Test**: Admin submits, Admin approves, transaction is successful.

**Acceptance Scenarios**:

1. **Given** a user with Admin role, **When** they submit a transaction and then approve it, **Then** the system allows the action and transaction status becomes "approved".

---

### Edge Cases

- What happens when a Checker is deleted after submitting a transaction?
- How does the system handle concurrent approval attempts on the same transaction?
- Can a transaction be modified after submission but before approval?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST enforce segregation of duties for all standard users (Maker cannot be the same as Checker).
- **FR-002**: System MUST permit Administrators to act as both Maker and Checker for the same transaction.
- **FR-003**: System MUST track the "Maker" and "Checker" identity for every transaction.
- **FR-004**: System MUST ensure that a transaction cannot be approved by a standard user if they are the original Maker.
- **FR-005**: System MUST allow transactions to be in "pending approval", "approved", or "rejected" states.

### Key Entities

- **Transaction**: A request submitted by a user that requires approval. Attributes: id, maker_id, checker_id, status, timestamp.
- **User**: A system user. Attributes: id, role (Maker, Checker, Admin).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of transactions submitted by standard users require approval from a different user with the Checker role.
- **SC-002**: 100% of transactions approved by standard users are validated to ensure the approver is not the original submitter.
- **SC-003**: Administrators can successfully approve their own submitted transactions without triggering segregation violations.

## Assumptions

- "Standard user" refers to any user not assigned the "Admin" role.
- Transaction status transitions are atomic.
- Existing user roles (Maker, Checker, Admin) are available in the system.

## Formal Requirements & Business KPI Mapping

```alloy
abstract sig Role {}
one sig MakerRole, CheckerRole, AdminRole extends Role {}

sig User {
    roles: set Role
}

abstract sig Status {}
one sig Pending, Approved, Rejected extends Status {}

sig Transaction {
    maker: one User,
    checker: lone User,
    status: one Status
}

fact Constraints {
    // Maker must be a Maker or Admin
    all t: Transaction | (MakerRole in t.maker.roles) or (AdminRole in t.maker.roles)

    // Checker must be a Checker or Admin if assigned
    all t: Transaction | some t.checker => ((CheckerRole in t.checker.roles) or (AdminRole in t.checker.roles))

    // Standard user cannot approve own transaction
    all t: Transaction | (some t.checker and (AdminRole not in t.maker.roles and AdminRole not in t.checker.roles)) => t.maker != t.checker
}
```

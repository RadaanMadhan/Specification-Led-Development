# Feature Specification: Restrict Ticket Closure

**Feature Branch**: `020-restrict-ticket-closure`
**Created**: 2026-05-19
**Status**: Draft
**Input**: User description: "A support ticket cannot be closed unless a resolution code is applied and a customer reply has been logged within the last 24 hours."

## User Scenarios & Testing

### User Story 1 - Close Resolved Ticket (Priority: P1)

A support agent attempts to close a ticket that has been resolved and addressed with the customer recently.

**Why this priority**: Core business logic. Ensures closure requirements are met.

**Independent Test**:
1. Create a ticket.
2. Add a resolution code.
3. Log a customer reply.
4. Attempt to close the ticket.
Result: Successful.

**Acceptance Scenarios**:

1. **Given** a ticket has a resolution code and a customer reply in the last 24 hours, **When** the support agent clicks close, **Then** the ticket is closed successfully.
2. **Given** a ticket lacks a resolution code, **When** the support agent clicks close, **Then** the system displays a validation error and prevents closure.
3. **Given** a ticket has a resolution code but the customer reply was > 24 hours ago, **When** the support agent clicks close, **Then** the system displays a validation error and prevents closure.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure ticket resolution quality | fact { canClose(t) iff (t.hasResolutionCode and t.recentCustomerReply) } | Audit log of failed/successful closures |

## Requirements

### Functional Requirements

- **FR-001**: System MUST require a valid resolution code to be associated with a ticket before closure.
- **FR-002**: System MUST verify that a customer reply has been logged for the ticket within the last 24 hours prior to closure.
- **FR-003**: System MUST prevent ticket closure if either the resolution code is missing or no customer reply exists within the last 24 hours.
- **FR-004**: System MUST provide a clear, user-friendly error message indicating which requirement (resolution code or recent reply) was not met when closure is attempted.

### Key Entities

- **Ticket**: Represents the support request. Attributes include status, resolutionCode, lastCustomerReplyTimestamp.
- **SupportAgent**: User initiating the closure action.

## Success Criteria

### Measurable Outcomes

- **SC-001**: 100% of closed tickets have a valid resolution code.
- **SC-002**: 100% of closed tickets have a customer reply logged in the 24 hours preceding closure.
- **SC-003**: Support agents receive immediate feedback when attempting to close tickets failing the restriction criteria.

## Assumptions

- A "resolution code" is a pre-defined set of values that can be applied to a ticket.
- "Customer reply" refers to messages logged in the ticket's communication history.
- The ticket system has an existing mechanism to store the timestamp of the last customer reply.

## Formal Requirements & Business KPI Mapping
```alloy
abstract sig Status {}
one sig Open, Closed extends Status {}

abstract sig Bool {}
one sig True, False extends Bool {}

sig Ticket {
    status: one Status,
    hasResolutionCode: one Bool,
    recentCustomerReply: one Bool
}

pred canClose[t: Ticket] {
    t.hasResolutionCode = True and t.recentCustomerReply = True
}

fact ClosureRestriction {
    // A ticket cannot be closed unless a resolution code is applied and a customer reply has been logged within the last 24 hours.
    all t: Ticket | t.status = Closed => canClose[t]
}

// Dummy check to ensure the model can be analyzed
run {} for 5
```

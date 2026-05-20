# Feature Specification: Ticket Closure Rule

**Feature Branch**: `073-ticket-closure-rule`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "A support ticket cannot be closed unless a resolution code is applied and a customer reply has been logged within the last 24 hours."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Valid Ticket Closure (Priority: P1)

As a Support Representative, I want to close a support ticket that has a resolution code and a recent customer reply, so that the ticket lifecycle is correctly completed.

**Why this priority**: Core functionality of the feature.

**Independent Test**: Create a ticket, add a resolution code, add a customer reply 1 hour ago, attempt to close the ticket. It should succeed.

**Acceptance Scenarios**:

1. **Given** a support ticket with a resolution code, **And** a customer reply logged 1 hour ago, **When** I request to close the ticket, **Then** the ticket should be closed successfully.

---

### User Story 2 - Closure Rejected: Missing Resolution Code (Priority: P2)

As a Support Representative, I want to be prevented from closing a ticket that lacks a resolution code, so that all closed tickets have a documented resolution.

**Why this priority**: Ensures data integrity for support metrics.

**Independent Test**: Create a ticket, add a customer reply 1 hour ago, attempt to close the ticket without a resolution code. It should be rejected.

**Acceptance Scenarios**:

1. **Given** a support ticket WITHOUT a resolution code, **And** a customer reply logged 1 hour ago, **When** I request to close the ticket, **Then** the closure attempt should be rejected, **And** I should receive an error message indicating the missing resolution code.

---

### User Story 3 - Closure Rejected: Missing Recent Customer Reply (Priority: P2)

As a Support Representative, I want to be prevented from closing a ticket that has not had a customer reply in the last 24 hours, so that unresolved or stagnant issues are not prematurely closed.

**Why this priority**: Ensures support quality and customer engagement.

**Independent Test**: Create a ticket, add a resolution code, add a customer reply 48 hours ago, attempt to close the ticket. It should be rejected.

**Acceptance Scenarios**:

1. **Given** a support ticket with a resolution code, **And** the last customer reply was logged 48 hours ago, **When** I request to close the ticket, **Then** the closure attempt should be rejected, **And** I should receive an error message indicating the lack of a recent customer reply.

### Edge Cases

- What happens when a ticket has no customer replies at all?
- How does the system handle a ticket where the last customer reply was exactly 24 hours ago? (Assumption: 24 hours exactly is permitted or not? Let's assume inclusive of the 24-hour mark is permitted).
- What happens when a ticket is re-opened and then re-closed?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST require a resolution code to be applied to a support ticket before allowing it to be closed.
- **FR-002**: System MUST require at least one customer reply to be logged within the last 24 hours before allowing a ticket to be closed.
- **FR-003**: System MUST reject closure requests that do not satisfy both FR-001 and FR-002.
- **FR-004**: System MUST provide a clear, actionable error message to the user when a closure request is rejected due to FR-003.

### Key Entities

- **Support Ticket**: A record representing an issue reported by a customer.
- **Resolution Code**: A predefined category or code identifying how the ticket was resolved.
- **Customer Reply**: A communication from the customer associated with the ticket, including a timestamp.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of closed tickets meet the resolution code and 24-hour reply constraint.
- **SC-002**: Support representatives receive a clear feedback message within 2 seconds when a closure attempt is rejected.
- **SC-003**: Reduction in prematurely closed support tickets (tickets closed without customer interaction in the last 24h) by 90%.

## Assumptions

- The concept of a "support ticket" and "customer reply" exists in the system.
- The system has a mechanism to log customer replies with timestamps.
- A "resolution code" is a standard data field for ticket closure.
- The 24-hour window is defined as exactly 24 hours from the current time.

## Formal Requirements & Business KPI Mapping

```alloy
sig ResolutionCode {}
sig CustomerReply {}

sig Ticket {
    resolution: lone ResolutionCode,
    replies: set CustomerReply,
    isClosed: one Bool
}

abstract sig Bool {}
one sig True, False extends Bool {}

// Formal requirement: A ticket cannot be closed unless a resolution code is 
// applied and at least one customer reply has been logged.
fact TicketClosurePolicy {
    all t: Ticket | 
        t.isClosed = True => (some t.resolution and some t.replies)
}
```

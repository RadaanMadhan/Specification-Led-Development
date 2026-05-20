# Feature Specification: Company Scheduling System

**Feature Branch**: `095-company-scheduling-system`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Build a scheduling system. Meetings can be scheduled at any time, but no two meetings in the entire company can happen at the exact same time."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Schedule a Meeting (Priority: P1)

As an employee, I want to schedule a meeting with a defined start time and duration so that I can coordinate work with colleagues.

**Why this priority**: Core functionality of the scheduling system.

**Independent Test**: Can be tested by creating a meeting proposal and verifying it is added to the system schedule if it does not conflict.

**Acceptance Scenarios**:

1. **Given** an available time slot, **When** I submit a meeting proposal, **Then** the meeting is confirmed and added to the schedule.

---

### User Story 2 - Conflict Prevention (Priority: P1)

As an employee, I want the system to automatically prevent me from scheduling a meeting that conflicts with any other meeting in the company, so that meeting times remain exclusive.

**Why this priority**: Essential requirement to ensure no two meetings happen at the same time.

**Independent Test**: Can be tested by proposing a meeting during a time slot that is already occupied by an approved meeting and verifying the proposal is rejected.

**Acceptance Scenarios**:

1. **Given** an existing approved meeting, **When** I attempt to schedule a new meeting that overlaps with the existing one, **Then** the system rejects the proposal and notifies me of the conflict.

---

### User Story 3 - View Company Schedule (Priority: P2)

As an employee, I want to view all scheduled company meetings so that I can identify available time slots.

**Why this priority**: Necessary for users to know when to propose meetings.

**Independent Test**: Can be tested by viewing the company schedule and verifying that all approved meetings are listed.

**Acceptance Scenarios**:

1. **Given** several approved meetings, **When** I view the company schedule, **Then** I see all confirmed meetings in chronological order.

---

### Edge Cases

- What happens when two users propose a meeting at the exact same time simultaneously (race condition)?
- How does the system handle meetings that are cancelled, freeing up time slots?
- How does the system handle meetings that start immediately after another ends (exact boundary condition)?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow employees to propose meetings with a start time and a defined duration.
- **FR-002**: System MUST enforce a global, company-wide rule ensuring no two approved meetings overlap.
- **FR-003**: System MUST reject any meeting proposal that conflicts with an existing approved meeting.
- **FR-004**: System MUST allow users to view the company-wide schedule of approved meetings.
- **FR-005**: System MUST provide an immediate response indicating success or failure of a scheduling proposal.

### Key Entities

- **Meeting**: Represents a confirmed company event with a start time, duration, and title.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of conflicting meetings are successfully blocked at the moment of proposal.
- **SC-002**: Meeting proposal submission and validation completes in under 2 seconds.
- **SC-003**: 95% of users successfully schedule their meetings without encountering scheduling conflicts in their preferred slots (assuming availability).

## Assumptions

- The system acts as the single source of truth for company meetings.
- All employees use the same scheduling system.
- Meetings are considered to conflict if their time intervals (start time to end time) overlap in any way.

## Formal Requirements & Business KPI Mapping

```alloy
open util/ordering[Time]

sig Time {}

sig Meeting {
    start: Time,
    end: Time
} {
    // A meeting must have a positive duration.
    lt[start, end]
}

fact NoOverlap {
    // For any two distinct meetings, they must not overlap.
    // Two intervals [s1, e1) and [s2, e2) do not overlap if
    // e1 <= s2 OR e2 <= s1.
    all disj m1, m2: Meeting |
        lte[m1.end, m2.start] or lte[m2.end, m1.start]
}
```

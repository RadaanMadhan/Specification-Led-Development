# Feature Specification: Restrict Concurrent Sessions

**Feature Branch**: `069-restrict-concurrent-sessions`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Restrict concurrent sessions. If a user logs into a 4th device on a Basic plan, force logout the oldest active session."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Enforce Device Limit for Basic Plan (Priority: P1)

As a Basic plan user, I want to ensure my account is protected by limiting the number of active sessions, so that my account security is maintained.

**Why this priority**: Directly addresses the core business requirement to restrict concurrent access and maintain account integrity.

**Independent Test**: Login with 4 different devices as a Basic user and verify that only 3 sessions remain active, with the oldest being removed.

**Acceptance Scenarios**:

1. **Given** a user is on the Basic plan with 3 active sessions, **When** the user attempts to login on a 4th device, **Then** the oldest session is automatically logged out and the new session is successfully established.
2. **Given** a user is on the Basic plan with 2 active sessions, **When** the user logs in on a 3rd device, **Then** all 3 sessions remain active.

---

### Edge Cases

- What happens when a user has multiple sessions created at the exact same time? The session with the lexicographically smaller session ID will be considered older.
- What happens if the session management service is unreachable during a login attempt?
- How are concurrent logins from the same browser/device handled?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST identify the user's current subscription plan during the login process.
- **FR-002**: System MUST track the number of active sessions for each user.
- **FR-003**: System MUST permit a maximum of 3 concurrent active sessions for users on the 'Basic' plan.
- **FR-004**: System MUST identify the oldest active session for a user based on its creation timestamp.
- **FR-005**: System MUST terminate the oldest active session when a 'Basic' user initiates a login that exceeds the concurrent session limit.
- **FR-006**: System MUST ensure that the new session is established successfully after the oldest session is terminated.

### Key Entities

- **Session**: Represents an active user login, including a unique identifier, user association, and creation timestamp.
- **User Subscription**: Defines the user's current plan (e.g., Basic), which dictates concurrent session limits.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Basic users never exceed 3 concurrent active sessions.
- **SC-002**: The oldest session is reliably terminated within 1 second of a 4th login attempt by a Basic user.
- **SC-003**: 100% of login attempts by Basic users are successfully processed regardless of current session count (either by creating a new session or replacing the oldest).
- **SC-004**: Users receive a notification or clear indication when a session has been terminated due to the concurrent limit.

## Assumptions

- 'Basic' plan is clearly defined in the user management system.
- Session creation timestamp is accurately captured and persisted.
- The session termination process does not impact the integrity of other active sessions.

## Formal Requirements & Business KPI Mapping
-- Assume session-based auth system
-- Define basic constraint
sig User {
    plan: Plan,
    sessions: set Session
}
abstract sig Plan {}
one sig Basic extends Plan {}
one sig Premium extends Plan {}

sig Session {
    createdAt: Int
}

-- Constraint: Basic users limited to 3
fact ConcurrentSessionLimit {
    all u: User | u.plan = Basic => #u.sessions <= 3
}

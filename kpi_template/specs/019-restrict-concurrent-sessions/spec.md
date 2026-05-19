# Feature Specification: Restrict Concurrent Sessions

**Feature Branch**: `016-restrict-concurrent-sessions`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Restrict concurrent sessions. If a user logs into a 4th device on a Basic plan, force logout the oldest active session."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Maintain Session Limits for Basic Plan Users (Priority: P1)

As a Basic Plan user, I want my active sessions to be limited to 3, so that when I log in from a new device beyond this limit, my oldest session is automatically terminated.

**Why this priority**: Directly implements the core business constraint for Basic plan users, enhancing security and resource management.

**Independent Test**: Log in to 3 different devices as a Basic plan user. Then log in to a 4th device. Verify that the session on the 4th device is active and the session that was logged in first is now inactive (logged out).

**Acceptance Scenarios**:

1. **Given** a user is on a Basic plan with 3 active sessions, **When** the user logs into a 4th device, **Then** the oldest active session is automatically terminated and the 4th session becomes active.
2. **Given** a user is on a Basic plan with 2 active sessions, **When** the user logs into a 3rd device, **Then** the user has 3 active sessions and no session is terminated.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain session limit for Basic plan | `fact { all u: User | u.plan = Basic implies #u.sessions <= 3 }` | Telemetry on active session count per user |

### User Story 2 - Premium Plan Users Unaffected (Priority: P2)

As a Premium Plan user, I want my active sessions to not be restricted by the Basic plan limits.

**Why this priority**: Ensures that the new restriction does not negatively impact existing Premium users.

**Independent Test**: Log in as a Premium user on more than 3 devices. Verify that all sessions remain active.

**Acceptance Scenarios**:

1. **Given** a user is on a Premium plan with 3 active sessions, **When** the user logs into a 4th device, **Then** the user has 4 active sessions and none are terminated.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| No restriction for Premium plan | `fact { all u: User | u.plan = Premium implies no sessionLimit }` | Validate no sessions are terminated unexpectedly |

## Edge Cases

- What happens if the oldest session is currently performing a critical operation (e.g., in the middle of a purchase)? (Assumption: Force logout terminates session regardless of activity)
- What happens if the user logs in from the same device multiple times? (Assumption: Device/Session is unique per login event)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST track active sessions for every user.
- **FR-002**: System MUST identify the plan type for every user (Basic, Premium).
- **FR-003**: System MUST enforce a maximum of 3 concurrent active sessions for users on the Basic plan.
- **FR-004**: System MUST automatically identify the oldest active session for a Basic plan user upon a new login attempt when already at the limit.
- **FR-005**: System MUST terminate the oldest active session when a Basic plan user initiates a 4th session.

### Key Entities

- **User**: Represents the account owner, associated with a subscription plan.
- **Session**: Represents an active login event, associated with a User and a timestamp of initiation.
- **Plan**: Defines the constraints (Basic = limit 3, Premium = no limit).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Basic plan users never have more than 3 concurrent active sessions.
- **SC-002**: When a Basic plan user hits the 4th session, the session initiated earliest is terminated within 1 second.
- **SC-003**: 100% of login attempts that exceed the Basic plan limit result in the oldest session being terminated.

## Assumptions

- Basic plan users are defined as users with a specific "Basic" subscription level.
- Premium plan users are defined as users with a "Premium" subscription level.
- The system has access to a reliable way to track session initiation timestamps.
- "Force logout" means immediately invalidating the session token.

## Formal Requirements & Business KPI Mapping
```alloy
sig User {
  plan: one Plan,
  sessions: set Session
}
abstract sig Plan {}
one sig Basic extends Plan {}
one sig Premium extends Plan {}

sig Session {
  user: one User,
  initTime: one Int
}

fact {
  all u: User | u.plan = Basic implies #u.sessions <= 3
}

pred login[u: User, s: Session] {
  u.plan = Basic and #u.sessions = 3 implies {
    some oldest: u.sessions | oldest.initTime = min[u.sessions.initTime] and
    u.sessions' = (u.sessions - oldest) + s
  } else {
    u.sessions' = u.sessions + s
  }
}
```

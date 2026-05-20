# Feature Specification: Two-Factor Authentication

**Feature Branch**: `014-two-factor-authentication`  
**Created**: 19 May 2026  
**Status**: Draft  
**Input**: User description: "Implement two-factor authentication (2FA). A user login state should remain 'Pending' until the 2FA code matches the system's generated code."

## Clarifications

### Session 2026-05-19
- Q: Does the counter increment on every login attempt, or only after a successful 2FA code entry? → A: Option A - Increment after successful 2FA verification.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Secure Login with 2FA (Priority: P1)

As a registered user, I want to authenticate using a second factor after entering my initial credentials, so that my account is better protected from unauthorized access.

**Why this priority**: Core security requirement for the feature to function as intended.

**Independent Test**: Can be fully tested by logging in with valid credentials, providing the correct 2FA code, and observing the session status transition from 'Pending' to 'Authenticated'.

**Acceptance Scenarios**:

1. **Given** a user with valid initial credentials, **When** they submit credentials, **Then** the system prompts the user for the current counter value, and sets the login state to 'Pending'.
2. **Given** a login state of 'Pending', **When** the user submits the correct counter value, **Then** the login state transitions to 'Authenticated', the user's counter is incremented, and access is granted.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| *Ensure all sensitive logins are verified* | *fact { all s: Session | s.status = Authenticated implies s.twoFactorVerified }* | *Audit logs tracking 2FA completion* |

---

### User Story 2 - Handling Failed 2FA Attempts (Priority: P2)

As a user, I want the system to reject incorrect 2FA codes and maintain the 'Pending' state or lock the session, so that malicious actors cannot brute-force the 2FA code.

**Why this priority**: Critical security measure to prevent code guessing.

**Independent Test**: Can be tested by providing an incorrect counter value and verifying that the login state remains 'Pending' or session is terminated, and access is denied.

**Acceptance Scenarios**:

1. **Given** a login state of 'Pending', **When** the user submits an incorrect counter value, **Then** the system rejects the input and the login state remains 'Pending' (or transitions to a locked state).

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| *Prevent brute-force attacks* | *fact { all s: Session | s.status = Pending and s.failedAttempts > MAX_ATTEMPTS implies s.status = Locked }* | *Telemetry on 2FA failure rates* |

---

### Edge Cases

- What happens when a user forgets their counter value? (Need a recovery mechanism)
- How does system handle multiple simultaneous 2FA requests? (System should only honor the latest code or have a strict time window)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST initiate a 2FA challenge upon successful initial credential verification.
- **FR-002**: System MUST transition user login state to 'Pending' upon initial credential verification.
- **FR-003**: System MUST prompt the user for the current counter value.
- **FR-004**: System MUST validate the submitted input against the user's stored counter value.
- **FR-005**: System MUST ONLY transition login state to 'Authenticated' if the input matches.
- **FR-006**: System MUST increment the user's stored counter value ONLY after successful 2FA verification.
- **FR-007**: System MUST restrict access to resources until the login state is 'Authenticated'.

### Key Entities

- **User**: Represents the account holder, associated with a unique counter.
- **Session**: Represents the login instance, holding state ('Pending', 'Authenticated', 'Locked'), and metadata (attempts).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users with 2FA enabled have 0% unauthorized access via credential stuffing attacks.
- **SC-002**: Average time for a user to complete 2FA verification is under 30 seconds.
- **SC-003**: 99% of valid 2FA code submissions result in successful 'Authenticated' state transition.

## Assumptions

- User has access to their remembered counter value.
- Initial credential authentication mechanism is already in place.
- The system has a secure way to store user counter values.

## Formal Requirements & Business KPI Mapping

```alloy
sig User {
    var counter: one Int
}

enum Status { Pending, Authenticated, Locked }

sig Session {
    user: one User,
    var status: one Status,
    var failedAttempts: one Int
}

// Ensure counter is non-negative
fact { all u: User | u.counter >= 0 }

// Transition rule: Authenticate requires correct counter value
pred attemptAuth[s: Session, input: Int] {
    s.status = Pending
    input = s.user.counter
    s.status' = Authenticated
    s.user.counter' = s.user.counter + 1
    s.failedAttempts' = 0
}

// Transition rule: Incorrect attempt
pred incorrectAuth[s: Session, input: Int] {
    s.status = Pending
    input != s.user.counter
    s.failedAttempts' = s.failedAttempts + 1
    // Logic for locking session
    (s.failedAttempts' > 3) implies s.status' = Locked else s.status' = Pending
}

// Invariant: Authenticated sessions must have verified the counter
fact { all s: Session | s.status = Authenticated implies s.failedAttempts = 0 }
```
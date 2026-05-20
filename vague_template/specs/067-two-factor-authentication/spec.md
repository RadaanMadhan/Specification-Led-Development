# Feature Specification: Two-Factor Authentication (2FA)

**Feature Branch**: `067-two-factor-authentication`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Implement two-factor authentication (2FA). A user login state should remain 'Pending' until the 2FA code matches the system's generated code."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Secure Login with 2FA (Priority: P1)

As a registered user, I want to authenticate with a second factor after providing my credentials so that my account is better protected against unauthorized access.

**Why this priority**: Core functionality of the feature.

**Independent Test**: Can be tested by attempting to log in, verifying the Pending state, providing the correct 2FA code, and observing the Active state and successful login.

**Acceptance Scenarios**:

1. **Given** a user has entered correct initial credentials, **When** the 2FA prompt is presented, **Then** the system updates the login state to 'Pending' and sends a 2FA code.
2. **Given** a login state of 'Pending', **When** the user provides the correct 2FA code, **Then** the login state transitions to 'Active' and access is granted.
3. **Given** a login state of 'Pending', **When** the user provides an incorrect 2FA code, **Then** the login state remains 'Pending' and access is denied.

---

### User Story 2 - Failed 2FA Attempts (Priority: P2)

As a security-conscious user, I want my account to be protected against brute-force 2FA attempts.

**Why this priority**: Essential security measure.

**Independent Test**: Can be tested by attempting to provide incorrect 2FA codes repeatedly and observing when the user is locked out.

**Acceptance Scenarios**:

1. **Given** a login state of 'Pending', **When** the user provides an incorrect 2FA code multiple times, **Then** the system denies further attempts and notifies the user.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST support a 2FA verification step during the login process.
- **FR-002**: Upon successful validation of initial credentials, System MUST set the user login state to 'Pending'.
- **FR-003**: System MUST generate a unique, time-limited 2FA code for the user.
- **FR-004**: System MUST validate the 2FA code provided by the user.
- **FR-005**: System MUST only grant 'Active' access upon successful 2FA validation.
- **FR-006**: System MUST maintain the 'Pending' login state for invalid 2FA attempts.

### Key Entities

- **UserLoginState**: Represents the state of the user's login process ('Initial', 'Pending', 'Active').
- **2FACode**: Represents the generated 2FA challenge, with attributes like 'Code', 'ExpiryTime', 'AssociatedUser'.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of logins with 2FA enabled successfully transition to 'Active' state only after correct 2FA code entry.
- **SC-002**: 0% of users can bypass the 2FA requirement to reach 'Active' state.
- **SC-003**: Unauthorized access attempts with incorrect 2FA codes are rejected in under 1 second.

## Assumptions

- The 2FA code delivery infrastructure (SMS/Email/App) is external and managed by the platform.
- User accounts have 2FA enabled as a prerequisite for this flow.

## Formal Requirements & Business KPI Mapping
```alloy
open util/ordering[Time] as to

sig Time {}

enum LoginState { Initial, Pending, Active }

sig User {
    var state: LoginState -> Time
}

sig Code {
    user: one User,
    secret: Int
}

// Initial state: User is Initial
fact init {
    all u: User | u.state.first = Initial
}

// Transition: Initial -> Pending
pred request2FA[u: User, t, t': Time] {
    u.state.t = Initial
    u.state.t' = Pending
    // 2FA code generation (simplified)
    some c: Code | c.user = u
}

// Transition: Pending -> Active (Success)
pred validate2FA[u: User, c: Code, t, t': Time] {
    u.state.t = Pending
    c.user = u
    // Correct code validation
    u.state.t' = Active
}

// Transition: Pending -> Pending (Failure)
pred fail2FA[u: User, c: Code, t, t': Time] {
    u.state.t = Pending
    c.user = u
    u.state.t' = Pending
}

// Scenario: Successful Login
run {
    some u: User, c: Code, t1, t2: Time |
        request2FA[u, to/prev[t1], t1] and
        validate2FA[u, c, t1, t2]
} for 3 but 2 Time
```

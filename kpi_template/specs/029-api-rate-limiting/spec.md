# Feature Specification: API Rate Limiting

**Feature Branch**: `api-rate-limiting`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Create a rate-limiting algorithm for an API. Users get 100 requests per minute. If they exceed it, their token is suspended for 5 minutes, but webhooks should still process."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Rate Limiting Enforcement (Priority: P1)

As an API consumer, I expect the system to limit my request rate so that API availability is maintained.

**Why this priority**: Core requirement to prevent API abuse.

**Independent Test**: Send 101 requests in under 60 seconds; verify that the 101st request is rejected.

**Acceptance Scenarios**:

1. **Given** a user has a valid API token, **When** they make 100 requests in 60 seconds, **Then** all requests are processed successfully.
2. **Given** a user has a valid API token, **When** they make 101 requests in 60 seconds, **Then** the 101st request is rejected.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain API availability | fact { all t: Token | t.reqCount <= 100 } | Telemetry on rate limit errors |

---

### User Story 2 - Token Suspension (Priority: P1)

As a system operator, I need to suspend tokens that violate rate limits to ensure stability.

**Why this priority**: Essential for enforcing the rate limit policy.

**Independent Test**: Violate the rate limit; verify the token is rejected for all requests for 5 minutes.

**Acceptance Scenarios**:

1. **Given** a token is suspended, **When** the user sends any request, **Then** the request is rejected.
2. **Given** a token is suspended for 4 minutes, **When** the user sends a request, **Then** the request is rejected.
3. **Given** a token is suspended for 5 minutes, **When** the user sends a request, **Then** the request is accepted (assuming it doesn't immediately exceed the new limit).

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Enforce suspension policy | fact { t.suspended implies t.status = 'rejected' } | Token status logs |

---

### User Story 3 - Webhook Exemption (Priority: P1)

As an integration user, I need webhooks to function even if my API token is suspended, so my automation doesn't break.

**Why this priority**: Ensures critical webhook delivery for integrations.

**Independent Test**: Suspend an API token; verify that webhook requests still succeed.

**Acceptance Scenarios**:

1. **Given** a token is suspended, **When** a webhook request is sent, **Then** the request is accepted.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure webhook delivery | fact { all w: Webhook | w.status = 'accepted' } | Webhook success rate |

---

### Edge Cases

- What happens when a user attempts to use a token just as the 5-minute suspension expires?
- How does the system handle concurrent requests that bring the count from 99 to 101?
- What is the behavior for requests made *during* the suspension period?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST limit API requests to 100 per minute per token.
- **FR-002**: System MUST suspend tokens for 5 minutes if the rate limit is exceeded.
- **FR-003**: System MUST reject all standard API requests using a suspended token.
- **FR-004**: System MUST allow all requests identified as webhooks, regardless of the token's suspension status.

### Key Entities

- **Token**: Authentication credential used to access the API.
- **Request**: Action performed by a user against the API.
- **Webhook**: Integration event originating from a trusted external source.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Rate limit violations are blocked within 100ms of detection.
- **SC-002**: Suspended tokens remain blocked for exactly 300 seconds.
- **SC-003**: 100% of designated webhook requests are processed even during token suspension.
- **SC-004**: Users receive a clear, documented error response when a request is blocked due to rate limiting or suspension.

## Assumptions

- "Token" refers to an API authentication credential provided by the user.
- "Webhook" refers to requests identified by the system as originating from trusted external integration events.
- "Suspension" implies rejecting standard API requests (e.g., returning HTTP 429).
- The system has a reliable way to differentiate between standard API requests and webhooks.

## Formal Requirements & Business KPI Mapping
```alloy
abstract sig Bool {}
one sig True, False extends Bool {}

abstract sig Status {}
one sig Active, Suspended extends Status {}

sig Token {
    status: one Status,
    reqCount: Int
}

enum RequestType { Standard, Webhook }

sig Request {
    token: one Token,
    type: one RequestType,
    isAccepted: one Bool
}

fact {
    // Rate Limit Constraint: A token can only have <= 100 requests if Active
    all t: Token | t.status = Active implies t.reqCount <= 100

    // Webhook Exemption: Webhooks are always accepted
    all r: Request | r.type = Webhook implies r.isAccepted = True

    // Suspension Rule: Suspended tokens cannot make Standard requests
    all r: Request | r.token.status = Suspended and r.type = Standard implies r.isAccepted = False
}

// Verification assertion
assert WebhooksAlwaysProcessed {
    all r: Request | r.type = Webhook implies r.isAccepted = True
}
check WebhooksAlwaysProcessed for 5
```
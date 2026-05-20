# Feature Specification: API Rate Limiting

**Feature Branch**: `079-api-rate-limiting`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Users get 100 requests per minute. If they exceed it, their token is suspended for 5 minutes, but webhooks should still process."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Normal API Usage (Priority: P1)

As an API user, I want to make API requests within my allotted quota, so that my integrations continue to function smoothly.

**Why this priority**: Core functionality of the API.

**Independent Test**: Verify that a user can make up to 100 requests in a 1-minute window without any disruption.

**Acceptance Scenarios**:

1. **Given** a user with a valid token, **When** they make 100 requests in under 60 seconds, **Then** all requests are processed successfully.

---

### User Story 2 - Token Suspension (Priority: P1)

As an API user, I want to be notified if I exceed my request limit, so that I understand why my requests are being denied.

**Why this priority**: Essential for maintaining API stability and user feedback.

**Independent Test**: Verify that the 101st request within a 1-minute window triggers a suspension.

**Acceptance Scenarios**:

1. **Given** a user has reached their 100-request limit, **When** they make a 101st request, **Then** the request is rejected with a "Rate limit exceeded - Token suspended" message.
2. **Given** a token is suspended, **When** 5 minutes have elapsed, **Then** the token is reactivated and requests are allowed again.

---

### User Story 3 - Webhook Reliability (Priority: P2)

As a webhook consumer, I want to ensure that my webhooks are delivered regardless of the status of my API token, so that critical data events are never missed.

**Why this priority**: Business continuity requirement.

**Independent Test**: Verify webhook delivery while an API token is suspended.

**Acceptance Scenarios**:

1. **Given** a user token is currently suspended due to rate limiting, **When** a system event occurs, **Then** the corresponding webhook is still successfully delivered to the user's endpoint.

---

### Edge Cases

- What happens when a request is made exactly at the 60-second boundary?
- How does the system handle concurrent requests just as the limit is being reached?
- What happens if the suspension service is temporarily unavailable?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST track request counts per unique API token.
- **FR-002**: System MUST enforce a rate limit of 100 requests per rolling 60-second window.
- **FR-003**: System MUST suspend an API token for 5 minutes immediately upon exceeding the rate limit.
- **FR-004**: System MUST reject all API requests made with a suspended token.
- **FR-005**: System MUST ensure webhook delivery is independent of the API request rate-limiting and suspension state.

### Key Entities

- **API Token**: Represents the credential used for API authentication.
- **Rate Limit Counter**: Stores the number of requests made by a specific token in the current window.
- **Suspension Status**: Represents whether an API token is currently suspended and when the suspension expires.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: API correctly rejects the 101st request within a 60-second window for a given token.
- **SC-002**: Suspended tokens are automatically reactivated after 5 minutes of suspension.
- **SC-003**: 100% of webhook events are delivered successfully during an API token suspension.
- **SC-004**: System latency added by the rate-limiting check is negligible (under 10ms per request).

## Assumptions

- API tokens are unique per user/application.
- The 5-minute suspension is a fixed duration.
- Webhooks are handled by a separate system component that does not share the same rate-limiting pool as the API.

## Formal Requirements & Business KPI Mapping

```alloy
sig Token {
    var requestCount: Int,
    var isSuspended: Bool,
    var suspensionTime: Int // Minutes remaining
}

abstract sig Bool {}
one sig True, False extends Bool {}

// Rate limit definition
const MaxRequests = 100
const WindowDuration = 1 // 1 minute
const SuspensionDuration = 5 // 5 minutes

pred canMakeRequest(t: Token) {
    t.isSuspended = False
}

pred handleRequest(t: Token) {
    canMakeRequest[t]
    t.requestCount < MaxRequests
    t.requestCount' = t.requestCount + 1
}

pred triggerSuspension(t: Token) {
    t.requestCount >= MaxRequests
    t.isSuspended' = True
    t.suspensionTime' = SuspensionDuration
}

// Webhooks remain independent
pred sendWebhook(t: Token) {
    // Webhook delivery does not depend on t.isSuspended
    some e: Event | deliver[e]
}

abstract sig Event {}
pred deliver(e: Event) { /* ... */ }
```

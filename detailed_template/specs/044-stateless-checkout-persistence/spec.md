# Feature Specification: Stateless Checkout Persistence

**Feature Branch**: `041-stateless-checkout-persistence`
**Created**: 2026-05-19
**Status**: Draft
**Input**: User description: "Every API endpoint must be completely stateless. However, the /checkout endpoint needs to remember the exact items in the user's cart from their abandoned session yesterday."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Retrieve Abandoned Cart (Priority: P1)

As a returning user, I want my cart from my previous session to be automatically available when I access the checkout endpoint, so I can resume my purchase without re-adding items.

**Why this priority**: Directly addresses the core requirement of resuming abandoned checkouts.

**Independent Test**: Can be tested by adding items to a cart, abandoning the session (e.g., closing browser/token expiry), and then accessing the checkout endpoint with the same user credentials, verifying the items are present.

**Acceptance Scenarios**:

1. **Given** a user has items in their cart, **When** the user closes the session and returns the next day, **Then** the `/checkout` endpoint displays the exact same items from the previous session.
2. **Given** an empty cart from a previous session, **When** the user accesses the `/checkout` endpoint, **Then** the cart remains empty.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| *Reduce cart abandonment rate* | *fact { all u: User | u.cart = u.last_cart_state }* | *Cart recovery rate telemetry* |

---

### User Story 2 - Stateless API Interaction (Priority: P2)

As a system architect, I want all API interactions to be stateless, so that the infrastructure can scale horizontally without session affinity.

**Why this priority**: Essential to comply with the architectural constraint of the project.

**Independent Test**: Can be tested by making consecutive requests to `/checkout` using different instances or load-balanced requests, verifying that the cart state is consistently retrieved from a backend store rather than local server memory.

**Acceptance Scenarios**:

1. **Given** a stateless API architecture, **When** a user makes multiple requests to `/checkout` across different instances, **Then** the cart state is consistent and correctly retrieved from the persistent store.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| *Maintain stateless scaling* | *fact { all req: Request | no req.session_memory }* | *Infrastructure load balancing metrics* |

---

### Edge Cases

- What happens when a user attempts to retrieve an abandoned cart after an extended period (e.g., 30 days) where business rules might dictate it should be cleared?
- How does the system handle concurrent cart modifications if the user has multiple sessions open?
- How is the system behavior defined if the persistent store is temporarily unavailable?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The `/checkout` API endpoint MUST be completely stateless, relying on persistent storage to retrieve cart state.
- **FR-002**: The system MUST persist cart state across user sessions.
- **FR-003**: The system MUST uniquely identify users/carts to retrieve the correct abandoned cart items.
- **FR-004**: The system MUST ensure the cart state is consistent across different API requests, regardless of the instance handling the request.

### Key Entities

- **Cart**: Represents a collection of items associated with a user, persisted independently of the API session.
- **User**: The actor to whom the Cart is associated.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of returning users have their cart state accurately restored to the state of their last active session.
- **SC-002**: API response time for cart retrieval at `/checkout` remains under 300ms.
- **SC-003**: The system successfully handles concurrent cart operations across multiple horizontally scaled API instances without state conflicts.

## Assumptions

- User identity is reliably available in the request (e.g., via a secure token).
- A persistent data store is available for cart state management.
- Cart state retrieval does not require server-side session memory.

## Formal Requirements & Business KPI Mapping
```alloy
sig Item {}
sig Cart { items: set Item }
sig User { cart: one Cart }

// Represent the persistent store
one sig PersistentStore {
    data: User -> one Cart
}

// Statelessness constraint: Requests do not hold session state
sig Request {
    user: one User
}

// The checkout action fetches from the store, not from session memory
pred checkout[r: Request, c: Cart] {
    c = PersistentStore.data[r.user]
}

// Integrity: The user's cart is always what is in the persistent store
fact ConsistentState {
    all u: User | u.cart = PersistentStore.data[u]
}

run {} for 3
```
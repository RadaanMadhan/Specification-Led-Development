# Feature Specification: Stateless Cart Persistence

**Feature Branch**: `stateless-cart-persistence`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Every API endpoint must be completely stateless. However, the /checkout endpoint needs to remember the exact items in the user's cart from their abandoned session yesterday."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resume Cart for Checkout (Priority: P1)

As a returning customer, I want to see the items I had in my cart during my previous session so that I can proceed to checkout without manually re-adding them.

**Why this priority**: Directly addresses user frustration and prevents lost sales from abandoned carts.

**Independent Test**: Add items to cart, log out/close session, log in the next day, and verify items are present in the cart upon checkout.

**Acceptance Scenarios**:

1. **Given** a user has items in their cart, **When** the user logs out or ends the session, **Then** the cart items are persisted in the user's account profile.
2. **Given** a user has a saved cart from a previous session, **When** the user accesses the `/checkout` endpoint, **Then** the system retrieves and displays the items from the persisted cart.

---

### User Story 2 - Maintain Stateless API Architecture (Priority: P1)

As a system architect, I want to ensure that all API endpoints, including `/checkout`, remain completely stateless so that the system can scale horizontally and handle requests without relying on local server state.

**Why this priority**: Essential to maintain the core system architecture constraint.

**Independent Test**: Perform consecutive requests to `/checkout` from different client instances without session cookies, and verify the system correctly identifies and loads the persistent cart for each request based on the provided user identity token.

**Acceptance Scenarios**:

1. **Given** an API request to `/checkout` without an active session cookie, **When** the request includes a valid user identity token, **Then** the API correctly processes the checkout using the persisted cart data without relying on server-side session state.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST persist cart items associated with a user identity independently of the session lifecycle.
- **FR-002**: API endpoints MUST operate in a stateless manner, relying on user identity tokens rather than server-side session state.
- **FR-003**: The `/checkout` endpoint MUST retrieve persisted cart items upon receipt of a valid request from an authenticated user.
- **FR-004**: Cart state MUST be updated immediately upon any change (add/remove) to ensure persistence.

### Key Entities

- **Cart**: Represents the collection of items selected by a user.
- **User Identity Token**: Represents the authenticated user, used to retrieve associated cart data.
- **Cart Item**: Represents a specific product and quantity added to the cart.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: User cart abandonment rate for returning customers decreases by 15%.
- **SC-002**: Returning customers complete checkout in under 2 minutes.
- **SC-003**: API response time for `/checkout` remains under 300ms, regardless of cart size.
- **SC-004**: 100% of API endpoints successfully operate without utilizing server-side session storage (validated by load balancing tests).

## Assumptions

- Users are required to be authenticated for their cart to be persisted across sessions.
- Cart persistence is limited to authenticated user accounts.
- The existing authentication system provides a reliable user identity token.

## Formal Requirements & Business KPI Mapping

```alloy
sig User {}
sig Item {}
sig Token {
    user: one User
}

sig Cart {
    owner: one User,
    items: set Item
}

-- Constraint: Cart is tied to User, not Session
fact CartOwnership {
    all c: Cart | one u: User | c.owner = u
}

-- Stateless API: Checkout depends on Token/User, not Session
pred canAccessCart[t: Token, c: Cart] {
    t.user = c.owner
}

-- Verify that a user can always access their cart via a valid token
assert PersistenceWorks {
    all u: User, c: Cart | c.owner = u implies (some t: Token | t.user = u and canAccessCart[t, c])
}

check PersistenceWorks for 5
```

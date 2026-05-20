# Feature Specification: Age-Restricted Content Gate

**Feature Branch**: `007-age-gate-content`
**Created**: 2026-05-19
**Status**: Draft
**Input**: User description: "Implement an age gate: users under 18 cannot view age-restricted content flags."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Block Restricted Content for Minors (Priority: P1)

A user who is under 18 years old logs into the system. When they navigate to or search for content that is marked as "age-restricted", the system should prevent them from viewing or accessing that content.

**Why this priority**: Protecting minors from inappropriate content is a critical compliance and safety requirement.

**Independent Test**: Create a test user with birthdate 17 years ago. Verify that accessing content flagged as age-restricted results in an "Access Denied" or "Content Unavailable" response.

**Acceptance Scenarios**:

1. **Given** a user is logged in with age < 18, **When** they request age-restricted content, **Then** the system denies access.
2. **Given** a user is logged in with age >= 18, **When** they request age-restricted content, **Then** the system allows access.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure compliance with minor safety regulations | `fact { all u: User | u.age < 18 implies no Content.restricted in u.accessibleContent }` | Telemetry on unauthorized access attempts by age < 18 |

---

### Edge Cases

- What happens when a user's date of birth is not set or invalid?
- How does the system handle content whose restriction status changes dynamically?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST store the Date of Birth (DOB) for every user.
- **FR-002**: System MUST calculate the current age of a user based on their DOB and the current date.
- **FR-003**: System MUST identify content as "age-restricted" or "not restricted".
- **FR-004**: System MUST prevent users under 18 from viewing content marked as "age-restricted".

### Key Entities

- **User**: Represents a registered user. Key attribute: Date of Birth (DOB).
- **Content**: Represents content in the system. Key attribute: Age-Restriction Status (Flag).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of users under 18 are prevented from accessing content flagged as restricted.
- **SC-002**: Users 18 and older have full access to all content as permitted by their account level.
- **SC-003**: Age calculation logic is verified to be accurate, accounting for leap years and timezones.

## Assumptions

- Users are required to provide a valid Date of Birth upon account creation.
- The content management system can distinguish between age-restricted and non-restricted content.
- The system has access to a reliable, synchronized clock for age verification.

## Formal Requirements & Business KPI Mapping
```alloy
sig User {
  dob: One Date,
  age: One Int
}

sig Content {
  restricted: One Bool
}

pred accessAllowed(u: User, c: Content) {
  u.age >= 18 or c.restricted = False
}

assert NoMinorsAccessRestricted {
  all u: User, c: Content | u.age < 18 and c.restricted = True implies not accessAllowed[u, c]
}
check NoMinorsAccessRestricted for 5
```

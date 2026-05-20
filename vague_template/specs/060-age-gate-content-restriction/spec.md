# Feature Specification: Age Gate: Content Restriction

**Feature Branch**: `060-age-gate-content-restriction`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Implement an age gate: users under 18 cannot view age-restricted content flags."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Block Underage Access (Priority: P1)

A user who is under 18 attempts to view content that has been flagged as age-restricted. The system prevents them from accessing the content and clearly communicates the reason for the restriction.

**Why this priority**: This is the core functionality of the age gate, ensuring legal compliance and protecting minors from inappropriate content. Without this, the feature fails its primary purpose.

**Independent Test**: Can be fully tested by attempting to access age-restricted content with a user profile indicating an age under 18 and verifying that access is denied and an appropriate message is displayed.

**Acceptance Scenarios**:

1.  **Given** a user is logged in and their registered age is 16, **When** they attempt to view a piece of content marked as "age-restricted", **Then** access is denied, and a message "This content is age-restricted and requires users to be 18 or older." is displayed.
2.  **Given** a user is logged in and their registered age is 16, **When** they try to navigate directly to the URL of age-restricted content, **Then** access is denied, and the age restriction message is displayed instead of the content.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure 100% compliance with age restrictions | fact { all u: User, c: Content | c.is_age_restricted and u.age < 18 implies not (u in c.viewers) } | Automated testing of restricted content access attempts |

---

### User Story 2 - Grant Age-Appropriate Access (Priority: P1)

A user who is 18 or over attempts to view content that has been flagged as age-restricted. The system allows them to view the content without any additional steps or interruptions.

**Why this priority**: This is equally critical to ensure that eligible users have a smooth experience and are not unduly penalized by the age gate mechanism.

**Independent Test**: Can be fully tested by attempting to access age-restricted content with a user profile indicating an age of 18 or over and verifying that access is granted immediately.

**Acceptance Scenarios**:

1.  **Given** a user is logged in and their registered age is 25, **When** they attempt to view a piece of content marked as "age-restricted", **Then** the content is displayed immediately without any age-related prompts or blocks.
2.  **Given** a user is logged in and their registered age is 18, **When** they try to navigate directly to the URL of age-restricted content, **Then** the content is displayed immediately.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain seamless experience for eligible users | fact { all u: User, c: Content | c.is_age_restricted and u.age >= 18 implies (u in c.viewers) } | User journey monitoring for eligible users accessing restricted content |
---

### User Story 3 - Invalid Age Input Handling (Priority: P2)

A user attempts to input an invalid age (e.g., non-numeric, logically impossible date). The system should detect this invalid input and provide feedback, prompting the user for correct information.

**Why this priority**: While not as critical as blocking access, robust input validation is important for data integrity and a positive user experience, preventing errors down the line.

**Independent Test**: Can be tested by providing various forms of invalid age input (e.g., text, future dates, very old dates) during age verification and confirming the system rejects them with appropriate messages.

**Acceptance Scenarios**:

1.  **Given** a user is prompted to enter their age, **When** they enter "twenty", **Then** the system displays an error message "Please enter a valid numeric age."
2.  **Given** a user is prompted to enter their date of birth, **When** they enter a date that would make them 1 year old, **Then** the system displays an error message "Please enter a valid date of birth."

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure data integrity for user age information | pred { check_age_input[age: int] } | Input validation during user age entry/update |

---

### Edge Cases

-   What happens if content is incorrectly flagged as age-restricted or not age-restricted?
-   How does the system handle a user whose age data is missing or corrupted?
What are the implications for users in regions with different legal age limits for content? The age restriction of 18 is globally fixed and not configurable per region.

## Requirements *(mandatory)*

### Functional Requirements

-   **FR-001**: The system MUST determine the age of the user.
-   **FR-002**: The system MUST identify content flagged as age-restricted.
-   **FR-003**: If a user's age is determined to be under 18, they MUST NOT be able to view age-restricted content.
-   **FR-004**: If a user's age is determined to be 18 or over, they MUST be able to view age-restricted content.
-   **FR-005**: When a user under 18 attempts to view age-restricted content, the system MUST display a message explaining that the content is age-restricted and they do not meet the age requirement.
-   **FR-006**: The system MUST prevent users from bypassing the age gate through direct URLs, API calls, or other technical means.
-   **FR-007**: The system MUST securely store and retrieve user age information.
-   **FR-008**: The system MUST provide a mechanism for content creators/administrators to mark content as age-restricted.
-   **FR-009**: The system MUST allow for users to update their age information if it was initially entered incorrectly or they have since come of age.
-   **FR-010**: The system MUST determine user age via a self-declared input during registration or profile update.
-   **FR-011**: If user age cannot be determined, the system MUST default to restricting access to age-gated content.

### Key Entities *(include if feature involves data)*

-   **User**: Represents an individual interacting with the system. Key attributes include `age` (integer, derived from date of birth) and `is_authenticated` (boolean).
-   **Content**: Represents any item that can be viewed by a user. Key attributes include `id` (unique identifier) and `is_age_restricted` (boolean).

## Success Criteria *(mandatory)*

### Measurable Outcomes

-   **SC-001**: 100% of access attempts by users identified as under 18 to content flagged as age-restricted are successfully blocked, as verified by system logs.
-   **SC-002**: 100% of access attempts by users identified as 18 or over to content flagged as age-restricted are successfully granted, without artificial delays or blocks.
-   **SC-003**: The age gate mechanism does not add more than 500ms of average latency to content loading times for eligible users.
-   **SC-004**: User-reported incidents or support tickets related to age gate errors or confusion (e.g., incorrect blocking, access issues) are less than 0.5% of total daily active users interacting with age-gated content.

## Assumptions

-   User authentication and identification processes are already established or will be implemented as a prerequisite.
-   A robust content management system (CMS) or similar mechanism exists or will be developed to allow for flagging content as age-restricted.
-   The default age restriction is 18 years old unless specified otherwise for specific regions or content types.
-   User age will be derived from a stored Date of Birth (DOB) or directly provided age.
-   Age verification will occur at the point of access to age-restricted content.

## Formal Requirements & Business KPI Mapping

```alloy
// Define the User and Content entities
sig User {
    age: one Int,
    is_authenticated: one Bool
}

sig Content {
    id: one Int,
    is_age_restricted: one Bool
}

// User Story 1: Block Underage Access
fact { all u: User, c: Content | c.is_age_restricted and u.age < 18 implies not (u in c.viewers) }

// User Story 2: Grant Age-Appropriate Access
fact { all u: User, c: Content | c.is_age_restricted and u.age >= 18 implies (u in c.viewers) }

// User Story 3: Invalid Age Input Handling
pred check_age_input[age_input: Int] {
    age_input >= 0 and age_input < 150 // Assuming a reasonable age range
}
```

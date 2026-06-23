# Feature Specification: Netflix Content Delivery & Access Control

**Feature Branch**: `003-netflix-content-delivery`
**Created**: 2026-05-14
**Status**: Draft
**Input**: User description: "A content streaming platform with subscription-based access control, content catalogue management, and viewing history tracking."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Stream Content (Priority: P1)

An authenticated subscriber selects a title from the catalogue and begins streaming. The system checks their subscription tier, verifies the content is available in their region, and starts playback. A viewing-history entry is recorded.

**Acceptance Scenarios**:

1. **Given** a user has an active Premium subscription, **When** they request to stream a title available in their region, **Then** playback begins and a viewing-history entry is created.
2. **Given** a user has an expired subscription, **When** they request to stream any title, **Then** a 403 Forbidden response is returned and no viewing-history entry is created.
3. **Given** a user has a Basic subscription, **When** they request to stream a title restricted to Premium, **Then** a 403 response with an upgrade prompt is returned.

---

### User Story 2 - Browse Catalogue (Priority: P1)

An authenticated user browses the content catalogue, filtered by genre, region availability, and their subscription tier. Only content they are entitled to see appears in results.

**Acceptance Scenarios**:

1. **Given** a user with a Basic subscription in region US, **When** they GET /catalogue, **Then** only titles available in US for Basic tier are returned.
2. **Given** a user with no auth token, **When** they GET /catalogue, **Then** a 401 Unauthorized response is returned.

---

### User Story 3 - Manage Catalogue (Priority: P2)

An admin user adds, updates, or removes titles from the content catalogue. Every catalogue mutation is recorded in an audit log.

**Acceptance Scenarios**:

1. **Given** an admin user, **When** they POST /catalogue with a new title, **Then** the title is created and an audit entry is recorded.
2. **Given** a subscriber user, **When** they POST /catalogue, **Then** a 403 Forbidden response is returned and no title is created.

---

### User Story 4 - View History (Priority: P2)

A subscriber views their own viewing history. Subscribers cannot see other users' history. Admins can view any user's history for support purposes.

**Acceptance Scenarios**:

1. **Given** a subscriber, **When** they GET /users/{id}/history where id is their own, **Then** their viewing history is returned.
2. **Given** a subscriber, **When** they GET /users/{id}/history where id is another user, **Then** a 404 response is returned (not 403, to avoid leaking user existence).

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST require valid authentication on every request to all API endpoints. Requests without valid authentication MUST be rejected with 401 before any authorization or business logic runs.
- **FR-002**: System MUST associate every authenticated caller with exactly one role from the set {subscriber, content_admin, support_admin}.
- **FR-003**: System MUST enforce subscription-tier gating: a subscriber may stream a title only if their active subscription tier is equal to or higher than the title's required tier.
- **FR-004**: System MUST enforce region gating: a subscriber may stream or browse only titles whose region availability includes the subscriber's registered region.
- **FR-005**: System MUST allow a caller with role content_admin to create, update, and remove catalogue titles. Subscribers and support_admins MUST NOT be able to mutate the catalogue.
- **FR-006**: System MUST allow a caller with role subscriber to view their own viewing history. A subscriber MUST NOT be able to view another user's history.
- **FR-007**: System MUST allow a caller with role support_admin to read any user's viewing history and to read the audit log. support_admins MUST NOT be able to mutate the catalogue.
- **FR-008**: Every successful catalogue mutation (create, update, delete) MUST produce exactly one AuditEntry linked to that mutation. No mutation may produce zero or more than one AuditEntry.
- **FR-009**: AuditEntries MUST be append-only. The system MUST NOT expose any operation that updates or deletes an existing AuditEntry through any role, including content_admin.
- **FR-010**: Each AuditEntry MUST capture: the mutation type (create/update/delete), the title affected, the identity of the admin who performed the mutation, and the timestamp.
- **FR-011**: Every successful stream request MUST produce exactly one ViewingHistory entry linked to the subscriber and the title. No stream request may produce zero or more than one entry.
- **FR-012**: System MUST reject stream requests for titles that do not exist with a 404 response. No ViewingHistory entry MUST be created for a rejected request.
- **FR-013**: For a subscriber caller, GET /users/{id}/history for a user other than themselves MUST return 404 (not 403) to avoid leaking the existence of other users.
- **FR-014**: System MUST expose exactly the following endpoints: GET /catalogue, POST /catalogue, PUT /catalogue/{id}, DELETE /catalogue/{id}, POST /stream/{titleId}, GET /users/{id}/history, GET /audit. No additional endpoint may bypass the permission or audit invariants above.

### Key Entities

- **User**: A platform user with an identity, role, subscription tier, and region.
- **Title**: A content item in the catalogue with a name, genre, required tier, and region availability.
- **ViewingHistory**: A record of a subscriber streaming a specific title at a specific time.
- **AuditEntry**: An append-only record of a catalogue mutation performed by an admin.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All endpoints return 401 when called without a valid token.
- **SC-002**: Subscribers cannot stream content above their subscription tier.
- **SC-003**: Subscribers cannot access content outside their registered region.
- **SC-004**: Every catalogue mutation produces exactly one audit entry.
- **SC-005**: Subscribers cannot view other users' viewing history, and the response does not leak user existence.

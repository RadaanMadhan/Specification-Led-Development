# Feature Specification: Feature Request Voting

**Feature Branch**: `feature-request-voting`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Users can vote on feature requests. A user can only vote once per feature. If a feature gets 100 votes, it is locked. Users can change their vote after a feature is locked."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Cast a Vote on a Feature (Priority: P1)

As a registered user, I want to vote for feature requests that I support, so that I can influence the development roadmap.

**Why this priority**: Core functionality that provides immediate value.

**Independent Test**: Verify that a user can successfully cast a single vote for a feature and the vote count increments.

**Acceptance Scenarios**:

1. **Given** a feature request with less than 100 votes, **When** a user votes for the feature, **Then** the vote is recorded and the vote count increments.
2. **Given** a user has already voted for a feature, **When** the user attempts to vote again, **Then** the system prevents the second vote.

---

### User Story 2 - Feature Lock at 100 Votes (Priority: P2)

As a product manager, I want feature requests to be locked for new voting when they reach 100 votes, so that we can prioritize those items for development.

**Why this priority**: Essential for managing the voting process and ensuring clear thresholds for development.

**Independent Test**: Verify that voting for a feature is disabled once the vote count reaches 100.

**Acceptance Scenarios**:

1. **Given** a feature request with 99 votes, **When** a user casts a new vote, **Then** the feature is recorded with 100 votes and status is set to 'locked'.
2. **Given** a feature request with 100 votes (locked), **When** a new user attempts to vote, **Then** the system prevents the vote and informs the user that the feature is locked.

---

### User Story 3 - Change Vote After Lock (Priority: P3)

As a user, I want to change my existing vote on a locked feature, so that I can update my preferences if my opinion changes.

**Why this priority**: Provides flexibility for users even after the threshold is reached.

**Independent Test**: Verify that a user who already voted can change their vote on a locked feature.

**Acceptance Scenarios**:

1. **Given** a locked feature request, **When** a user who previously voted on it attempts to change their vote, **Then** the system allows the vote change and updates the record (vote count remains 100).
2. **Given** a locked feature request, **When** a user who *did not* previously vote attempts to vote, **Then** the system prevents the new vote.

---

### Edge Cases

- What happens if 100 votes are reached exactly when two users vote simultaneously? (System should handle concurrency and correctly set to 100/locked).
- How does the system handle a user attempting to change their vote from "upvote" to "none"? (System should allow removing the vote, decrementing the count below 100, and potentially unlocking the feature).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST record votes cast by registered users.
- **FR-002**: System MUST enforce a limit of one vote per user per feature request.
- **FR-003**: System MUST automatically lock a feature request for *new* votes when it reaches 100 votes.
- **FR-004**: System MUST allow users who have already voted on a locked feature to change their vote.

### Key Entities

- **Feature Request**: Represents a proposed feature, tracks total votes and current status (open/locked).
- **Vote**: Represents an association between a User and a Feature Request.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can cast or change a vote in under 2 seconds.
- **SC-002**: Feature status accurately reflects 'locked' state immediately upon reaching 100 votes.
- **SC-003**: 100% of attempts to cast new votes on a locked feature are successfully blocked.

## Assumptions

- Users are authenticated and uniquely identifiable.
- The system handles concurrent requests to update vote counts reliably.

## Formal Requirements & Business KPI Mapping

```alloy
sig User {}
sig FeatureRequest {
  votes: set User,
  locked: Bool
}
enum Bool { True, False }

// Rules:
// 1. Feature is locked if and only if it has 100 or more votes.
fact LockRule {
  all f: FeatureRequest |
    f.locked = (if #f.votes >= 100 then True else False)
}

// 2. A user can only vote once per feature (enforced by 'set User' in FeatureRequest).

// 3. Changing a vote after lock: If locked, no new votes allowed.
// The requirement "Users can change their vote after a feature is locked"
// implies that the set of voters cannot increase if locked.
fact ChangeVoteRule {
   all f, f': FeatureRequest |
     f.locked = True => f'.votes = f.votes
}
```

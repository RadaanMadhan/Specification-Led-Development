# Feature Specification: Private Profile Visibility

**Feature Branch**: `071-private-profile-visibility`
**Created**: 2026-05-20
**Status**: Draft
**Input**: User description: "A social media profile set to 'Private' means their posts can only be seen by users who exist in their 'Approved Followers' set."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Set Profile to Private (Priority: P1)

As a profile owner, I want to toggle my profile privacy to 'Private' so that I can control who sees my posts.

**Why this priority**: Core functionality for enabling privacy.

**Independent Test**: Verify that toggling the privacy setting changes the profile's internal status and restricts visibility.

**Acceptance Scenarios**:

1. **Given** a profile is 'Public', **When** the owner sets the profile to 'Private', **Then** the profile is immediately marked as 'Private' and non-followers lose access to view posts.
2. **Given** a profile is 'Private', **When** the owner sets the profile to 'Public', **Then** the profile is marked as 'Public' and all users can view posts.

---

### User Story 2 - Follow Request Approval (Priority: P1)

As a private profile owner, I want to approve or reject follow requests so that I can manage my 'Approved Followers' set.

**Why this priority**: Essential to build the 'Approved Followers' set.

**Independent Test**: Verify that the owner can accept or reject a pending follow request and that the follower is added/removed from the 'Approved Followers' set.

**Acceptance Scenarios**:

1. **Given** a user has requested to follow a 'Private' profile, **When** the owner approves the request, **Then** the user is added to the 'Approved Followers' set and can now view posts.
2. **Given** a user has requested to follow a 'Private' profile, **When** the owner rejects the request, **Then** the user is not added to the 'Approved Followers' set and still cannot view posts.

---

### User Story 3 - View Posts on Private Profile (Priority: P1)

As a visitor, I want to view posts on a profile only if I am an 'Approved Follower' when the profile is 'Private'.

**Why this priority**: Direct implementation of the privacy requirement.

**Independent Test**: Verify that a visitor's access to posts depends on their presence in the 'Approved Followers' set when the profile is private.

**Acceptance Scenarios**:

1. **Given** a 'Private' profile, **When** a user who is in the 'Approved Followers' set attempts to view posts, **Then** they can see the posts.
2. **Given** a 'Private' profile, **When** a user who is NOT in the 'Approved Followers' set attempts to view posts, **Then** they cannot see the posts.

---

### Edge Cases

- What happens to pending follow requests if a profile changes from 'Private' to 'Public'? (Assume pending requests remain pending or are cleared).
- What happens if a user is in the 'Approved Followers' set but the owner removes them? (They lose access to view posts).
- What if the profile owner is a visitor to their own profile? (Always has access).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a mechanism for a user to set their profile to 'Public' or 'Private'.
- **FR-002**: System MUST restrict viewing of posts from 'Private' profiles to only those users explicitly in the 'Approved Followers' set of the profile owner.
- **FR-003**: System MUST provide a mechanism for 'Private' profile owners to approve or reject follow requests.
- **FR-004**: System MUST allow users to request to follow a 'Private' profile.
- **FR-005**: System MUST immediately enforce privacy restrictions when a profile switches from 'Public' to 'Private'.

### Key Entities

- **User**: Represents a profile owner or a visitor.
- **Post**: Content created by a user.
- **PrivacyStatus**: The state of a profile (Public or Private).
- **ApprovedFollowers**: The set of users approved by the profile owner to view their content.
- **FollowRequest**: A pending request from a visitor to become an approved follower.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of posts from a 'Private' profile are hidden from unauthorized visitors within 1 second of the profile status change.
- **SC-002**: 100% of follow requests can be effectively approved or rejected by the profile owner.
- **SC-003**: Authorized followers (those in the 'Approved Followers' set) can view posts on a 'Private' profile with no increased latency compared to a 'Public' profile.
- **SC-004**: Users can toggle their profile privacy setting with a success rate of 99.9% in under 3 seconds.

## Assumptions

- Users have a unique identifier for follow requests and approvals.
- Posts are directly linked to the user who created them (the author).
- Public profiles allow all users to view posts.
- The 'Approved Followers' set is managed and persisted for each profile owner.

## Formal Requirements & Business KPI Mapping

```alloy
sig User {
    posts: set Post,
    privacy: PrivacyStatus,
    approved_followers: set User
}

enum PrivacyStatus { Public, Private }

sig Post { author: User }

// Requirement: Private posts only seen by approved followers
fact PrivacyEnforcement {
    all p: Post, visitor: User |
        p.author.privacy = Private and visitor not in p.author.approved_followers =>
            visitor cannot view p
}

// Helper: Define view permission
pred canView[visitor: User, p: Post] {
    p.author.privacy = Public or visitor in p.author.approved_followers
}
```

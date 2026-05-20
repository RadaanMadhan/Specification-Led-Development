# Feature Specification: Private Profile Visibility

**Feature Branch**: `018-private-profile-visibility`  
**Created**: 19 May 2026  
**Status**: Draft  
**Input**: User description: "A social media profile set to 'Private' means their posts can only be seen by users who exist in their 'Approved Followers' set."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - View Private Profile Content (Priority: P1)

As a visitor of a private profile, I want to be restricted from viewing their posts unless I am an approved follower, so that my privacy preferences are respected.

**Why this priority**: Core privacy requirement.

**Independent Test**: Can be tested by having two users: one with a private profile and one follower, and one non-follower. The non-follower should not see posts.

**Acceptance Scenarios**:

1. **Given** User A has a Private profile, **When** User B (not in Approved Followers) views User A's profile, **Then** User B cannot see User A's posts.
2. **Given** User A has a Private profile, **When** User C (in Approved Followers) views User A's profile, **Then** User C can see User A's posts.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Enforce privacy for private profiles | `fact { all p: Post, u: User | p.author.isPrivate implies (p.visibility = p.author.approvedFollowers) }` | Telemetry on unauthorized access attempts |

---

### User Story 2 - Manage Approved Followers (Priority: P2)

As a private profile owner, I want to manage my 'Approved Followers' list, so that I have control over who sees my posts.

**Why this priority**: Required for the privacy model to function (owner must be able to approve followers).

**Independent Test**: Add/remove followers and verify visibility changes.

**Acceptance Scenarios**:

1. **Given** User A has a Private profile, **When** User A approves User B, **Then** User B can see User A's posts.
2. **Given** User A has a Private profile, **When** User A removes User B from approved followers, **Then** User B can no longer see User A's posts.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Accurate access control | `pred addFollower[owner, follower: User] { follower in owner.approvedFollowers' }` | Count of followers in approved set |

### Edge Cases

- What happens when a profile switches from Public to Private? (Assumption: Posts become hidden to non-followers).
- What happens if a profile is deleted? (Assumption: Content becomes inaccessible).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST restrict access to posts authored by a user with a 'Private' profile status.
- **FR-002**: System MUST allow access to posts authored by a user with a 'Private' profile status IF the viewer is in the author's 'Approved Followers' set.
- **FR-003**: System MUST provide an interface for a profile owner to manage their 'Approved Followers' list (add/remove).

### Key Entities

- **User**: Represents a social media user. Attributes include profile visibility status (Public/Private), and a set of Approved Followers.
- **Post**: Content created by a user. Author is a User.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of posts authored by 'Private' users are invisible to non-approved users.
- **SC-002**: Average time for follower approval to propagate and grant access is under 5 seconds.
- **SC-003**: 0 unauthorized data leaks reported due to private profile bypasses.

## Assumptions

- Users have a stable identity within the system.
- An existing authentication system is used to identify the viewer.
- The 'Approved Followers' list is managed by the profile owner.

## Formal Requirements & Business KPI Mapping
```alloy
sig User {
    isPrivate: one Bool,
    approvedFollowers: set User
}

sig Post {
    author: one User
}

pred canView[viewer: User, post: Post] {
    (not post.author.isPrivate = True) or (viewer in post.author.approvedFollowers)
}
```

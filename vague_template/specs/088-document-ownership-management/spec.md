# Feature Specification: Document Ownership Management

**Feature Branch**: `[088-document-ownership-management]`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "A document must always have exactly one owner. If the sole owner leaves the company, the document becomes unowned in the system until an Admin reassigns it."

## User Scenarios & Testing

### User Story 1 - Document Owner Leaves Company (Priority: P1)

When a document owner leaves the company, the system should automatically update the document status to ensure it is not permanently lost and is managed correctly.

**Why this priority**: Ensures data integrity and security for company documents.

**Independent Test**: An employee who owns a document is set to "inactive" (left company). Verify that the document's ownership status changes to "unowned" and the document is no longer accessible to the departed employee.

**Acceptance Scenarios**:

1. **Given** a document with one active owner, **When** the owner leaves the company, **Then** the document status becomes "unowned".
2. **Given** an "unowned" document, **When** a regular user attempts to access it, **Then** access is denied.

---

### User Story 2 - Admin Reassigns Unowned Document (Priority: P2)

An Administrator must be able to view and reassign documents that have become unowned to ensure business continuity.

**Why this priority**: Enables critical business operations to resume for affected documents.

**Independent Test**: An Admin views a list of "unowned" documents, selects one, and assigns it to a new active owner. Verify the document is successfully reassigned.

**Acceptance Scenarios**:

1. **Given** an "unowned" document, **When** an Admin assigns a new owner, **Then** the document status becomes "owned" with the new owner.

---

### Edge Cases

- What happens if the sole owner is also an Admin? (Admin should reassign to another admin before leaving)
- How does the system handle documents where the owner is already marked as "left company" but the document is not yet marked "unowned"? (System must retroactively flag these documents)
- What if an Admin attempts to reassign an "unowned" document to an employee who has already left the company? (System must block this action)

## Requirements

### Functional Requirements

- **FR-001**: System MUST track exactly one owner per document at all times.
- **FR-002**: System MUST detect when an owner leaves the company.
- **FR-003**: System MUST automatically transition document status to "unowned" when the sole owner leaves the company.
- **FR-004**: System MUST prevent access to "unowned" documents by standard users.
- **FR-005**: System MUST permit Admins to view "unowned" documents and reassign them to an active user.

### Key Entities

- **Document**: Represents a company asset; has one Owner or an "Unowned" state.
- **Owner (Employee)**: Represents an active user within the system.
- **Admin**: Represents a privileged role capable of managing document ownership.

## Success Criteria

### Measurable Outcomes

- **SC-001**: 100% of documents in the system have either a defined active owner or are explicitly flagged as "unowned".
- **SC-002**: No unowned documents remain accessible to regular users.
- **SC-003**: Admin reassignment of an unowned document is completed and the document is accessible to the new owner within 1 minute of the action.

## Assumptions

- The system has a reliable mechanism to sync employee status (Active/Left).
- "Unowned" is a recognized state for a document within the system.
- Administrative roles are pre-defined.

## Formal Requirements & Business KPI Mapping

```alloy
sig Bool {}
one sig True, False extends Bool {}

abstract sig User {
    active: one Bool
}
sig Admin extends User {}
sig Employee extends User {}

sig Document {
    owner: lone User // 'lone' allows for 'unowned' (no owner)
}

// Rule: A document must have an owner, unless it is unowned 
// after an owner has left.
// In this model, 'unowned' is represented by 'no owner'.

fact {
    // Only active employees can be owners
    all d: Document, u: User | d.owner = u => u.active = True
}

// Rule: If owner leaves, document becomes unowned
pred ownerLeaves[d: Document, u: User] {
    u.active = True
    d.owner = u
    // Transition
    u.active' = False
    d.owner' = none
}

// Rule: Admin reassigns unowned document
pred adminReassigns[d: Document, a: Admin, u: User] {
    d.owner = none
    u.active = True
    d.owner' = u
}
```
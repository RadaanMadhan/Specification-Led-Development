# Feature Specification: Task Hierarchy Enforcement

**Feature Branch**: `044-task-hierarchy-enforcement`  
**Created**: 19 May 2026  
**Status**: Draft  
**Input**: User description: "A parent task cannot be marked 'Done' until all sub-tasks are 'Done'. If a parent task is deleted, all sub-tasks become parent tasks themselves."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Enforce Task Completion Order (Priority: P1)

As a task manager, I want to ensure that parent tasks are only marked as 'Done' when all sub-tasks are also 'Done', so that dependencies are respected.

**Why this priority**: Core business constraint required to maintain task integrity.

**Independent Test**: Create a parent task with one sub-task. Attempt to mark the parent as 'Done' while the sub-task is still 'Pending'. Verify system prevents the action. Mark the sub-task as 'Done' and verify parent can then be marked as 'Done'.

**Acceptance Scenarios**:

1. **Given** a parent task with an incomplete sub-task, **When** user attempts to mark parent as 'Done', **Then** system rejects action with error.
2. **Given** a parent task with all sub-tasks marked as 'Done', **When** user attempts to mark parent as 'Done', **Then** system successfully marks parent as 'Done'.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Enforce task dependency logic | `all p: ParentTask | p.status = Done implies all s: p.subtasks | s.status = Done` | Verify invalid state transition attempts |

---

### User Story 2 - Handle Deleted Parent Task (Priority: P1)

As a task manager, I want to allow sub-tasks to become independent tasks when a parent is deleted, so that I can remove parent categorization without losing the child tasks.

**Why this priority**: Essential for flexible task management and lifecycle management.

**Independent Test**: Create a parent task with sub-tasks. Delete the parent task. Verify that the sub-tasks are now independent tasks (no longer associated with a parent).

**Acceptance Scenarios**:

1. **Given** a parent task with sub-tasks, **When** user deletes the parent task, **Then** sub-tasks are updated to have no parent task.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure task continuity | `all s: Subtask | deleted(s.parent) implies s.parent = none` | Verify task dependency links after deletion |

---

### Edge Cases

- What happens if a sub-task is added to a parent that is already 'Done'? (Assumption: The system must revert the parent status to 'Pending' if a new 'Pending' sub-task is added, or prevent the addition.)
- How does the system handle multi-level hierarchies (tasks with parents which also have parents)? (Assumption: Rule applies recursively.)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST prevent marking a parent task as 'Done' if any associated sub-task is not 'Done'.
- **FR-002**: System MUST automatically unassign the 'parent' relationship for all sub-tasks when their parent task is deleted.
- **FR-003**: System MUST support multi-level task hierarchies where a task can be both a parent and a sub-task.

### Key Entities

- **Task**: Represents the unit of work, with a status and optional parent relationship.
- **ParentTask**: A task that has sub-tasks associated with it.
- **Subtask**: A task that is assigned to a parent task.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of parent tasks with incomplete sub-tasks are prevented from entering the 'Done' state.
- **SC-002**: 100% of child tasks remain present in the system after the deletion of their parent task, correctly reassigned as independent tasks.
- **SC-003**: Task completion workflow violations related to dependency order are reduced to zero.

## Assumptions

- Tasks have a 'Done' and 'Pending' status.
- The 'Done' status is terminal or equivalent for completion tracking.
- The user has permission to delete tasks.

## Formal Requirements & Business KPI Mapping
```alloy
sig Task {
    status: one Status,
    parent: lone Task
}
enum Status { Done, Pending }

pred canBeDone(t: Task) {
    t.status = Pending
    all sub: Task | sub.parent = t implies sub.status = Done
}

// Ensure parent task cannot be marked 'Done' until all sub-tasks are 'Done'
fact ParentDependency {
    all t: Task | t.status = Done implies (all sub: Task | sub.parent = t implies sub.status = Done)
}

// If a parent task is deleted, all sub-tasks become parent tasks themselves (independent)
// Representing 'deleted' by removing the task instance
pred deleteParent(t: Task) {
    no t.parent // Can only delete root tasks for simplicity, or redefine
    // When t is removed, all sub: Task | sub.parent = t implies sub.parent' = none
}
```

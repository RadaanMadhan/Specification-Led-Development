# Feature Specification: Task Hierarchy Management

**Feature Branch**: `task-hierarchy-management`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "A parent task cannot be marked 'Done' until all sub-tasks are 'Done'. If a parent task is deleted, all sub-tasks become parent tasks themselves."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prevent Completion of Incomplete Parent Task (Priority: P1)

As a project manager, I want to ensure that parent tasks are only marked as 'Done' when all their sub-tasks are complete, so that we maintain project integrity.

**Why this priority**: Core business constraint required to enforce task hierarchy validity.

**Independent Test**: Attempt to mark a parent task (with pending sub-tasks) as 'Done' via the user interface. Expect the action to be blocked with an informative message.

**Acceptance Scenarios**:

1. **Given** a parent task with one or more sub-tasks in 'Pending' status, **When** the user attempts to mark the parent task as 'Done', **Then** the action is rejected by the system.
2. **Given** a parent task with all sub-tasks in 'Done' status, **When** the user attempts to mark the parent task as 'Done', **Then** the action is accepted, and the parent task status is updated to 'Done'.

---

### User Story 2 - Promote Sub-tasks upon Parent Deletion (Priority: P2)

As a team member, I want sub-tasks to become top-level tasks if the parent task is deleted, so that no work is lost and task ownership remains clear.

**Why this priority**: Essential for maintaining data integrity and preventing task loss when project structures change.

**Independent Test**: Delete a parent task and verify that all its sub-tasks still exist in the system and are now top-level (independent) tasks.

**Acceptance Scenarios**:

1. **Given** a parent task with sub-tasks, **When** the user deletes the parent task, **Then** the parent task is removed, and all former sub-tasks are promoted to top-level tasks.

---

### Edge Cases

- What happens when a parent task with nested sub-tasks (deep hierarchy) is marked as 'Done'? (Must check all levels recursively).
- How does the system handle the deletion of a parent task that has already been marked as 'Done'? (Sub-tasks should still be promoted).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST prevent any parent task from being marked 'Done' if any of its immediate sub-tasks are not in the 'Done' state.
- **FR-002**: The system MUST implement recursive validation; if a sub-task is itself a parent, it must satisfy the completion criteria before the top-level parent can be completed.
- **FR-003**: Upon the deletion of a parent task, the system MUST automatically re-parent all its direct sub-tasks to the project root (promoting them to top-level tasks).
- **FR-004**: Promoted sub-tasks MUST retain their original status (e.g., 'Pending', 'In Progress').

### Key Entities

- **Task**: Represents a unit of work. Key attributes: ID, status ('Pending', 'In Progress', 'Done'), parent_task_id (optional, null for top-level).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of parent tasks with incomplete sub-tasks are blocked from transitioning to 'Done'.
- **SC-002**: 100% of sub-tasks are successfully preserved and promoted as top-level tasks upon parent deletion.
- **SC-003**: System response time for task status updates remains below 500ms even for deeply nested hierarchies.

## Assumptions

- The project uses a standard tree structure for task hierarchies.
- The 'Done' status is the only terminal state for tasks.
- Project root is the default container for top-level tasks.
- Deletion is a permanent action, and promotion happens synchronously with deletion.

## Formal Requirements & Business KPI Mapping
```alloy
enum Status { Pending, InProgress, Done }

sig Task {
    status: Status,
    parent: lone Task
}

-- Fact: No task can be its own ancestor (prevents cycles)
fact {
    no t: Task | t in t.^parent
}

-- Constraint 1: A parent task cannot be marked 'Done' until all sub-tasks are 'Done'.
-- (Recursive validation via transitive closure)
fact {
    all t: Task | t.status = Done implies (all sub: t.^parent_inv | sub.status = Done)
}

-- Inverse relation helper for parent
pred parent_inv[t, sub: Task] { sub.parent = t }

-- Deletion predicate (Modeling the effect of deletion)
pred deleteTask[t: Task, tasks_before, tasks_after: set Task] {
    tasks_after = tasks_before - t
    -- All direct children are promoted (parent becomes none/null)
    all child: Task | child.parent = t implies (child in tasks_after and child.parent' = none)
    -- Other tasks' hierarchy remains unchanged
    all other: Task - t - {child: Task | child.parent = t} | other.parent' = other.parent
}
```

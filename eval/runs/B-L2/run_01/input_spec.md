# Feature: Task Management API

## Functional Requirements
- **FR-001**: Authenticated users can create, read, update, and delete tasks. Each task has a title, optional description, due date, priority level, and assigned owner. Tasks can be filtered by status, priority, and due date.
- **FR-002**: The API must return responses within acceptable time under normal and peak load conditions. List endpoints that return large result sets must support pagination to prevent response bloat.
- **FR-003**: Tasks must be persisted to durable storage so that no task data is lost in the event of an application service restart or crash. Data consistency must be maintained across concurrent write operations.
- **FR-004**: All create, update, and delete operations must be captured in an audit log recording the actor, action type, affected resource ID, and timestamp. Logs must be queryable by support staff for debugging and compliance review.

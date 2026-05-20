# Feature Specification: Prerequisite Course Enforcement

**Feature Branch**: `012-course-prerequisite-enforcement`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Implement prerequisite enforcement for online courses. A student cannot enroll in Course B unless Course A is marked as 'Completed'."

## User Scenarios & Testing

### User Story 1 - Enroll in Course with Prerequisites Met (Priority: P1)

As a student, I want to enroll in a course when I have already completed its prerequisite courses, so that I can progress in my learning path.

**Why this priority**: Core functionality required to allow users to move forward.

**Independent Test**: Student A completes Course A. Student A then attempts to enroll in Course B (which has Course A as a prerequisite). Enrollment should be successful.

**Acceptance Scenarios**:

1. **Given** Student A has completed Course A, **When** they request to enroll in Course B, **Then** enrollment is processed successfully.
2. **Given** Student A has completed Course A, **When** they view Course B's enrollment page, **Then** they see an "Enroll" button.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure correct progression path | `fact { all s: Student, c: Course | canEnroll[s, c] iff (all p: c.prerequisites | completed[s, p]) }` | Enrollment success rate for valid requests |

---

### User Story 2 - Prevent Enrollment without Prerequisites (Priority: P1)

As a student, I should be prevented from enrolling in a course if I have not completed its prerequisite courses, to ensure I have the foundational knowledge.

**Why this priority**: Essential constraint implementation.

**Independent Test**: Student B has not completed Course A. Student B attempts to enroll in Course B. Enrollment should be denied.

**Acceptance Scenarios**:

1. **Given** Student B has NOT completed Course A, **When** they request to enroll in Course B, **Then** enrollment is denied and they receive an error message indicating a missing prerequisite.
2. **Given** Student B has NOT completed Course A, **When** they view Course B's enrollment page, **Then** they see a "Prerequisite Required: Course A" notification instead of an "Enroll" button.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Maintain curriculum integrity | `fact { no s: Student, c: Course | !canEnroll[s, c] and enrolled[s, c] }` | Count of unauthorized enrollment attempts |

---

## Requirements

### Functional Requirements

- **FR-001**: System MUST identify prerequisite courses for any given course.
- **FR-002**: System MUST verify the completion status of all prerequisite courses before allowing enrollment.
- **FR-003**: System MUST deny enrollment if any prerequisite course is not marked as 'Completed'.
- **FR-004**: System MUST provide a clear reason for enrollment denial to the user.

### Key Entities

- **Student**: Represents a learner in the system.
- **Course**: Represents a learning module, which may have zero or more prerequisites.
- **EnrollmentStatus**: Enum representing ('NotStarted', 'InProgress', 'Completed').

## Success Criteria

### Measurable Outcomes

- **SC-001**: Enrollment requests that violate prerequisite rules are rejected 100% of the time.
- **SC-002**: Users can clearly identify the missing prerequisite for any blocked course immediately.
- **SC-003**: System response time for enrollment validation remains under 500ms.

## Assumptions

- Courses have a clear status ('Completed', 'InProgress', 'NotStarted') recorded for each student.
- Prerequisite rules are static per course definition.

## Formal Requirements & Business KPI Mapping
```alloy
sig Student {
  enrollments: set Enrollment
}

sig Course {
  prerequisites: set Course
}

sig Enrollment {
  course: Course,
  status: EnrollmentStatus
}

enum EnrollmentStatus { NotStarted, InProgress, Completed }

pred completed[s: Student, c: Course] {
  some e: s.enrollments | e.course = c and e.status = Completed
}

pred canEnroll[s: Student, c: Course] {
  all p: c.prerequisites | completed[s, p]
}
```

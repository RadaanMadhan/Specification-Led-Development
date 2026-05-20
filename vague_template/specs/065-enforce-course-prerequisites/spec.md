# Feature Specification: Enforce Course Prerequisites

**Feature Branch**: `065-enforce-course-prerequisites`  
**Created**: 2026-05-20  
**Status**: Draft  
**Input**: User description: "Implement prerequisite enforcement for online courses. A student cannot enroll in Course B unless Course A is marked as 'Completed'."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Enroll in Course with Prerequisite (Priority: P1)

As a student, I want to enroll in a course, and the system should verify if I have completed the required prerequisite course, so that I don't enroll in a course I'm not prepared for.

**Why this priority**: Core functionality of the feature.

**Independent Test**: Enroll in a course that has a prerequisite. Attempt to enroll without having the prerequisite marked as 'Completed'. Ensure enrollment is blocked. Enroll after marking the prerequisite as 'Completed'. Ensure enrollment is allowed.

**Acceptance Scenarios**:

1. **Given** a student has not completed Course A, **When** they attempt to enroll in Course B (which requires Course A), **Then** the system denies enrollment and displays an error.
2. **Given** a student has completed Course A, **When** they attempt to enroll in Course B (which requires Course A), **Then** the system permits enrollment.

---

### User Story 2 - Enroll in Course without Prerequisite (Priority: P2)

As a student, I want to enroll in a course that does not have any prerequisites, so that I can start learning immediately.

**Why this priority**: Ensures basic functionality isn't broken.

**Independent Test**: Attempt to enroll in a course with no defined prerequisites. Ensure enrollment is allowed.

**Acceptance Scenarios**:

1. **Given** a course has no prerequisites, **When** a student attempts to enroll, **Then** the system permits enrollment.

### Edge Cases

- What happens when a course has multiple prerequisites? (Assume all must be completed)
- How does system handle circular prerequisites? (System should prevent circular configuration)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST verify enrollment eligibility against course prerequisites upon enrollment attempt.
- **FR-002**: System MUST deny enrollment in a course if any required prerequisite course is not in 'Completed' status.
- **FR-003**: System MUST permit enrollment in a course if all required prerequisite courses are in 'Completed' status.
- **FR-004**: System MUST allow enrollment in courses with no defined prerequisites.

### Key Entities

- **Student**: An individual enrolled in the system.
- **Course**: An academic unit, which may have prerequisites.
- **Enrollment**: A record representing a student's participation in a course.
- **CourseStatus**: The progress state of a student in a course (e.g., 'Not Started', 'In Progress', 'Completed').

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of enrollment attempts for courses with incomplete prerequisites are blocked.
- **SC-002**: 100% of enrollment attempts for courses with all prerequisites 'Completed' are successful.
- **SC-003**: Enrollment processing time for courses with prerequisites does not increase by more than 200ms compared to courses without prerequisites.

## Assumptions

- 'Completed' is the only status that satisfies the prerequisite requirement.
- Prerequisites are assigned at the course level.
- Courses with no defined prerequisites are considered eligible for enrollment by all students.

## Formal Requirements & Business KPI Mapping

```alloy
sig Student {
    completedCourses: set Course,
    enrolledCourses: set Course
}

sig Course {
    prerequisites: set Course
}

// Rule: Cannot enroll in a course unless all prerequisites are completed
pred canEnroll(s: Student, c: Course) {
    c.prerequisites in s.completedCourses
}

// Rule: Cannot complete a course if already enrolled (implied state constraint)
// Rule: A completed course must be an enrolled course
fact {
    all s: Student | s.completedCourses in s.enrolledCourses
    all c: Course | c not in c.prerequisites // No self-prerequisites
}

// Assert: If a student is enrolled in a course, they must have met the prerequisites
assert EnrollmentRequiresPrerequisites {
    all s: Student, c: s.enrolledCourses | 
        c.prerequisites in s.completedCourses
}

check EnrollmentRequiresPrerequisites for 5
```

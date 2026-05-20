# Feature Specification: Hello World CLI

**Feature Branch**: `999-hello-cli`
**Created**: 2026-05-04
**Status**: Draft
**Input**: User description: "A trivial hello-world CLI for testing the parser."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Print Hello World (Priority: P1)

A user runs the tool with no arguments and gets a greeting.

**Why this priority**: This is the only thing the tool does.

**Independent Test**: Run `hello` and check the output.

**Acceptance Scenarios**:

1. **Given** the user is at a shell prompt, **When** they run `hello`,
   **Then** the text "Hello, world!" is printed to stdout.
2. **Given** the user is at a shell prompt, **When** they run `hello --name Leon`,
   **Then** the text "Hello, Leon!" is printed to stdout.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST print "Hello, world!" when invoked with no arguments.
- **FR-002**: System MUST accept a `--name` flag and personalise the greeting.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The tool exits with code 0 on a successful greeting.

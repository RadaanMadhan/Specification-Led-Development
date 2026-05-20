# Feature Specification: Dispute Resolution State Machine

**Feature Branch**: `082-dispute-resolution-workflow`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Implement a multi-step dispute resolution state machine. A dispute goes from Open -> Mediation -> Arbitration -> Closed. It can only move to Arbitration if Mediation times out after 14 days or both parties reject the mediator's proposal."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resolve Dispute via Mediation (Priority: P1)

A user involved in a dispute wants to resolve it quickly through mediation, avoiding the need for formal arbitration.

**Why this priority**: Mediation is the primary, more efficient path to resolution.

**Independent Test**: Dispute starts in 'Open', moves to 'Mediation', and successfully transitions to 'Closed' when parties agree.

**Acceptance Scenarios**:

1. **Given** a dispute is in 'Open' state, **When** parties initiate mediation, **Then** the dispute transitions to 'Mediation'.
2. **Given** a dispute is in 'Mediation' state, **When** both parties accept the mediator's proposal, **Then** the dispute transitions to 'Closed'.

---

### User Story 2 - Escalate Dispute to Arbitration (Priority: P2)

When mediation fails to resolve the dispute, the system must allow transition to arbitration based on specific criteria.

**Why this priority**: Ensures a fallback path for unresolved disputes.

**Independent Test**: Dispute transitions to 'Arbitration' only when mediation has timed out or both parties rejected the proposal.

**Acceptance Scenarios**:

1. **Given** a dispute is in 'Mediation' for 14 days without resolution, **When** the system checks for transition, **Then** it must allow transition to 'Arbitration'.
2. **Given** a dispute is in 'Mediation' state, **When** both parties formally reject the mediator's proposal, **Then** the dispute transitions to 'Arbitration'.
3. **Given** a dispute is in 'Mediation' state for less than 14 days and both parties have not rejected the proposal, **When** arbitration is requested, **Then** the system must deny the transition.

---

### Edge Cases

- What happens when a dispute is prematurely closed?
- How does the system handle if the mediator is unavailable?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST implement a state machine for dispute resolution with the following states: Open, Mediation, Arbitration, Closed.
- **FR-002**: The system MUST allow transitions from Open to Mediation.
- **FR-003**: The system MUST allow transitions from Mediation to Closed (resolved).
- **FR-004**: The system MUST allow transitions from Mediation to Arbitration ONLY IF (Mediation time >= 14 days) OR (Both parties reject the mediator's proposal).
- **FR-005**: The system MUST allow transitions from Arbitration to Closed.

### Key Entities

- **Dispute**: Represents the conflict instance with attributes: current_state, start_date, mediation_start_date, status.
- **Party**: Represents the involved entities in the dispute.
- **Mediator**: Facilitates the mediation process.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of disputes follow the defined state transition rules.
- **SC-002**: Disputes cannot enter 'Arbitration' state unless the defined conditions (timeout or rejection) are met.
- **SC-003**: System accurately tracks the duration of the mediation process to enforce the 14-day timeout rule.

## Assumptions

- The dispute start and mediation start dates are accurately captured by the system.
- Formal rejection by both parties is explicitly recorded in the system.
- An arbitration mechanism is available once the state transitions to 'Arbitration'.

## Formal Requirements & Business KPI Mapping
```alloy
// Dispute Resolution Alloy Model

abstract sig State {}
one sig Open, Mediation, Arbitration, Closed extends State {}

sig Dispute {
    var state: one State,
    // Flags for transition conditions
    mediationTimedOut: one Bool,
    mediationRejected: one Bool
}

abstract sig Bool {}
one sig True, False extends Bool {}

// Predicate to enforce valid transitions
pred transition[d: Dispute, nextState: State] {
    d.state = Open => nextState = Mediation
    d.state = Mediation => (nextState = Closed or (nextState = Arbitration and (d.mediationTimedOut = True or d.mediationRejected = True)))
    d.state = Arbitration => nextState = Closed
}

// Initial state
pred initial[d: Dispute] {
    d.state = Open
}
```
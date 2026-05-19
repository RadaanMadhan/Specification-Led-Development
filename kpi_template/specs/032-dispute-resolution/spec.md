# Feature Specification: Dispute Resolution Flow

**Feature Branch**: `029-dispute-resolution`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Implement a multi-step dispute resolution state machine. A dispute goes from Open -> Mediation -> Arbitration -> Closed. It can only move to Arbitration if Mediation times out after 14 days or both parties reject the mediator's proposal."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Standard Dispute Resolution (Priority: P1)

As a Disputant, I want to initiate a dispute, so that I can reach a resolution with the other party.

**Why this priority**: Core functionality of the dispute resolution process.

**Independent Test**: Can be tested by initiating a dispute, observing the transition from 'Open' to 'Mediation', and verifying successful resolution in 'Mediation'.

**Acceptance Scenarios**:

1. **Given** a new dispute, **When** filed, **Then** the dispute transitions to the 'Open' state.
2. **Given** an 'Open' dispute, **When** mediator intervention is assigned, **Then** the dispute transitions to the 'Mediation' state.
3. **Given** a 'Mediation' dispute, **When** both parties accept the mediator's proposal, **Then** the dispute transitions to the 'Closed' state.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Reduce dispute resolution time | `fact { Dispute.state = Mediation implies Mediation.status = Active }` | Track time in Mediation |

---

### User Story 2 - Escalation to Arbitration (Priority: P1)

As a Disputant or Mediator, I want to escalate an unresolved dispute to Arbitration, so that a final decision can be reached.

**Why this priority**: Essential for handling impasses in mediation.

**Independent Test**: Can be tested by initiating an 'Open' dispute, moving to 'Mediation', and triggering an escalation either by timeout (14 days) or rejection by both parties.

**Acceptance Scenarios**:

1. **Given** a 'Mediation' dispute, **When** it has been in the 'Mediation' state for > 14 days, **Then** the dispute is eligible to transition to the 'Arbitration' state.
2. **Given** a 'Mediation' dispute, **When** both parties reject the mediator's proposal, **Then** the dispute transitions to the 'Arbitration' state.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure fair resolution | `fact { Dispute.state = Arbitration implies Arbitration.status = Active }` | Monitor escalation rate |

---

### Edge Cases

- What happens when a party becomes unreachable during Mediation?
- How does the system handle concurrent disputes between the same parties?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST initiate a new dispute in the 'Open' state.
- **FR-002**: System MUST transition a dispute from 'Open' to 'Mediation'.
- **FR-003**: System MUST transition a dispute from 'Mediation' to 'Arbitration' ONLY IF the dispute has been in 'Mediation' for 14 days OR both parties reject the mediator's proposal.
- **FR-004**: System MUST transition a dispute from 'Arbitration' to 'Closed' upon resolution.
- **FR-005**: System MUST transition a dispute from 'Mediation' to 'Closed' if resolved.
- **FR-006**: System MUST ensure that a dispute cannot bypass the 'Mediation' state to reach 'Arbitration'.

### Key Entities

- **Dispute**: Represents the disagreement, with a state and lifecycle history.
- **Parties**: The two involved sides of the dispute.
- **Mediator**: The neutral party facilitating the discussion in the Mediation phase.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Disputes are resolved (in Mediation or Arbitration) within 30 days on average.
- **SC-002**: 100% of disputes correctly transition through the defined state machine without bypassing steps.
- **SC-003**: Escalation to Arbitration is automatically triggered or available immediately upon meeting the defined conditions.

## Assumptions

- A separate system component handles timing and notifications for the 14-day Mediation timeout.
- The state machine is managed by a central workflow service.
- Dispute initiation and resolution events are correctly logged in the system.

## Formal Requirements & Business KPI Mapping

```alloy
-- State Machine
abstract sig State {}
one sig Open, Mediation, Arbitration, Closed extends State {}

abstract sig Bool {}
one sig True, False extends Bool {}

sig Party {}
sig Mediator {}

sig Dispute {
    state: State,
    mediator: lone Mediator,
    timedOut: Bool,
    proposalRejectedByBoth: Bool
}

-- Rules for valid transitions
fact StateTransitions {
    all d: Dispute | {
        -- A dispute can move to Arbitration from Mediation if specific conditions are met
        d.state = Mediation and (d.timedOut = True or d.proposalRejectedByBoth = True) implies
            validNextState[d, Arbitration]
        
        -- Basic valid transitions
        d.state = Open implies validNextState[d, Mediation]
        d.state = Mediation implies validNextState[d, Closed]
        d.state = Arbitration implies validNextState[d, Closed]
    }
}

pred validNextState[d: Dispute, s: State] {
    -- Dummy predicate to allow compilation
}
```

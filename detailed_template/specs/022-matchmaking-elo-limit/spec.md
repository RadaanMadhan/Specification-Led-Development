# Feature Specification: Matchmaking Elo Limit

**Feature Branch**: `019-matchmaking-elo-limit`
**Created**: 2026-05-19
**Status**: Draft
**Input**: User description: "Implement a matchmaking rule for competitive gaming: players can only be matched if their Elo rating difference is less than 500 points."

## User Scenarios & Testing

### User Story 1 - Matchmaking Validation (Priority: P1)

As a player in a competitive queue, I want to be matched only with players of a similar skill level, so that matches are fair and challenging.

**Why this priority**: Core functionality of the feature request.

**Independent Test**: Can be tested by placing two players with < 500 Elo difference in a queue and verifying a match is possible, and by placing two players with >= 500 Elo difference and verifying they are not matched together.

**Acceptance Scenarios**:

1. **Given** two players, Player A (Elo: 1000) and Player B (Elo: 1400), **When** both are in the matchmaking queue, **Then** the system should allow them to be matched because their Elo difference is 400 (which is < 500).
2. **Given** two players, Player A (Elo: 1000) and Player B (Elo: 1600), **When** both are in the matchmaking queue, **Then** the system should prevent them from being matched because their Elo difference is 600 (which is >= 500).

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure fair match quality | `fact { all m: Match | abs[m.p1.elo - m.p2.elo] < 500 }` | Matchmaking simulation validation |

---

### Edge Cases

- What happens when a player's Elo rating is undefined? [Assumption: All players in the matchmaking pool have a valid, assigned Elo rating.]
- How does the system handle rapid Elo changes during the matchmaking process? [Assumption: The Elo rating used is the value at the time the matchmaking process evaluates the potential match.]
- What happens if the matchmaking queue is empty? The system remains in a waiting state for both players.

## Requirements

### Functional Requirements

- **FR-001**: System MUST calculate the absolute difference between the Elo ratings of any two potential matched players.
- **FR-002**: System MUST permit matchmaking only if the calculated Elo rating difference is less than 500 points.
- **FR-003**: System MUST prevent the creation of a match if the calculated Elo rating difference is 500 points or greater.

### Key Entities

- **Player**: Represents a competitive gamer with an Elo rating attribute.
- **Match**: Represents a valid pairing of two Players for a competitive game session.

## Success Criteria

### Measurable Outcomes

- **SC-001**: 100% of all generated matches successfully satisfy the Elo rating difference constraint (< 500).
- **SC-002**: No match is generated where the Elo rating difference between players is >= 500 points.

## Assumptions

- Elo ratings are numeric values available for all players participating in the matchmaking process.
- The matchmaking algorithm periodically evaluates the queue and identifies valid player pairs.
- Players cannot modify their own Elo rating to bypass matchmaking restrictions.

## Formal Requirements & Business KPI Mapping
```alloy
sig Player {
  elo: Int
}

sig Match {
  p1: Player,
  p2: Player
}

fact EloConstraint {
  all m: Match | 
    let diff = abs[m.p1.elo - m.p2.elo] |
      diff < 500
}
```

# Feature Specification: Elo Matchmaking Rule

**Feature Branch**: `072-elo-matchmaking-rule`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Implement a matchmaking rule for competitive gaming: players can only be matched if their Elo rating difference is less than 500 points."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Matchmaking with compatible Elo (Priority: P1)

Competitive players want to ensure they are matched with opponents of similar skill level to have fair games.

**Why this priority**: Core functionality of the matchmaking system ensuring fair competitive balance.

**Independent Test**: Can be fully tested by creating two players with Elo ratings 1000 and 1200, attempting to match them, and verifying that the system proposes the match.

**Acceptance Scenarios**:

1. **Given** Player A (Elo 1000) and Player B (Elo 1200), **When** matchmaking request is initiated, **Then** the match is proposed (difference is 200 < 500).

---

### User Story 2 - Blocking incompatible Elo (Priority: P2)

Competitive players want to avoid being matched with opponents whose skill level is significantly different, leading to one-sided games.

**Why this priority**: Essential to uphold competitive integrity.

**Independent Test**: Can be tested by creating two players with Elo ratings 1000 and 1600, attempting to match them, and verifying that the system rejects the match.

**Acceptance Scenarios**:

1. **Given** Player A (Elo 1000) and Player B (Elo 1600), **When** matchmaking request is initiated, **Then** the match is rejected (difference is 600 >= 500).

---

### Edge Cases

- What happens when a player has no established Elo rating? [Assumption: Players without Elo are assigned a baseline value.]
- How does system handle cases where no player within the 500 Elo range is available? [Assumption: System waits for a compatible player or expands search criteria if necessary - scope outside current feature.]

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST identify the Elo rating of all players in the matchmaking pool.
- **FR-002**: System MUST calculate the absolute difference between Elo ratings of candidate players.
- **FR-003**: System MUST permit a match if the absolute Elo difference is strictly less than 500.
- **FR-004**: System MUST prohibit a match if the absolute Elo difference is 500 or greater.

### Key Entities

- **Player**: A participant in the competitive gaming system, characterized by a unique ID and a numerical Elo rating.
- **Match**: A proposed pairing of two Players for a competitive game session.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of generated matches adhere to the Elo rating difference constraint (< 500).
- **SC-002**: Matchmaking latency does not increase by more than 10% due to the inclusion of this validation rule.
- **SC-003**: Support tickets related to unfair matchmaking (due to skill gap) are reduced by 25%.

## Assumptions

- There is an existing, functional system that tracks and updates Player Elo ratings.
- The matchmaking system operates in real-time or near real-time.
- Players have pre-established Elo ratings prior to entering the matchmaking pool.

## Formal Requirements & Business KPI Mapping
```alloy
sig Player {
    elo: Int
}

pred isValidMatch(p1: Player, p2: Player) {
    let diff = abs[p1.elo - p2.elo] {
        diff < 500
    }
}
```
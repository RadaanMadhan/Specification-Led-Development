/*
 * tiny_passing_snapshot.als
 *
 * Hand-crafted snapshot designed to PASS all three KPIs.
 * Use this to confirm the assertions return UNSAT (no counterexample)
 * when the spec is well-formed.
 *
 * Concept: a trivial three-scenario chain inside one User Story.
 *   NoSession --start--> Work25 --tick--> Break5 --tick--> Work25
 */

// Concrete states (extend the abstract State sig from domain.als)
one sig NoSession, Work25, Break5 extends State {}

// Concrete actions
one sig RunStart, PhaseEnd extends Action {}

// Functional Requirements
one sig FR_001, FR_002 extends Requirement {}

// One User Story, with all three scenarios under it
one sig Story_1 extends Story {}

// NoSession is the initial state
fact InitialStates { Initial = NoSession }

// Three scenarios. All three (given, action, then) triples are distinct
// → KPI-G-003 (uniqueness) PASSES. Sc2 and Sc3 share the same action
// (PhaseEnd) but with different givens → KPI-G-001 (determinism) PASSES.
// Story_1 has scenarios → KPI-G-002 (story coverage) PASSES.
one sig Sc1 extends Scenario {} {
    given  = NoSession
    action = RunStart
    then   = Work25
    covers = FR_001
    story  = Story_1
}
one sig Sc2 extends Scenario {} {
    given  = Work25
    action = PhaseEnd
    then   = Break5
    covers = FR_002
    story  = Story_1
}
one sig Sc3 extends Scenario {} {
    given  = Break5
    action = PhaseEnd
    then   = Work25
    covers = FR_001 + FR_002
    story  = Story_1
}

// Scope chosen to fit our exact snapshot size.
check KPI_G_001 for 3 Scenario, 3 State, 2 Action, 2 Requirement, 1 Story
check KPI_G_002 for 3 Scenario, 3 State, 2 Action, 2 Requirement, 1 Story
check KPI_G_003 for 3 Scenario, 3 State, 2 Action, 2 Requirement, 1 Story

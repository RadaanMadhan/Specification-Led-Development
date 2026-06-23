/*
 * tiny_failing_snapshot.als
 *
 * Hand-crafted snapshot designed to FAIL all three KPIs, each
 * for its own deliberate reason. Use this to confirm the
 * assertions return SAT (counterexample found) and the harness
 * surfaces the failures correctly.
 */

one sig NoSession, Work25, Break5 extends State {}
one sig RunStart, PhaseEnd extends Action {}
one sig FR_001, FR_002 extends Requirement {}

// Two stories. Story_2 will have no scenarios → KPI-G-002 fails.
one sig Story_1, Story_2 extends Story {}

fact InitialStates { Initial = NoSession }

// --- Violation 1: KPI-G-001 (Determinism) ---
// Sc1 and Sc2 have the same Given+Action but different Then.
one sig Sc1 extends Scenario {} {
    given  = NoSession
    action = RunStart
    then   = Work25
    covers = FR_001
    story  = Story_1
}
one sig Sc2 extends Scenario {} {
    given  = NoSession
    action = RunStart
    then   = Break5      // contradicts Sc1
    covers = FR_002
    story  = Story_1
}

// --- Violation 3: KPI-G-003 (Scenario Uniqueness) ---
// Sc3 and Sc4 are identical on (Given, Action, Then) — duplicate.
one sig Sc3 extends Scenario {} {
    given  = Work25
    action = PhaseEnd
    then   = Break5
    covers = FR_001
    story  = Story_1
}
one sig Sc4 extends Scenario {} {
    given  = Work25
    action = PhaseEnd
    then   = Break5      // identical (G,A,T) to Sc3 → duplicate
    covers = FR_002
    story  = Story_1
}

// --- Violation 2: KPI-G-002 (Story Coverage) ---
// Story_2 is declared but no scenario references it.

check KPI_G_001 for 4 Scenario, 3 State, 2 Action, 2 Requirement, 2 Story
check KPI_G_002 for 4 Scenario, 3 State, 2 Action, 2 Requirement, 2 Story
check KPI_G_003 for 4 Scenario, 3 State, 2 Action, 2 Requirement, 2 Story

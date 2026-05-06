/*
 * kpi_library.als
 *
 * Generic, application-agnostic KPIs for spec-led-eval.
 * Each KPI is one Alloy predicate plus a matching assertion.
 *
 * The harness runs `check KPI_G_NNN` against the assembled
 * domain + this library + a generated snapshot.
 *
 * These three KPIs are deliberately ENCODING-INSENSITIVE: their
 * verdicts depend on the *graph* of scenarios rather than the
 * specific atom names a lifter chose. A well-designed SpecKit
 * spec passes all three; a defective one fails the relevant ones
 * for clear, actionable reasons.
 */


/* ----------------------------------------------------------------
 * KPI-G-001 — Scenario Determinism
 *
 * No two acceptance scenarios with the same precondition (Given)
 * and the same action (When) end in different outcomes (Then).
 *
 * Catches: contradictory specifications. If two stories in the
 * same spec describe the same trigger leading to different
 * outcomes, this KPI surfaces it.
 * ---------------------------------------------------------------- */
pred KPI_G_001_Determinism {
    no disj s1, s2: Scenario |
        s1.given  = s2.given  and
        s1.action = s2.action and
        s1.then  != s2.then
}
assert KPI_G_001 { KPI_G_001_Determinism }


/* ----------------------------------------------------------------
 * KPI-G-002 — Story Coverage
 *
 * Every User Story declared in the spec has at least one
 * acceptance scenario.
 *
 * Catches: half-finished templates — a User Story heading with
 * no acceptance scenarios under it. The SpecKit spec template
 * mandates at least one Given/When/Then per story, so a story
 * with zero scenarios is an unambiguous defect.
 * ---------------------------------------------------------------- */
pred KPI_G_002_StoryCoverage {
    all st: Story | some s: Scenario | s.story = st
}
assert KPI_G_002 { KPI_G_002_StoryCoverage }


/* ----------------------------------------------------------------
 * KPI-G-003 — Scenario Uniqueness
 *
 * No two acceptance scenarios share an identical
 * (Given, Action, Then) triple.
 *
 * Catches: copy-paste duplication — a scenario that was cloned
 * across stories but never edited to test something new.
 * Encoding-insensitive: duplicates remain duplicates regardless
 * of how the lifter atomises the prose.
 * ---------------------------------------------------------------- */
pred KPI_G_003_ScenarioUniqueness {
    no disj s1, s2: Scenario |
        s1.given  = s2.given  and
        s1.action = s2.action and
        s1.then   = s2.then
}
assert KPI_G_003 { KPI_G_003_ScenarioUniqueness }

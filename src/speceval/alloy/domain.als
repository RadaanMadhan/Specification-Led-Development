/*
 * domain.als
 *
 * Generic Alloy domain model for spec-led-eval.
 *
 * This file is APPLICATION-AGNOSTIC. It defines the vocabulary that
 * every SpecKit `spec.md` lifts into. The same domain works for a
 * Pomodoro timer, a todo CLI, a banking service, anything.
 *
 *   State        — a canonical condition of the system
 *   Action       — a canonical event/operation a user or system performs
 *   Requirement  — one Functional Requirement (FR-NNN) from spec.md
 *   Scenario     — one Given/When/Then triple from spec.md
 *   Initial      — subset of State designated as initial conditions
 *
 * Each generated snapshot.als declares concrete `one sig` instances
 * extending these sigs to describe one specific spec.
 *
 * KPIs (kpi_library.als) are written against this vocabulary, so they
 * apply uniformly to any spec lifted into this shape.
 */

abstract sig State {}
abstract sig Action {}
abstract sig Requirement {}
abstract sig Story {}

abstract sig Scenario {
    given:  one State,
    action: one Action,
    then:   one State,
    covers: set Requirement,
    story:  one Story
}

// `Initial` is a subset of `State`. Any concrete State atom can be
// designated initial by including it in this subset. The lifter does this
// for the precondition of the first Priority-1 scenario, plus any state
// the LLM identifies as a starting condition.
sig Initial in State {}

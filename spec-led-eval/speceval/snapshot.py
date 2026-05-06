"""snapshot.py — render a LiftResult into a runnable Alloy snapshot.als.

This module is purely mechanical: given canonical atom names (states,
actions, requirements) and per-scenario mappings, it emits valid Alloy
syntax.

The *interpretation* step that produces a LiftResult lives elsewhere:
- For Phase 1 (this PoC): a hardcoded mapping in `lift_pomodoro_hardcoded`
  below, used to prove the pipeline end-to-end without an LLM.
- For Phase 2: an LLM-driven lifter (see lifter.py) returns the same
  LiftResult shape.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from textwrap import dedent

from speceval.parser import ParsedSpec


# ---------------------------------------------------------------------------
# Intermediate representation: the contract between lifter and snapshot.
# ---------------------------------------------------------------------------

@dataclass
class LiftedScenario:
    """One scenario expressed in canonical atom names."""
    label: str                    # "1.1", "2.3", ...
    given_state: str              # canonical State name, e.g. "NoActiveSession"
    action: str                   # canonical Action name, e.g. "RunPomoStart"
    then_state: str               # canonical State name
    covers: list[str]             # list of FR ids covered, e.g. ["FR-001", "FR-005"]
    story: str                    # canonical Story name, e.g. "Story_1"


@dataclass
class LiftResult:
    """The canonical structural data extracted from a spec."""
    states: list[str]             # sorted, unique
    actions: list[str]            # sorted, unique
    requirements: list[str]       # sorted, unique (FR ids)
    stories: list[str]            # sorted, unique (Story IDs, e.g. "Story_1")
    initial_states: list[str]     # subset of states
    scenarios: list[LiftedScenario]

    def __post_init__(self) -> None:
        self.states = sorted(set(self.states))
        self.actions = sorted(set(self.actions))
        self.requirements = sorted(set(self.requirements))
        self.stories = sorted(set(self.stories))
        self.initial_states = sorted(set(self.initial_states))


# ---------------------------------------------------------------------------
# Snapshot rendering
# ---------------------------------------------------------------------------

def _alloy_id(name: str) -> str:
    """Convert a canonical name into an Alloy-safe identifier.

    Alloy identifiers must match [A-Za-z][A-Za-z0-9_'/]*. We replace
    hyphens (FR-001 → FR_001) and reject anything else as a coding bug.
    """
    safe = name.replace("-", "_")
    if not safe.replace("_", "").isalnum():
        raise ValueError(f"unsafe Alloy identifier: {name!r}")
    return safe


def render_snapshot(lift: LiftResult, *, header_comment: str = "") -> str:
    """Render the LiftResult as a complete Alloy snapshot file."""
    lines: list[str] = []

    if header_comment:
        lines.append("/*")
        for line in header_comment.splitlines():
            lines.append(" * " + line)
        lines.append(" */")
        lines.append("")

    # --- Sigs for States, Actions, Requirements, Stories ---
    lines.append("// === Concrete States, Actions, Requirements, Stories lifted from spec.md ===")

    if lift.states:
        states_csv = ", ".join(_alloy_id(s) for s in lift.states)
        lines.append(f"one sig {states_csv} extends State {{}}")
    if lift.actions:
        actions_csv = ", ".join(_alloy_id(a) for a in lift.actions)
        lines.append(f"one sig {actions_csv} extends Action {{}}")
    if lift.requirements:
        reqs_csv = ", ".join(_alloy_id(r) for r in lift.requirements)
        lines.append(f"one sig {reqs_csv} extends Requirement {{}}")
    if lift.stories:
        stories_csv = ", ".join(_alloy_id(st) for st in lift.stories)
        lines.append(f"one sig {stories_csv} extends Story {{}}")

    # --- Initial states fact ---
    lines.append("")
    lines.append("// === Initial states ===")
    if lift.initial_states:
        initial_csv = " + ".join(_alloy_id(s) for s in lift.initial_states)
        lines.append(f"fact InitialStates {{ Initial = {initial_csv} }}")
    else:
        lines.append("fact InitialStates { no Initial }")

    # --- One Scenario sig per lifted scenario ---
    lines.append("")
    lines.append("// === Acceptance scenarios ===")
    for sc in lift.scenarios:
        sc_name = "Scenario_" + sc.label.replace(".", "_")
        covers_expr = (
            " + ".join(_alloy_id(r) for r in sc.covers) if sc.covers else "none"
        )
        lines.append(f"one sig {sc_name} extends Scenario {{}} {{")
        lines.append(f"    given  = {_alloy_id(sc.given_state)}")
        lines.append(f"    action = {_alloy_id(sc.action)}")
        lines.append(f"    then   = {_alloy_id(sc.then_state)}")
        lines.append(f"    covers = {covers_expr}")
        lines.append(f"    story  = {_alloy_id(sc.story)}")
        lines.append("}")

    # --- Check commands with explicit scopes that fit the snapshot ---
    n_sc = len(lift.scenarios)
    n_st = len(lift.states)
    n_ac = len(lift.actions)
    n_rq = len(lift.requirements)
    n_sy = len(lift.stories)
    scope = (
        f"{n_sc} Scenario, {n_st} State, {n_ac} Action, "
        f"{n_rq} Requirement, {n_sy} Story"
    )

    lines.append("")
    lines.append("// === KPI checks (scoped exactly to the snapshot) ===")
    for kpi in ("KPI_G_001", "KPI_G_002", "KPI_G_003"):
        lines.append(f"check {kpi} for {scope}")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Phase-1 hardcoded lifter for the 001-pomo-cli spec.
#
# This lives here for the PoC. In Phase 2, lifter.py replaces it with an
# LLM-driven version that returns the same LiftResult. The snapshot
# rendering above is unaffected.
# ---------------------------------------------------------------------------

# Each tuple is (scenario_label, given_state, action, then_state, [FR ids]).
# Carefully hand-mapped so that:
#   - Naming reuses the same atom for semantically identical prose
#     ("the user has no active session" == "no session is active").
#   - Initial states are the natural starting points.
#   - FR coverage reflects what each scenario actually exercises.
#   - Some FRs are *deliberately* uncovered (FR-011 persist, FR-014 cleanup)
#     so that KPI-G-003 produces a real, meaningful failure on this spec.
_POMODORO_MAPPING: list[tuple[str, str, str, str, list[str]]] = [
    # --- Story 1: default session ---
    ("1.1", "NoActiveSession",       "RunPomoStart",       "Work25Countdown",       ["FR-001", "FR-002", "FR-005", "FR-007"]),
    ("1.2", "WorkPhaseCompleted",    "PhaseEndsAutomatic", "Break5Countdown",       ["FR-005", "FR-008"]),
    ("1.3", "FourWorkPhasesDone",    "FourthPhaseEnds",    "LongBreak15Countdown",  ["FR-005", "FR-006"]),
    ("1.4", "TimerRunning",          "PressCtrlC",         "SessionEndedSummary",   ["FR-010"]),

    # --- Story 2: configured durations ---
    ("2.1", "InvokedWithWork50",     "SessionStarts",      "Work50Countdown",       ["FR-003"]),
    ("2.2", "InvokedWithBreak10",    "BreakBegins",        "Break10Countdown",      ["FR-003"]),
    ("2.3", "InvokedWithLongBrk30",  "FourthPhaseEnds",    "LongBreak30Countdown",  ["FR-003"]),
    ("2.4", "InvokedWithInvalid",    "ProcessFlag",        "ErrorMessageShown",     ["FR-004"]),

    # --- Story 3: pause / resume ---
    ("3.1", "TimerRunning",          "PressPauseKey",      "TimerPaused",           ["FR-009"]),
    ("3.2", "TimerPaused",           "PressPauseKey",      "TimerRunning",          ["FR-009"]),
    ("3.3", "TimerPaused",           "PressCtrlC",         "SessionEndedSummary",   ["FR-010"]),

    # --- Story 4: status query ---
    ("4.1", "SessionActive",         "RunStatusJson",      "JsonStatusPrinted",     ["FR-012"]),
    ("4.2", "SessionActiveAndPaused","RunStatusJson",      "JsonStatusPausedTrue",  ["FR-012"]),
    ("4.3", "NoActiveSession",       "RunStatusJson",      "NoSessionMessage",      ["FR-013"]),
    ("4.4", "SessionActive",         "RunStatusPlain",     "HumanReadableSummary",  ["FR-012"]),
]

# Initial states for the Pomodoro spec. Starting points the user can
# legitimately begin from without prior in-spec actions:
_POMODORO_INITIALS = [
    "NoActiveSession",         # the natural starting condition
    "InvokedWithWork50",       # configured starting points
    "InvokedWithBreak10",
    "InvokedWithLongBrk30",
    "InvokedWithInvalid",
]


def lift_pomodoro_hardcoded(parsed: ParsedSpec) -> LiftResult:
    """Phase-1 hardcoded lifter, only for the 001-pomo-cli spec.

    Validates the parsed spec has the expected scenario labels and FRs,
    then emits the canonical mapping above. Used to prove the snapshot/
    runner/reporter pipeline end-to-end before plugging in the LLM.
    """
    expected_labels = {row[0] for row in _POMODORO_MAPPING}
    actual_labels = {sc.label for sc in parsed.all_scenarios}
    if not expected_labels.issubset(actual_labels):
        missing = expected_labels - actual_labels
        raise ValueError(
            f"hardcoded Pomodoro mapping expects scenarios {sorted(missing)} "
            f"that are not present in the parsed spec."
        )

    states: set[str] = set()
    actions: set[str] = set()
    stories: set[str] = set()
    scenarios: list[LiftedScenario] = []

    for label, given, action, then, covers in _POMODORO_MAPPING:
        # Story name is derived from the user-story number in the label,
        # e.g. "1.3" -> "Story_1". This is encoding-insensitive: it just
        # mirrors the user-story headings in spec.md.
        story_num = label.split(".")[0]
        story = f"Story_{story_num}"

        states.update([given, then])
        actions.add(action)
        stories.add(story)
        scenarios.append(
            LiftedScenario(
                label=label,
                given_state=given,
                action=action,
                then_state=then,
                covers=covers,
                story=story,
            )
        )

    requirements = [fr.id for fr in parsed.requirements]

    # Also include any User Stories the parser found that have no
    # scenarios in our hardcoded mapping — those are exactly what
    # KPI-G-002 (Story Coverage) is meant to flag.
    for us in parsed.user_stories:
        stories.add(f"Story_{us.number}")

    return LiftResult(
        states=list(states),
        actions=list(actions),
        requirements=requirements,
        stories=list(stories),
        initial_states=_POMODORO_INITIALS,
        scenarios=scenarios,
    )


if __name__ == "__main__":  # quick manual test
    import sys
    from speceval.parser import parse_spec

    parsed = parse_spec(sys.argv[1])
    lift = lift_pomodoro_hardcoded(parsed)
    snap = render_snapshot(
        lift,
        header_comment=(
            "Generated snapshot for the 001-pomo-cli spec.\n"
            "Phase-1 hardcoded mapping (no LLM)."
        ),
    )
    print(snap)

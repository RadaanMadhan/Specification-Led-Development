"""reporter.py — render a human-readable verdict table to the terminal.

Inputs:
  - ParsedSpec    : statistics about the input spec.md
  - LiftResult    : statistics about the lifted Alloy world
  - RunOutcome    : one result per KPI from Alloy

Output:
  - A plain-text bordered table on stdout, with optional ANSI colour.

We intentionally avoid `rich` as a hard dependency so the tool runs
in any Python 3.10+ environment with no extra installs. If `rich` is
available we use it for nicer rendering, otherwise we fall back to
plain ASCII.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass

from speceval.parser import ParsedSpec
from speceval.runner import RunOutcome
from speceval.snapshot import LiftResult


# ---------------------------------------------------------------------------
# Static metadata about each KPI (so the table can show full names + notes)
# ---------------------------------------------------------------------------

KPI_META: dict[str, dict[str, str]] = {
    "KPI_G_001": {
        "name": "Scenario Determinism",
        "description": (
            "No two acceptance scenarios with the same precondition (Given) "
            "and the same action (When) end in different outcomes (Then)."
        ),
    },
    "KPI_G_002": {
        "name": "Story Coverage",
        "description": (
            "Every User Story declared in the spec has at least one "
            "acceptance scenario."
        ),
    },
    "KPI_G_003": {
        "name": "Scenario Uniqueness",
        "description": (
            "No two acceptance scenarios share an identical "
            "(Given, Action, Then) triple."
        ),
    },
}


# ---------------------------------------------------------------------------
# Optional ANSI colour
# ---------------------------------------------------------------------------

def _supports_colour() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    return sys.stdout.isatty()


def _green(s: str) -> str:
    return f"\033[32m{s}\033[0m" if _supports_colour() else s


def _red(s: str) -> str:
    return f"\033[31m{s}\033[0m" if _supports_colour() else s


def _bold(s: str) -> str:
    return f"\033[1m{s}\033[0m" if _supports_colour() else s


def _dim(s: str) -> str:
    return f"\033[2m{s}\033[0m" if _supports_colour() else s


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

@dataclass
class ReportInputs:
    parsed: ParsedSpec
    lift: LiftResult
    outcome: RunOutcome
    spec_path: str


def render_report(r: ReportInputs) -> str:
    """Build the full terminal report as a single string."""
    lines: list[str] = []

    # --- Header ---
    bar = "═" * 70
    lines.append(bar)
    lines.append(_bold("  Specification Evaluation Report"))
    lines.append(f"  spec: {r.spec_path}")
    lines.append(
        f"  feature: {r.parsed.feature_name}"
    )
    lines.append(
        f"  parsed:  {len(r.parsed.user_stories)} stories, "
        f"{len(r.parsed.all_scenarios)} scenarios, "
        f"{len(r.parsed.requirements)} functional requirements"
    )
    lines.append(
        f"  lifted:  {len(r.lift.scenarios)} scenarios, "
        f"{len(r.lift.states)} states, "
        f"{len(r.lift.actions)} actions, "
        f"{len(r.lift.initial_states)} initial states"
    )
    lines.append(bar)
    lines.append("")

    # --- KPI table ---
    by_name = r.outcome.by_name()
    pass_count = sum(1 for cr in r.outcome.results if cr.passed)
    total = len(r.outcome.results)

    col_id = max(len("KPI"), max((len(n) for n in by_name), default=0))
    col_name = max(
        len("Name"),
        max((len(KPI_META.get(n, {}).get("name", n)) for n in by_name), default=0),
    )
    col_verdict = len("VERDICT")

    header = f"  {'KPI':<{col_id}}  {'Name':<{col_name}}  {'Verdict':<{col_verdict}}"
    lines.append(_bold(header))
    lines.append("  " + "─" * (col_id + col_name + col_verdict + 4))

    for kpi_id in ("KPI_G_001", "KPI_G_002", "KPI_G_003"):
        cr = by_name.get(kpi_id)
        meta = KPI_META.get(kpi_id, {})
        name = meta.get("name", kpi_id)
        if cr is None:
            verdict = _dim("MISSING")
        elif cr.passed:
            verdict = _green("✓ PASS ")
        else:
            verdict = _red("✗ FAIL ")
        lines.append(f"  {kpi_id:<{col_id}}  {name:<{col_name}}  {verdict}")

    lines.append("")
    summary = f"  Summary: {pass_count} of {total} KPIs passed."
    if pass_count == total and total > 0:
        lines.append(_green(summary))
    else:
        lines.append(_red(summary))
    lines.append("")

    # --- Failure details ---
    failures = [cr for cr in r.outcome.results if not cr.passed]
    if failures:
        lines.append(_bold("  Failure notes"))
        lines.append("  " + "─" * 50)
        for cr in failures:
            meta = KPI_META.get(cr.name, {})
            name = meta.get("name", cr.name)
            desc = meta.get("description", "")
            lines.append(f"  {cr.name} — {name}")
            lines.append(_dim(f"    {desc}"))
            lines.append(
                "    Alloy reported: "
                + cr.raw_line
            )
            # Hint at what to inspect, when we can guess from the KPI:
            if cr.name == "KPI_G_001":
                lines.append(_dim(
                    "    Hint: two scenarios share the same Given+Action but\n"
                    "          have different Then states (a contradiction in\n"
                    "          the spec). Inspect the snapshot to find them."
                ))
            elif cr.name == "KPI_G_002":
                stories_with_scenarios = {s.story for s in r.lift.scenarios}
                empty_stories = sorted(set(r.lift.stories) - stories_with_scenarios)
                if empty_stories:
                    lines.append(_dim(
                        f"    Stories without any acceptance scenarios: "
                        f"{', '.join(empty_stories)}"
                    ))
            elif cr.name == "KPI_G_003":
                # Find duplicate (given, action, then) triples for the report.
                from collections import Counter
                triples = [
                    (s.given_state, s.action, s.then_state)
                    for s in r.lift.scenarios
                ]
                dup_triples = [t for t, n in Counter(triples).items() if n > 1]
                if dup_triples:
                    pretty = "; ".join(
                        f"({g}, {a}, {t})" for g, a, t in dup_triples
                    )
                    lines.append(_dim(
                        f"    Duplicate (Given, Action, Then) triples: {pretty}"
                    ))
            lines.append("")

    return "\n".join(lines)


def print_report(inputs: ReportInputs) -> None:
    print(render_report(inputs))

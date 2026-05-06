"""speceval.prompts — system + user prompts for the LLM lifter.

Two passes:
  1. EXTRACTION  — read the parsed spec, output canonical Alloy atoms as JSON.
  2. VALIDATION  — fresh-context review of the extraction; flag issues.

Both prompts ask for STRICT JSON output. The lifter parses, validates the
schema, and (if review mode is on) shows a human-readable summary before
running Alloy.
"""

from __future__ import annotations

import json
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from speceval.parser import ParsedSpec


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

EXTRACTION_SYSTEM_PROMPT = """\
You are a formal-specification analyst. Your job is to lift natural-language
acceptance scenarios from a SpecKit spec.md into canonical atoms suitable
for Alloy formal verification.

You MUST follow these rules:

1. Identical or paraphrased prose MUST map to the same atom name. For
   example, "the user has no active session" and "no session is active"
   describe the same logical state and must use one canonical atom name.

2. Semantically distinct prose MUST get different atom names. Do not
   collapse states that are conceptually different (e.g. "timer running"
   vs "timer paused" are different states).

3. Atom identifiers MUST match the regex [A-Za-z][A-Za-z0-9_]+ — no spaces,
   no hyphens, no special characters. Use UpperCamelCase. Examples of
   valid names: NoActiveSession, RunPomoStart, Work25Countdown, FR_001.

4. Functional Requirement IDs MUST be in the form FR-NNN (e.g. FR-001),
   exactly matching the IDs as they appear in the spec.

5. Every Functional Requirement that any scenario plausibly exercises
   should appear in that scenario's "covers" list. Be liberal but not
   reckless — if a scenario tests behaviour described by an FR, include
   the FR.

6. The "initial_states" set should contain states that represent valid
   starting points before any scenario action occurs. Typically these
   include the precondition of the first Priority-1 scenario plus any
   "configuration-time" states (e.g. invocation flag combinations).

7. Each scenario must be assigned to its parent User Story using the
   form "Story_N" where N is the user-story number from the spec.

8. Every User Story declared in the spec must appear in the "stories"
   list, even if no scenario references it. (KPI-G-002 needs to detect
   stories with no scenarios.)

You MUST return ONLY a single JSON object matching this schema. No
prose, no markdown, no commentary outside the JSON:

{
  "states":         [string, ...],          // unique canonical state names
  "actions":        [string, ...],          // unique canonical action names
  "stories":        [string, ...],          // e.g. ["Story_1", "Story_2", ...]
  "initial_states": [string, ...],          // subset of "states"
  "scenarios": [
    {
      "label":  string,                     // e.g. "1.1", "2.3"
      "given":  string,                     // a name from "states"
      "action": string,                     // a name from "actions"
      "then":   string,                     // a name from "states"
      "covers": [string, ...],              // FR IDs in form "FR-NNN"
      "story":  string                      // a name from "stories"
    },
    ...
  ]
}
"""


EXTRACTION_USER_PROMPT_HEADER = """\
Lift the following SpecKit specification into canonical Alloy atoms.
Produce the JSON object now — no other output.
"""


def build_extraction_prompt(parsed: "ParsedSpec") -> str:
    """Render a `ParsedSpec` into the user-prompt body for extraction."""
    lines: list[str] = [EXTRACTION_USER_PROMPT_HEADER, ""]

    lines.append(f"# Feature\n{parsed.feature_name}\n")

    lines.append("# Functional Requirements")
    for fr in parsed.requirements:
        lines.append(f"- {fr.id}: {fr.text}")
    lines.append("")

    lines.append("# User Stories")
    for us in parsed.user_stories:
        lines.append(f"- Story_{us.number} ({us.priority}): {us.title}")
    lines.append("")

    lines.append("# Acceptance Scenarios")
    for sc in parsed.all_scenarios:
        lines.append(f"## Scenario {sc.label} (parent: Story_{sc.story_number})")
        lines.append(f"  Given: {sc.given}")
        lines.append(f"  When:  {sc.when}")
        lines.append(f"  Then:  {sc.then}")
    lines.append("")

    lines.append(
        "# Required output\nReturn the JSON object as specified by the system "
        "prompt. Output ONLY valid JSON; no prose, no code fences."
    )

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

VALIDATION_SYSTEM_PROMPT = """\
You are reviewing a lift from a SpecKit spec.md into canonical Alloy atoms.
Your job is to identify mistakes the extractor may have made.

Look for these specific failure modes:

A. UNDER-MERGING. Two scenario clauses describe the same logical state or
   action but were assigned different atom names. Example: scenario X has
   given="NoActiveSession" and scenario Y has given="SessionInactive" —
   these are the same condition and should share one atom.

B. OVER-MERGING. Two scenario clauses describe different logical states
   or actions but were collapsed into the same atom. Example: scenario X
   has then="SessionRunning" and scenario Y has then="SessionRunning",
   but X's prose was about a fresh session and Y's was about a paused
   session being resumed — these should be different atoms.

C. MISSING COVERAGE. A scenario clearly exercises a Functional
   Requirement, but the FR is missing from the scenario's "covers" list.
   Example: a scenario whose Then is "JsonStatusPrinted" should cover
   the FR that mandates JSON status output.

D. STORY MISASSIGNMENT. A scenario is assigned to the wrong Story_N.

E. INVALID IDENTIFIER. An atom name violates the [A-Za-z][A-Za-z0-9_]+
   regex (contains spaces, hyphens, etc.).

You MUST return ONLY a single JSON object:

{
  "issues": [
    {
      "kind":        "under_merging" | "over_merging" | "missing_coverage"
                   | "story_misassignment" | "invalid_identifier" | "other",
      "scenarios":   [string, ...],         // affected scenario labels
      "atoms":       [string, ...],         // affected atom names
      "description": string                 // one sentence explaining the issue
    },
    ...
  ]
}

If no issues, return {"issues": []}. No prose outside the JSON.
"""


def build_validation_prompt(parsed: "ParsedSpec", extracted: dict) -> str:
    """Render the validation user-prompt body.

    The validator gets the original prose plus the extractor's JSON, and
    is asked whether the mappings look right.
    """
    lines: list[str] = [
        "Review this lift for the failure modes described in the system prompt.",
        "",
        "## Original spec content",
        "",
    ]

    lines.append("### Functional Requirements")
    for fr in parsed.requirements:
        lines.append(f"- {fr.id}: {fr.text}")
    lines.append("")

    lines.append("### User Stories")
    for us in parsed.user_stories:
        lines.append(f"- Story_{us.number} ({us.priority}): {us.title}")
    lines.append("")

    lines.append("### Acceptance Scenarios")
    for sc in parsed.all_scenarios:
        lines.append(f"#### Scenario {sc.label}")
        lines.append(f"Given: {sc.given}")
        lines.append(f"When:  {sc.when}")
        lines.append(f"Then:  {sc.then}")
    lines.append("")

    lines.append("## Extracted atoms")
    lines.append("```json")
    lines.append(json.dumps(extracted, indent=2))
    lines.append("```")
    lines.append("")
    lines.append(
        "Return the issues JSON now. Output ONLY valid JSON; no prose, "
        "no code fences."
    )

    return "\n".join(lines)

"""parser.py — extract structured data from a SpecKit spec.md.

The SpecKit spec template (.specify/templates/spec-template.md) hardcodes
the format `**Given** ..., **When** ..., **Then** ...` for acceptance
scenarios, and `**FR-NNN**: text` for functional requirements. We rely on
those bold markers as anchors.

This module does NO interpretation — it just slices the markdown into
dataclasses. The interpretation step (mapping prose to canonical atom
names) lives in lifter.py.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class FunctionalRequirement:
    """One FR-NNN entry from the spec's Functional Requirements section."""
    id: str          # e.g. "FR-001"
    text: str        # the requirement text after the colon


@dataclass
class AcceptanceScenario:
    """One numbered Given/When/Then triple under a user story."""
    story_number: int        # 1, 2, 3, ...
    scenario_index: int      # 1-based within the story
    given: str               # raw prose after "**Given**"
    when: str                # raw prose after "**When**"
    then: str                # raw prose after "**Then**"

    @property
    def label(self) -> str:
        """Human label like '1.2' meaning Story 1, Scenario 2."""
        return f"{self.story_number}.{self.scenario_index}"


@dataclass
class UserStory:
    number: int
    title: str
    priority: str            # "P1", "P2", ...
    scenarios: list[AcceptanceScenario] = field(default_factory=list)


@dataclass
class ParsedSpec:
    feature_name: str
    requirements: list[FunctionalRequirement]
    user_stories: list[UserStory]

    @property
    def all_scenarios(self) -> list[AcceptanceScenario]:
        return [s for us in self.user_stories for s in us.scenarios]


# ---------------------------------------------------------------------------
# Regexes — anchored on what the SpecKit template guarantees.
# ---------------------------------------------------------------------------

# `# Feature Specification: Pomo CLI — Pomodoro Timer`
RE_FEATURE_NAME = re.compile(
    r"^#\s*Feature Specification:\s*(?P<name>.+?)\s*$",
    re.MULTILINE,
)

# `### User Story 1 - Start a Default Pomodoro Session (Priority: P1)`
RE_USER_STORY = re.compile(
    r"^###\s*User\s+Story\s+(?P<num>\d+)\s*-\s*"
    r"(?P<title>.+?)\s*\(Priority:\s*(?P<prio>P\d+)\)\s*$",
    re.MULTILINE,
)

# `- **FR-014**: System MUST clean up the state file ...`
# FR text may wrap across multiple lines (markdown soft-wrap with leading
# whitespace). Capture greedy-but-bounded: stop at the next FR line, a
# blank line, or a markdown heading.
RE_FUNCTIONAL_REQ = re.compile(
    r"^\s*-\s*\*\*(?P<id>FR-\d+)\*\*:\s*(?P<text>.+?)"
    r"(?=\n\s*-\s*\*\*FR-\d+\*\*|\n\s*\n|\n#{1,6}\s|\Z)",
    re.DOTALL | re.MULTILINE,
)

# A Given/When/Then triple may span multiple lines (markdown soft-wrap with
# leading whitespace). DOTALL lets `.` match newlines so we can capture
# across line breaks. The numbered list prefix (e.g., `1. `) anchors the start.
RE_GWT = re.compile(
    r"\*\*Given\*\*\s*(?P<given>.+?)"
    r",?\s*\*\*When\*\*\s*(?P<when>.+?)"
    r",?\s*\*\*Then\*\*\s*(?P<then>.+?)"
    r"(?=\n\s*\d+\.\s*\*\*Given\*\*|\n\s*\n|\n\s*-{3,}|\n\s*###|\Z)",
    re.DOTALL,
)


def _clean_clause(text: str) -> str:
    """Collapse whitespace and strip trailing punctuation from a clause."""
    text = re.sub(r"\s+", " ", text).strip()
    # Trim a trailing period if it's the final character of the THEN clause.
    return text.rstrip(".")


def parse_spec(path: Path) -> ParsedSpec:
    """Parse a SpecKit-format spec.md into a ParsedSpec dataclass."""
    md = Path(path).read_text(encoding="utf-8")

    # --- Feature name ---
    m = RE_FEATURE_NAME.search(md)
    feature_name = m.group("name") if m else "Unknown"

    # --- Functional requirements ---
    requirements = [
        FunctionalRequirement(id=m.group("id"), text=_clean_clause(m.group("text")))
        for m in RE_FUNCTIONAL_REQ.finditer(md)
    ]

    # --- User stories and their scenarios ---
    stories: list[UserStory] = []
    story_matches = list(RE_USER_STORY.finditer(md))

    for i, m in enumerate(story_matches):
        story_num = int(m.group("num"))
        story_start = m.end()
        story_end = story_matches[i + 1].start() if i + 1 < len(story_matches) else len(md)
        story_block = md[story_start:story_end]

        # Stop scenario search at the next H2/H3 inside the block,
        # in case "Edge Cases" or "Requirements" follows the last story.
        cutoff = re.search(r"^##\s", story_block, re.MULTILINE)
        if cutoff:
            story_block = story_block[: cutoff.start()]

        scenarios = []
        for j, gwt in enumerate(RE_GWT.finditer(story_block), start=1):
            scenarios.append(
                AcceptanceScenario(
                    story_number=story_num,
                    scenario_index=j,
                    given=_clean_clause(gwt.group("given")),
                    when=_clean_clause(gwt.group("when")),
                    then=_clean_clause(gwt.group("then")),
                )
            )

        stories.append(
            UserStory(
                number=story_num,
                title=_clean_clause(m.group("title")),
                priority=m.group("prio"),
                scenarios=scenarios,
            )
        )

    return ParsedSpec(
        feature_name=feature_name,
        requirements=requirements,
        user_stories=stories,
    )


def summarise(parsed: ParsedSpec) -> str:
    """One-line human summary used by the CLI."""
    return (
        f"{parsed.feature_name}: "
        f"{len(parsed.user_stories)} user stories, "
        f"{len(parsed.all_scenarios)} scenarios, "
        f"{len(parsed.requirements)} functional requirements"
    )


if __name__ == "__main__":  # quick manual test
    import sys
    p = parse_spec(Path(sys.argv[1]))
    print(summarise(p))
    for us in p.user_stories:
        print(f"\n[{us.priority}] Story {us.number}: {us.title}")
        for sc in us.scenarios:
            print(f"  {sc.label}  Given: {sc.given[:60]}...")
            print(f"        When:  {sc.when[:60]}...")
            print(f"        Then:  {sc.then[:60]}...")
    print(f"\nFunctional Requirements ({len(p.requirements)}):")
    for fr in p.requirements:
        print(f"  {fr.id}: {fr.text[:80]}")

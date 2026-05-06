"""speceval.lifter — LLM-driven lift from ParsedSpec to LiftResult.

Pipeline:
    1. Cache check (sha256 of spec content)
    2. Extraction LLM call → JSON of canonical atoms
    3. Deterministic schema/identifier validation
    4. Validation LLM call → list of issues (independent context)
    5. Optional human review prompt
    6. Cache write
    7. Return LiftResult

The output type matches `lift_pomodoro_hardcoded`'s, so the rest of the
pipeline (snapshot.py, runner.py, reporter.py) doesn't change.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

from speceval.parser import ParsedSpec
from speceval.prompts import (
    EXTRACTION_SYSTEM_PROMPT,
    VALIDATION_SYSTEM_PROMPT,
    build_extraction_prompt,
    build_validation_prompt,
)
from speceval.providers import Provider
from speceval.snapshot import LiftedScenario, LiftResult


VALID_ALLOY_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


# ---------------------------------------------------------------------------
# Issue and review types
# ---------------------------------------------------------------------------

@dataclass
class ValidationIssue:
    kind: str
    scenarios: list[str] = field(default_factory=list)
    atoms: list[str] = field(default_factory=list)
    description: str = ""


@dataclass
class LiftPackage:
    """Everything the CLI needs to render a review and proceed to Alloy."""
    lift: LiftResult
    extraction_raw: dict
    issues: list[ValidationIssue]
    cache_hit: bool
    spec_hash: str
    model: str


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def lift_with_llm(
    parsed: ParsedSpec,
    *,
    provider: Provider,
    cache_dir: Path,
    use_cache: bool = True,
) -> LiftPackage:
    """Lift a parsed spec via two LLM passes (extract + validate).

    Caching is content-addressed by sha256 of the spec's normalised form,
    so re-running on the same spec is free and stable. Pass `use_cache=False`
    to force a fresh lift.
    """
    spec_hash = _spec_hash(parsed)
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / f"{spec_hash}.json"

    if use_cache and cache_path.exists():
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
        return LiftPackage(
            lift=_lift_from_dict(cached["lift"]),
            extraction_raw=cached.get("extraction_raw", {}),
            issues=[ValidationIssue(**i) for i in cached.get("issues", [])],
            cache_hit=True,
            spec_hash=spec_hash,
            model=cached.get("model", provider.model),
        )

    # --- Extraction ---
    extraction_raw = _call_for_json(
        provider,
        system=EXTRACTION_SYSTEM_PROMPT,
        user=build_extraction_prompt(parsed),
        what="extraction",
    )

    # --- Deterministic schema check ---
    schema_errors = _validate_schema(extraction_raw, parsed)
    if schema_errors:
        raise LiftError(
            "Extraction output failed schema validation:\n  - "
            + "\n  - ".join(schema_errors)
        )

    # --- Validation pass ---
    validation_raw = _call_for_json(
        provider,
        system=VALIDATION_SYSTEM_PROMPT,
        user=build_validation_prompt(parsed, extraction_raw),
        what="validation",
    )
    issues = [
        ValidationIssue(
            kind=str(it.get("kind", "other")),
            scenarios=list(it.get("scenarios", []) or []),
            atoms=list(it.get("atoms", []) or []),
            description=str(it.get("description", "")),
        )
        for it in validation_raw.get("issues", []) or []
    ]

    # --- Build LiftResult ---
    # Pass `parsed` so the lifter can include all declared FRs (covered or
    # not) — that way the snapshot reflects the spec accurately even if a
    # future KPI cares about uncovered FRs.
    lift = _lift_from_dict(extraction_raw, parsed=parsed)

    # --- Cache write ---
    payload = {
        "lift": _lift_to_dict(lift),
        "extraction_raw": extraction_raw,
        "issues": [asdict(i) for i in issues],
        "model": provider.model,
        "spec_hash": spec_hash,
    }
    cache_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    return LiftPackage(
        lift=lift,
        extraction_raw=extraction_raw,
        issues=issues,
        cache_hit=False,
        spec_hash=spec_hash,
        model=provider.model,
    )


# ---------------------------------------------------------------------------
# Human review
# ---------------------------------------------------------------------------

def render_review(pkg: LiftPackage, parsed: ParsedSpec) -> str:
    """Build the human-readable review block printed before Alloy runs."""
    lines: list[str] = []
    lines.append("=" * 70)
    lines.append(f"  LLM lift review  (model: {pkg.model})")
    if pkg.cache_hit:
        lines.append(f"  cached from previous run, sha={pkg.spec_hash[:12]}")
    lines.append("=" * 70)
    lines.append("")

    lift = pkg.lift
    lines.append(f"  States   ({len(lift.states):2d}): {', '.join(lift.states)}")
    lines.append(f"  Actions  ({len(lift.actions):2d}): {', '.join(lift.actions)}")
    lines.append(f"  Stories  ({len(lift.stories):2d}): {', '.join(lift.stories)}")
    lines.append(
        f"  Initial  ({len(lift.initial_states):2d}): "
        f"{', '.join(lift.initial_states)}"
    )
    lines.append("")

    lines.append("  Scenarios:")
    for sc in lift.scenarios:
        cov = ", ".join(sc.covers) if sc.covers else "(no FRs)"
        lines.append(
            f"    {sc.label}  {sc.given_state}  --{sc.action}-->  {sc.then_state}"
            f"   [{sc.story}; covers {cov}]"
        )
    lines.append("")

    if pkg.issues:
        lines.append(f"  Validation: {len(pkg.issues)} issue(s) reported")
        lines.append("  " + "-" * 50)
        for it in pkg.issues:
            lines.append(f"    [{it.kind}] {it.description}")
            if it.scenarios:
                lines.append(f"        scenarios: {', '.join(it.scenarios)}")
            if it.atoms:
                lines.append(f"        atoms:     {', '.join(it.atoms)}")
        lines.append("")
    else:
        lines.append("  Validation: 0 issues found.")
        lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

class LiftError(RuntimeError):
    pass


def _spec_hash(parsed: ParsedSpec) -> str:
    """Stable hash over the parsed structure (resilient to whitespace edits)."""
    payload = {
        "feature": parsed.feature_name,
        "frs": [(fr.id, fr.text) for fr in parsed.requirements],
        "stories": [
            (us.number, us.title, us.priority, [
                (sc.label, sc.given, sc.when, sc.then) for sc in us.scenarios
            ])
            for us in parsed.user_stories
        ],
    }
    blob = json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def _call_for_json(
    provider: Provider, *, system: str, user: str, what: str
) -> dict:
    """Call the model and parse a JSON object from the response.

    Tolerates the model wrapping the JSON in ```json fences. One soft
    retry if the response isn't parseable as JSON.
    """
    raw = provider.complete(system=system, user=user, max_tokens=8000)
    parsed = _parse_json_loose(raw)
    if parsed is None:
        # One retry: ask the model to fix its own output.
        raw2 = provider.complete(
            system=system,
            user=(
                user
                + "\n\nIMPORTANT: your previous reply was not valid JSON. "
                "Return ONLY the JSON object, no prose, no code fences."
            ),
            max_tokens=8000,
        )
        parsed = _parse_json_loose(raw2)
        if parsed is None:
            raise LiftError(
                f"{what} call did not return valid JSON. "
                f"Raw start: {raw[:200]!r}"
            )
    if not isinstance(parsed, dict):
        raise LiftError(f"{what} JSON must be an object, got {type(parsed).__name__}")
    return parsed


def _parse_json_loose(text: str) -> dict | None:
    """Try to parse JSON, with light cleanup for common LLM quirks."""
    text = text.strip()
    if text.startswith("```"):
        # strip ```json ... ``` fences
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```\s*$", "", text)
    # If the model added prose around the JSON, find the outer braces.
    if not text.startswith("{"):
        m = re.search(r"\{.*\}\s*$", text, re.DOTALL)
        if m:
            text = m.group(0)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def _validate_schema(extracted: dict, parsed: ParsedSpec) -> list[str]:
    """Deterministic checks before we accept the LLM output."""
    errors: list[str] = []

    for key in ("states", "actions", "stories", "initial_states", "scenarios"):
        if key not in extracted:
            errors.append(f"missing key: {key}")

    if errors:
        return errors  # don't bother with deeper checks if shape is wrong

    states = set(extracted.get("states", []) or [])
    actions = set(extracted.get("actions", []) or [])
    stories = set(extracted.get("stories", []) or [])
    initial = set(extracted.get("initial_states", []) or [])
    scenarios = extracted.get("scenarios", []) or []

    for s in states | actions | stories:
        if not VALID_ALLOY_ID.match(s):
            errors.append(f"invalid Alloy identifier: {s!r}")

    if not initial.issubset(states):
        errors.append(
            f"initial_states not subset of states: extra={sorted(initial - states)}"
        )

    seen_labels: set[str] = set()
    expected_labels = {sc.label for sc in parsed.all_scenarios}
    for sc in scenarios:
        label = sc.get("label")
        if not isinstance(label, str):
            errors.append(f"scenario missing label: {sc}")
            continue
        seen_labels.add(label)
        for k in ("given", "action", "then", "story"):
            v = sc.get(k)
            if not isinstance(v, str) or not VALID_ALLOY_ID.match(v):
                errors.append(f"scenario {label} has invalid {k}: {v!r}")
        if sc.get("given") not in states:
            errors.append(f"scenario {label} given {sc.get('given')!r} not in states")
        if sc.get("then") not in states:
            errors.append(f"scenario {label} then {sc.get('then')!r} not in states")
        if sc.get("action") not in actions:
            errors.append(f"scenario {label} action {sc.get('action')!r} not in actions")
        if sc.get("story") not in stories:
            errors.append(f"scenario {label} story {sc.get('story')!r} not in stories")
        for fr in sc.get("covers", []) or []:
            if not isinstance(fr, str):
                errors.append(f"scenario {label} covers contains non-string: {fr!r}")

    missing_labels = expected_labels - seen_labels
    if missing_labels:
        errors.append(f"scenarios not lifted: {sorted(missing_labels)}")

    extra_labels = seen_labels - expected_labels
    if extra_labels:
        errors.append(f"unknown scenario labels: {sorted(extra_labels)}")

    return errors


def _lift_from_dict(extracted: dict, *, parsed: ParsedSpec | None = None) -> LiftResult:
    """Convert a validated extraction dict into a LiftResult.

    FR IDs are kept in the user-visible "FR-NNN" form throughout. The
    snapshot renderer (snapshot._alloy_id) converts to "FR_NNN" only
    when emitting the .als file.

    If `parsed` is provided, every FR declared in the spec is included
    in `requirements` (even if no scenario covers it). This lets the
    snapshot reflect the full spec rather than only the covered FRs.
    """
    # Accept both the LLM's field names ("given", "then") and the
    # dataclass-serialised forms ("given_state", "then_state") so cached
    # lifts written via asdict() can be reloaded transparently.
    scenarios = [
        LiftedScenario(
            label=sc["label"],
            given_state=sc.get("given_state") or sc["given"],
            action=sc["action"],
            then_state=sc.get("then_state") or sc["then"],
            covers=list(sc.get("covers") or []),
            story=sc["story"],
        )
        for sc in extracted.get("scenarios", [])
    ]
    if "requirements" in extracted:
        # Cache reload — `requirements` was already canonicalised on first lift.
        requirements = sorted(set(extracted["requirements"]))
    else:
        covered_frs = {fr for sc in scenarios for fr in sc.covers}
        declared_frs = {fr.id for fr in parsed.requirements} if parsed else set()
        requirements = sorted(covered_frs | declared_frs)
    return LiftResult(
        states=list(extracted.get("states", [])),
        actions=list(extracted.get("actions", [])),
        requirements=requirements,
        stories=list(extracted.get("stories", [])),
        initial_states=list(extracted.get("initial_states", [])),
        scenarios=scenarios,
    )


def _lift_to_dict(lift: LiftResult) -> dict:
    return {
        "states": lift.states,
        "actions": lift.actions,
        "requirements": lift.requirements,
        "stories": lift.stories,
        "initial_states": lift.initial_states,
        "scenarios": [asdict(sc) for sc in lift.scenarios],
    }

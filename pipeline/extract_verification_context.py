#!/usr/bin/env python3
"""Extract verification context from a speceval run directory.

Reads the structured output of a speceval run (manifest JSON, Alloy model,
unified report) and produces a single verification_context.md file suitable
for feeding into an LLM code-generation prompt.

Usage:
    python pipeline/extract_verification_context.py <run_dir> [-o <output>]
"""

import argparse
import json
import re
import sys
from pathlib import Path


def load_manifest(run_dir: Path) -> dict:
    manifest_path = run_dir / "feature_model.manifest.json"
    if not manifest_path.exists():
        print(f"ERROR: {manifest_path} not found", file=sys.stderr)
        sys.exit(1)
    with open(manifest_path) as f:
        return json.load(f)


def load_alloy_model(run_dir: Path) -> str:
    als_path = run_dir / "feature_model.als"
    if not als_path.exists():
        return ""
    with open(als_path) as f:
        return f.read()


def load_unified_report(run_dir: Path) -> str:
    report_path = run_dir / "unified_report.md"
    if not report_path.exists():
        return ""
    with open(report_path) as f:
        return f.read()


def extract_named_facts(alloy_text: str) -> list[dict]:
    """Extract named facts with their bodies from the Alloy model."""
    facts = []
    pattern = re.compile(
        r"(//[^\n]*\n)*"  # optional comment lines before fact
        r"fact\s+(F_\w+)\s*\{",
        re.MULTILINE,
    )
    for match in pattern.finditer(alloy_text):
        fact_name = match.group(2)
        # Extract comment lines preceding the fact
        comments = match.group(0).split(f"fact {fact_name}")[0].strip()
        # Find the matching closing brace
        start = match.end()
        depth = 1
        pos = start
        while pos < len(alloy_text) and depth > 0:
            if alloy_text[pos] == "{":
                depth += 1
            elif alloy_text[pos] == "}":
                depth -= 1
            pos += 1
        body = alloy_text[start : pos - 1].strip()
        facts.append(
            {"name": fact_name, "comments": comments, "body": body}
        )
    return facts


def extract_assertions(alloy_text: str) -> list[dict]:
    """Extract assertion declarations from the Alloy model."""
    assertions = []
    pattern = re.compile(
        r"(//[^\n]*\n)*"
        r"assert\s+(\w+)\s*\{",
        re.MULTILINE,
    )
    for match in pattern.finditer(alloy_text):
        name = match.group(2)
        comments = match.group(0).split(f"assert {name}")[0].strip()
        start = match.end()
        depth = 1
        pos = start
        while pos < len(alloy_text) and depth > 0:
            if alloy_text[pos] == "{":
                depth += 1
            elif alloy_text[pos] == "}":
                depth -= 1
            pos += 1
        body = alloy_text[start : pos - 1].strip()
        assertions.append(
            {"name": name, "comments": comments, "body": body}
        )
    return assertions


def render_context(manifest: dict, alloy_text: str, report_text: str) -> str:
    """Render the full verification_context.md."""
    sections = []

    feature_id = manifest.get("feature_id", "unknown")
    sections.append(f"# Verification Context — `{feature_id}`\n")
    sections.append(
        "This document contains the formally verified structural constraints, "
        "FR coverage mapping, mutation test results, and WAF-derived KPI targets "
        "for guiding code generation.\n"
    )

    # Section 1: Structural Patterns
    patterns = manifest.get("patterns_applied", [])
    sections.append("## 1. Structural Patterns\n")
    sections.append(
        f"{len(patterns)} verification patterns applied from the pattern catalogue:\n"
    )
    for p in patterns:
        sections.append(f"- `{p}`")
    sections.append("")

    # Section 2: FR-to-Assertion Map
    fr_map = manifest.get("fr_assertion_map", {})
    sections.append("## 2. FR-to-Assertion Map\n")
    sections.append(
        "Each functional requirement is covered by one or more formally verified assertions.\n"
    )
    sections.append("| FR | Assertions |")
    sections.append("|---|---|")
    for fr, assertions in sorted(fr_map.items()):
        assertion_str = ", ".join(f"`{a}`" for a in assertions)
        sections.append(f"| `{fr}` | {assertion_str} |")
    sections.append("")

    # Section 3: Mutation Results
    mutations = manifest.get("mutation_targets", [])
    sections.append("## 3. Mutation Results\n")
    sections.append(
        f"{len(mutations)} mutation targets tested. Each removes a named fact "
        "and injects a violation to test assertion strength.\n"
    )
    sections.append("| Fact | Asserts Violated | Verdict | Rationale |")
    sections.append("|---|---|---|---|")
    for m in mutations:
        asserts = ", ".join(f"`{a}`" for a in m.get("asserts_violated", []))
        rationale = m.get("rationale", "")
        # Truncate long rationales for readability
        if len(rationale) > 120:
            rationale = rationale[:117] + "..."
        sections.append(
            f"| `{m['fact_name']}` | {asserts} | VACUOUS | {rationale} |"
        )
    sections.append("")
    sections.append(
        "**Injection patterns** (use these to inform hardening):\n"
    )
    for m in mutations:
        sections.append(f"- **{m['fact_name']}**: `{m.get('inject_violation', '')}`")
    sections.append("")

    # Section 4: Invariant Semantics (named facts with body previews)
    named_facts = extract_named_facts(alloy_text)
    sections.append("## 4. Invariant Semantics\n")
    sections.append(
        f"{len(named_facts)} named facts define the structural invariants. "
        "Each must be translated into a runtime check.\n"
    )
    for fact in named_facts:
        sections.append(f"### `{fact['name']}`\n")
        if fact["comments"]:
            sections.append(f"{fact['comments']}\n")
        # Show body as code block
        sections.append("```alloy")
        sections.append(fact["body"])
        sections.append("```\n")

    # Section 5: Feature-Specific Predicates
    predicates = manifest.get("feature_specific_predicates", [])
    sections.append("## 5. Feature-Specific Predicates\n")
    sections.append(
        f"{len(predicates)} feature-specific predicates beyond pattern-derived assertions:\n"
    )
    for p in predicates:
        sections.append(f"- `{p}`")
    sections.append("")

    # Show assertion bodies for these predicates
    assertions = extract_assertions(alloy_text)
    pred_set = set(predicates)
    feature_assertions = [a for a in assertions if a["name"] in pred_set]
    if feature_assertions:
        sections.append("### Assertion Details\n")
        for a in feature_assertions:
            sections.append(f"**`{a['name']}`**")
            if a["comments"]:
                sections.append(f"{a['comments']}")
            sections.append("```alloy")
            sections.append(a["body"])
            sections.append("```\n")

    # Section 6: Full Unified Report
    sections.append("## 6. Full Unified Report\n")
    if report_text:
        sections.append(
            "The complete unified compliance report including Alloy verdicts "
            "and WAF-derived KPI targets:\n"
        )
        sections.append("<details>")
        sections.append("<summary>Click to expand full report</summary>\n")
        sections.append(report_text)
        sections.append("\n</details>")
    else:
        sections.append("*No unified report found.*")
    sections.append("")

    return "\n".join(sections)


def main():
    parser = argparse.ArgumentParser(
        description="Extract verification context from a speceval run directory"
    )
    parser.add_argument(
        "run_dir",
        type=Path,
        help="Path to a speceval run directory (e.g. runs/005-...)",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output path for verification_context.md (default: stdout)",
    )
    args = parser.parse_args()

    run_dir = args.run_dir.resolve()
    if not run_dir.is_dir():
        print(f"ERROR: {run_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    manifest = load_manifest(run_dir)
    alloy_text = load_alloy_model(run_dir)
    report_text = load_unified_report(run_dir)

    context = render_context(manifest, alloy_text, report_text)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, "w") as f:
            f.write(context)
        print(f"Wrote verification context to {args.output}", file=sys.stderr)
    else:
        print(context)


if __name__ == "__main__":
    main()

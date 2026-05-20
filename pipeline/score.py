#!/usr/bin/env python3
"""Automated artifact-counting scorer for guided vs baseline code generation.

Scores two implementations across 6 dimensions by counting concrete artifacts
(pattern comments, FR docstrings, invariant checks, test functions, KPI constants,
security constructs). No LLM needed.

Usage:
    python pipeline/score.py <guided_dir> <baseline_dir> <context_path> [-o <output>]
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path


def find_source_files(directory: Path) -> list[Path]:
    """Find all Python, TypeScript, and JavaScript source files."""
    extensions = {".py", ".ts", ".js", ".tsx", ".jsx"}
    files = []
    for root, _dirs, filenames in os.walk(directory):
        for f in filenames:
            path = Path(root) / f
            if path.suffix in extensions:
                files.append(path)
    return files


def find_test_files(directory: Path) -> list[Path]:
    """Find test files by convention."""
    test_files = []
    for root, _dirs, filenames in os.walk(directory):
        for f in filenames:
            path = Path(root) / f
            if path.suffix in {".py", ".ts", ".js"} and (
                f.startswith("test_") or f.endswith("_test.py") or f.endswith(".test.ts")
                or f.endswith(".test.js") or f.endswith(".spec.ts") or f.endswith(".spec.js")
            ):
                test_files.append(path)
    return test_files


def read_all_source(directory: Path) -> str:
    """Concatenate all source file contents."""
    files = find_source_files(directory)
    parts = []
    for f in files:
        try:
            parts.append(f.read_text(errors="replace"))
        except OSError:
            continue
    return "\n".join(parts)


def _extract_section(text: str, heading: str) -> str:
    """Extract text between a ## heading and the next ## heading."""
    pattern = re.compile(
        rf"^## {re.escape(heading)}\s*\n(.*?)(?=^## |\Z)",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(text)
    return m.group(1) if m else ""


def load_context(context_path: Path) -> dict:
    """Parse verification_context.md to extract expected artifacts."""
    text = context_path.read_text()

    # Extract patterns from Section 1 only
    sec1 = _extract_section(text, "1. Structural Patterns")
    patterns = re.findall(r"^- `(\w+)`", sec1, re.MULTILINE)

    # Extract FR keys from Section 2
    frs = re.findall(r"\| `(FR-\d+)` \|", text)

    # Extract mutation fact names from Section 3
    mutations = re.findall(r"\| `(F_\w+)` \|", text)

    # Extract feature-specific predicates from Section 5 only
    sec5 = _extract_section(text, "5. Feature-Specific Predicates")
    predicates = re.findall(r"^- `(\w+)`", sec5, re.MULTILINE)

    # Extract named facts from Section 4
    facts = re.findall(r"### `(F_\w+)`", text)

    return {
        "patterns": list(dict.fromkeys(patterns)),  # dedupe, preserve order
        "frs": list(dict.fromkeys(frs)),
        "mutations": list(dict.fromkeys(mutations)),
        "predicates": list(dict.fromkeys(predicates)),
        "facts": list(dict.fromkeys(facts)),
    }


def score_structural_completeness(source: str, expected_patterns: list[str]) -> dict:
    """Score: count // PATTERN: comments vs expected patterns."""
    found = set()
    for match in re.finditer(r"#\s*PATTERN:\s*(\w+)|//\s*PATTERN:\s*(\w+)", source):
        name = match.group(1) or match.group(2)
        found.add(name)

    matched = found & set(expected_patterns)
    total = len(expected_patterns) if expected_patterns else 1
    score = min(10.0, (len(matched) / total) * 10)

    return {
        "score": round(score, 1),
        "found": sorted(found),
        "expected": expected_patterns,
        "matched": sorted(matched),
        "coverage": f"{len(matched)}/{total}",
    }


def score_fr_coverage(source: str, expected_frs: list[str]) -> dict:
    """Score: count 'Implements FR-NNN' docstrings."""
    found = set()
    for match in re.finditer(r"Implements\s+(FR-\d+)", source, re.IGNORECASE):
        found.add(match.group(1))

    # Also check for FR-NNN in comments/docstrings as fallback
    for match in re.finditer(r"(?:#|//|\"\"\"|\*)\s*.*?(FR-\d+)", source):
        found.add(match.group(1))

    matched = found & set(expected_frs)
    total = len(expected_frs) if expected_frs else 1
    score = min(10.0, (len(matched) / total) * 10)

    return {
        "score": round(score, 1),
        "found": sorted(found),
        "expected": expected_frs,
        "matched": sorted(matched),
        "coverage": f"{len(matched)}/{total}",
    }


def score_invariant_enforcement(source: str, expected_facts: list[str]) -> dict:
    """Score: grep for runtime checks matching named facts."""
    found = set()

    for fact in expected_facts:
        # Strip F_ prefix for matching
        short_name = fact.replace("F_", "")
        # Look for the fact name in various forms
        patterns = [
            re.escape(fact),
            re.escape(short_name),
            # camelCase version
            re.escape(short_name[0].lower() + short_name[1:]) if short_name else "",
            # snake_case version
            re.escape(re.sub(r"(?<=[a-z])(?=[A-Z])", "_", short_name).lower()),
        ]
        for p in patterns:
            if p and re.search(p, source, re.IGNORECASE):
                found.add(fact)
                break

    # Also look for HARDENED comments
    hardened = set()
    for match in re.finditer(r"#\s*HARDENED:\s*(F_\w+)|//\s*HARDENED:\s*(F_\w+)", source):
        name = match.group(1) or match.group(2)
        hardened.add(name)
        found.add(name)

    total = len(expected_facts) if expected_facts else 1
    score = min(10.0, (len(found) / total) * 10)

    return {
        "score": round(score, 1),
        "found": sorted(found),
        "hardened": sorted(hardened),
        "expected": expected_facts,
        "coverage": f"{len(found)}/{total}",
    }


def score_test_quality(directory: Path) -> dict:
    """Score: count test files/functions, categorize by naming convention."""
    test_files = find_test_files(directory)
    source = ""
    for f in test_files:
        try:
            source += f.read_text(errors="replace") + "\n"
        except OSError:
            continue

    # Count test functions by category
    assertion_tests = re.findall(r"def\s+test_assertion_\w+|it\(['\"].*assertion", source)
    mutation_tests = re.findall(r"def\s+test_mutation_\w+|it\(['\"].*mutation", source)
    kpi_tests = re.findall(r"def\s+test_kpi_\w+|it\(['\"].*kpi", source, re.IGNORECASE)
    fr_tests = re.findall(r"def\s+test_fr_\d+\w*|it\(['\"].*FR-\d+", source)

    # Count all test functions
    all_tests = re.findall(
        r"def\s+test_\w+|it\(['\"]|test\(['\"]|describe\(['\"]", source
    )

    total_tests = len(all_tests)
    categorized = len(assertion_tests) + len(mutation_tests) + len(kpi_tests) + len(fr_tests)

    # Score: base on total test count + bonus for categorization
    base_score = min(5.0, total_tests / 4)  # up to 5 points for having tests
    category_score = min(5.0, categorized / 3)  # up to 5 points for categorized tests
    score = min(10.0, base_score + category_score)

    return {
        "score": round(score, 1),
        "total_test_files": len(test_files),
        "total_test_functions": total_tests,
        "assertion_tests": len(assertion_tests),
        "mutation_tests": len(mutation_tests),
        "kpi_tests": len(kpi_tests),
        "fr_tests": len(fr_tests),
    }


def score_kpi_instrumentation(source: str) -> dict:
    """Score: count METRIC_* constants and threshold definitions."""
    metric_constants = re.findall(r"METRIC_\w+", source)
    threshold_defs = re.findall(
        r"(?:threshold|THRESHOLD|target|TARGET)[\w_]*\s*=\s*[\d.]+", source
    )
    # Also check for KPI-related comments
    kpi_comments = re.findall(r"#.*KPI|//.*KPI|#.*metric|//.*metric", source, re.IGNORECASE)

    total_items = len(set(metric_constants)) + len(threshold_defs)
    score = min(10.0, total_items / 2)

    return {
        "score": round(score, 1),
        "metric_constants": sorted(set(metric_constants)),
        "threshold_definitions": len(threshold_defs),
        "kpi_comments": len(kpi_comments),
    }


def score_security_posture(source: str) -> dict:
    """Score: checklist of security constructs."""
    checks = {
        "auth_middleware": bool(re.search(
            r"auth.*middleware|authenticate|@login_required|@require_auth|verify_token|jwt.*verify",
            source, re.IGNORECASE,
        )),
        "input_validation": bool(re.search(
            r"validate|validator|pydantic|schema.*valid|sanitize|clean_input",
            source, re.IGNORECASE,
        )),
        "ownership_check": bool(re.search(
            r"owner|belongs_to|authorized.*access|check_permission|check_ownership",
            source, re.IGNORECASE,
        )),
        "rate_limiting": bool(re.search(
            r"rate.?limit|throttle|velocity|daily.?limit",
            source, re.IGNORECASE,
        )),
        "error_handling": bool(re.search(
            r"try.*except|catch\s*\(|error.*handler|raise\s+\w+Error",
            source, re.IGNORECASE,
        )),
        "no_info_leakage": bool(re.search(
            r"404|not.?found|generic.*error|same.*response|indistinguishable",
            source, re.IGNORECASE,
        )),
    }

    found = sum(1 for v in checks.values() if v)
    total = len(checks)
    score = round((found / total) * 10, 1)

    return {
        "score": score,
        "checks": checks,
        "found": f"{found}/{total}",
    }


def score_directory(directory: Path, context: dict) -> dict:
    """Score a single implementation directory."""
    source = read_all_source(directory)

    structural = score_structural_completeness(source, context["patterns"])
    fr = score_fr_coverage(source, context["frs"])
    invariant = score_invariant_enforcement(source, context["facts"])
    tests = score_test_quality(directory)
    kpi = score_kpi_instrumentation(source)
    security = score_security_posture(source)

    return {
        "structural_completeness": structural,
        "fr_coverage": fr,
        "invariant_enforcement": invariant,
        "test_quality": tests,
        "kpi_instrumentation": kpi,
        "security_posture": security,
    }


def compute_weighted_total(scores: dict) -> float:
    """Compute weighted total from dimension scores."""
    weights = {
        "structural_completeness": 0.25,
        "fr_coverage": 0.25,
        "invariant_enforcement": 0.20,
        "test_quality": 0.15,
        "kpi_instrumentation": 0.10,
        "security_posture": 0.05,
    }
    total = 0.0
    for dim, weight in weights.items():
        total += scores[dim]["score"] * weight
    return round(total, 2)


def main():
    parser = argparse.ArgumentParser(
        description="Score guided vs baseline code generation artifacts"
    )
    parser.add_argument("guided_dir", type=Path, help="Path to guided track output")
    parser.add_argument("baseline_dir", type=Path, help="Path to baseline track output")
    parser.add_argument("context_path", type=Path, help="Path to verification_context.md")
    parser.add_argument(
        "-o", "--output", type=Path, default=None,
        help="Output path for scores.json (default: stdout)",
    )
    args = parser.parse_args()

    if not args.context_path.exists():
        print(f"ERROR: {args.context_path} not found", file=sys.stderr)
        sys.exit(1)

    context = load_context(args.context_path)

    guided_scores = score_directory(args.guided_dir, context)
    baseline_scores = score_directory(args.baseline_dir, context)

    guided_total = compute_weighted_total(guided_scores)
    baseline_total = compute_weighted_total(baseline_scores)

    if guided_total > baseline_total + 0.5:
        verdict = "GUIDED_WINS"
    elif baseline_total > guided_total + 0.5:
        verdict = "BASELINE_WINS"
    else:
        verdict = "TIE"

    dimension_names = {
        "structural_completeness": "Structural Completeness",
        "fr_coverage": "FR Coverage",
        "invariant_enforcement": "Invariant Enforcement",
        "test_quality": "Test Quality",
        "kpi_instrumentation": "KPI Instrumentation",
        "security_posture": "Security Posture",
    }

    weights = {
        "structural_completeness": 25,
        "fr_coverage": 25,
        "invariant_enforcement": 20,
        "test_quality": 15,
        "kpi_instrumentation": 10,
        "security_posture": 5,
    }

    output = {
        "dimensions": [
            {
                "name": dimension_names[dim],
                "key": dim,
                "weight": weights[dim],
                "guided_score": guided_scores[dim]["score"],
                "baseline_score": baseline_scores[dim]["score"],
                "guided_detail": guided_scores[dim],
                "baseline_detail": baseline_scores[dim],
            }
            for dim in dimension_names
        ],
        "guided_total": guided_total,
        "baseline_total": baseline_total,
        "verdict": verdict,
        "context_summary": {
            "patterns_expected": len(context["patterns"]),
            "frs_expected": len(context["frs"]),
            "mutations_expected": len(context["mutations"]),
            "facts_expected": len(context["facts"]),
        },
    }

    result_json = json.dumps(output, indent=2)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, "w") as f:
            f.write(result_json)
        print(f"Scores written to {args.output}", file=sys.stderr)
    else:
        print(result_json)


if __name__ == "__main__":
    main()

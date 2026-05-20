"""eval/scorer.py — per-run AQS scorer (E3).

Reads the 6 artefacts written by `run_experiment.py` (E2) for a single run
plus the source cell's `eval/specs/<cell>/spec.md` plus the project-root
`patterns.md`, computes D1–D4 of the AQS rubric per EVALUATION_PLAN.md §3.1,
and writes `scores.json` next to the other artefacts.

This scorer is **fully deterministic and offline** — no API calls — so the
whole 90-run dataset can be re-scored from disk in seconds.

Dimensions (see EVALUATION_PLAN.md §3.1 for the canonical definitions):

- **D1 — Compilability.** 1.0 iff `alloy_verdicts.json` is non-empty AND the
  .als declares ≥ 1 `assert`. 0.5 if the .als parses but declares 0
  assertions. 0.0 otherwise (PARSE_FAIL).
- **D2 — Pattern grounding.** Per pattern name in `manifest.patterns_applied`:
  1.0 if the name is in `patterns.md` AND a `pred <Name>` declaration is in
  the .als; 0.5 if only one of those holds; 0.0 if the name is not in
  `patterns.md`. D2 = mean over declared patterns. If `patterns_applied` is
  empty, D2 = 0.0 (no grounding to assess).
- **D3 — Mutation discrimination.** Per `mutation_targets` entry in
  `mutation_outcomes.json`: 1.0 if all targeted assertions BIT, 0.0 if any
  one is VACUOUS_TAUTOLOGY, else 0.5. D3 = mean over targets. Skipped
  targets (`skipped: true`, e.g. fact-not-found) are excluded from the
  mean; if all targets are skipped or no targets exist, D3 = 0.0.
- **D4 — FR coverage + verdict.** Per FR in `spec.md`: 1.0 if it has ≥ 1
  matching assertion AND ≥ 1 of those PASSes; 0.5 if it has matching
  assertions but all FAIL; 0.0 if uncovered. D4 = mean over FRs.

`aqs_partial = mean(D1, D2, D3, D4)`.

**D5 (cross-replicate stability) is intentionally NOT computed here** — it
is a per-cell aggregate over all 10 replicates and lives in
`eval/aggregate.py` (E4).

CLI:

    python eval/scorer.py <run_dir>          # score one run
    python eval/scorer.py eval/runs/         # walk tree, skip already-scored

Skip-on-existing-scores.json semantics: a run is considered "scored" iff
`scores.json` is present and parseable. The walker skips those and scores
the rest. Per-run errors are caught so the walk doesn't abort.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean
from typing import Any

# The scorer reuses the speceval helpers rather than re-implementing parsing.
# Importing this way assumes the project root is on PYTHONPATH; the .command
# launcher does `cd <repo root>` so `python eval/scorer.py …` works.
HERE = Path(__file__).resolve().parent          # …/eval
REPO_ROOT = HERE.parent                          # …/spec-led-eval
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from speceval.lifter_design import (             # noqa: E402  — late import
    extract_anchors,
    fr_coverage,
    list_assertions,
    parse_mutation_targets,
)
from speceval.parser import parse_spec           # noqa: E402  — late import


# ---------------------------------------------------------------------------
# Path discovery
# ---------------------------------------------------------------------------

# Runs are laid out as `<eval_root>/runs/<cell>/<model>/run_NN/`.
# `run_NN` matches \d{2,} so two-digit replicate numbers are typical but the
# scorer accepts wider widths.
_RE_RUN_NN = re.compile(r"^run_(?P<rep>\d+)$")


def _discover_run_layout(run_dir: Path) -> tuple[str, str, int, Path]:
    """Return (cell, model, rep, eval_root) inferred from a run_dir path.

    Layout: `<eval_root>/runs/<cell>/<model>/run_NN/`.
    """
    run_dir = run_dir.resolve()
    m = _RE_RUN_NN.match(run_dir.name)
    if not m:
        raise ScorerError(
            f"run_dir name {run_dir.name!r} does not match run_NN pattern"
        )
    rep = int(m.group("rep"))
    model_dir = run_dir.parent
    cell_dir = model_dir.parent
    runs_dir = cell_dir.parent
    if runs_dir.name != "runs":
        raise ScorerError(
            f"run_dir layout unexpected: {run_dir} (expected …/runs/<cell>/<model>/run_NN/)"
        )
    eval_root = runs_dir.parent
    return cell_dir.name, model_dir.name, rep, eval_root


def _patterns_md_path(eval_root: Path) -> Path:
    """`patterns.md` lives at the repository root, one level above eval/."""
    return eval_root.parent / "patterns.md"


def _spec_md_path(eval_root: Path, cell: str) -> Path:
    return eval_root / "specs" / cell / "spec.md"


# ---------------------------------------------------------------------------
# patterns.md ingest
# ---------------------------------------------------------------------------

# Each pattern in patterns.md starts with `### <Name>` (see the catalogue).
# `_render_design_report` in cli.py treats names case-sensitively; we follow
# that.
_RE_PATTERN_HEADING = re.compile(r"^###\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*$",
                                 re.MULTILINE)


def load_pattern_names(patterns_md_path: Path) -> set[str]:
    """Return the set of `### <Name>` headings in patterns.md."""
    if not patterns_md_path.exists():
        raise ScorerError(f"patterns.md not found at {patterns_md_path}")
    text = patterns_md_path.read_text(encoding="utf-8")
    return {m.group("name") for m in _RE_PATTERN_HEADING.finditer(text)}


# `pred <Name>` declaration detector, mirrors lifter_design._RE_ASSERTION but
# for `pred` blocks.
_RE_PRED = re.compile(
    r"\bpred\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b\s*\{",
    re.MULTILINE,
)


def list_predicates(als_text: str) -> set[str]:
    """Return the set of `pred <Name>` declarations in `als_text`."""
    return {m.group("name") for m in _RE_PRED.finditer(als_text)}


# ---------------------------------------------------------------------------
# Dimension computations
# ---------------------------------------------------------------------------

class ScorerError(RuntimeError):
    """Raised for missing artefacts or malformed inputs."""


def compute_d1(als_text: str, verdicts: dict[str, str]) -> tuple[float, dict]:
    """D1 — compilability.

    Score: 1.0 if verdicts non-empty AND assertions ≥ 1; 0.5 if .als parses
    but 0 assertions; 0.0 otherwise (PARSE_FAIL or no als text).
    """
    assertions = list_assertions(als_text) if als_text else []
    n_assert = len(assertions)
    n_verdicts = len(verdicts or {})

    if n_verdicts >= 1 and n_assert >= 1:
        score = 1.0
    elif n_assert == 0 and als_text.strip():
        # .als parses (we have *some* file text) but no assertions declared.
        # We treat a non-empty file as "parses" for this dimension — the
        # canonical "Alloy errored out" path produces an empty
        # alloy_verdicts.json AND typically a missing/incomplete .als.
        score = 0.5
    else:
        score = 0.0

    return score, {
        "n_assertions": n_assert,
        "n_verdicts": n_verdicts,
    }


def compute_d2(
    manifest: dict,
    als_text: str,
    pattern_catalog: set[str],
) -> tuple[float, dict]:
    """D2 — pattern grounding.

    Mean over `manifest.patterns_applied`: 1.0 if the pattern is in the
    catalog AND a matching `pred` declaration exists; 0.5 if exactly one of
    those holds; 0.0 if the pattern name is not in the catalog at all
    (hallucination).

    If `patterns_applied` is empty, returns 0.0 (no grounding can be
    assessed — degenerate case).
    """
    declared: list[str] = list(manifest.get("patterns_applied") or [])
    predicates = list_predicates(als_text) if als_text else set()

    if not declared:
        return 0.0, {
            "patterns_applied": [],
            "per_pattern": {},
            "note": "patterns_applied is empty",
        }

    per_pattern: dict[str, dict[str, Any]] = {}
    scores: list[float] = []
    for name in declared:
        in_catalog = name in pattern_catalog
        has_pred = name in predicates
        if not in_catalog:
            # Hallucinated — full 0.0 regardless of whether there's a stub
            # `pred <Name>` in the .als.
            s = 0.0
        elif in_catalog and has_pred:
            s = 1.0
        else:
            # in_catalog XOR has_pred (only one side true).
            s = 0.5
        scores.append(s)
        per_pattern[name] = {
            "in_catalog": in_catalog,
            "has_pred": has_pred,
            "score": s,
        }

    return mean(scores), {
        "patterns_applied": declared,
        "per_pattern": per_pattern,
    }


def compute_d3(mutation_outcomes: dict) -> tuple[float, dict]:
    """D3 — mutation discrimination.

    Per `mutation_targets` entry (one per `fact_name`):

    - 1.0 if all assertions in `targeted_asserts` are BIT
    - 0.0 if any assertion is VACUOUS_TAUTOLOGY
    - 0.5 if at least one is VACUOUS_OVERCONSTRAINT but none are
      VACUOUS_TAUTOLOGY

    Skipped targets (`skipped: true`, e.g. fact-not-found in the .als) are
    excluded from the mean.

    Mean is taken over the surviving (non-skipped) targets. If every target
    is skipped or no targets exist at all, returns 0.0.
    """
    if not isinstance(mutation_outcomes, dict):
        mutation_outcomes = {}

    per_target: dict[str, dict[str, Any]] = {}
    target_scores: list[float] = []
    skipped: list[str] = []

    for fact_name, body in mutation_outcomes.items():
        if not isinstance(body, dict):
            continue
        if body.get("skipped"):
            skipped.append(fact_name)
            per_target[fact_name] = {
                "skipped": True,
                "skip_reason": body.get("skip_reason"),
                "score": None,
            }
            continue
        verdicts: dict[str, str] = dict(body.get("targeted_asserts") or {})
        if not verdicts:
            # No targeted assertions resolved → treat as a degenerate target.
            # Score 0.0 (the discrimination probe produced no signal).
            per_target[fact_name] = {
                "targeted_asserts": {},
                "score": 0.0,
            }
            target_scores.append(0.0)
            continue
        values = set(verdicts.values())
        if "VACUOUS_TAUTOLOGY" in values:
            score = 0.0
        elif values == {"BIT"}:
            score = 1.0
        else:
            # Contains at least one VACUOUS_OVERCONSTRAINT (and no tautology).
            score = 0.5
        per_target[fact_name] = {
            "targeted_asserts": verdicts,
            "score": score,
        }
        target_scores.append(score)

    if not target_scores:
        return 0.0, {
            "per_target": per_target,
            "skipped": skipped,
            "note": (
                "no scoreable mutation targets"
                if not mutation_outcomes
                else "all mutation targets skipped"
            ),
        }
    return mean(target_scores), {
        "per_target": per_target,
        "skipped": skipped,
    }


def compute_d4(
    fr_ids: list[str],
    manifest: dict,
    als_text: str,
    verdicts: dict[str, str],
) -> tuple[float, dict]:
    """D4 — FR coverage + verdict.

    Per FR (from `spec.md`):

    - 1.0 if there is ≥ 1 matching assertion AND ≥ 1 of those PASSes
    - 0.5 if there are matching assertions but all FAIL
    - 0.0 if there is no matching assertion (uncovered)

    Uses `fr_coverage(...)` from `speceval.lifter_design` (no re-
    implementation).
    """
    assertions = list_assertions(als_text) if als_text else []
    coverage = fr_coverage(fr_ids, manifest or {}, assertions)

    per_fr: dict[str, dict[str, Any]] = {}
    fr_scores: list[float] = []
    if not fr_ids:
        return 0.0, {
            "per_fr": {},
            "note": "no FRs declared in spec.md",
        }

    for fr in fr_ids:
        covers = coverage.get(fr) or []
        if not covers:
            s = 0.0
            verdict_summary = {}
        else:
            verdict_summary = {a: verdicts.get(a, "MISSING") for a in covers}
            if any(v == "PASS" for v in verdict_summary.values()):
                s = 1.0
            else:
                s = 0.5
        per_fr[fr] = {
            "covers": covers,
            "verdicts": verdict_summary,
            "score": s,
        }
        fr_scores.append(s)

    return mean(fr_scores), {
        "per_fr": per_fr,
    }


# ---------------------------------------------------------------------------
# Per-run scoring
# ---------------------------------------------------------------------------

# The three "run is complete" artefacts (same as run_experiment.py's
# is_run_complete check, plus alloy_verdicts.json / mutation_outcomes.json
# which the scorer also needs but which may be absent on PARSE_FAIL runs).
_REQUIRED_FOR_SCORING = (
    "feature_model.als",
    "feature_model.manifest.json",
    "cost_log.json",
)


def is_run_scoreable(run_dir: Path) -> bool:
    """A run is scoreable iff the 3 'complete' artefacts are on disk.

    Note that `alloy_verdicts.json` and `mutation_outcomes.json` may be
    absent on PARSE_FAIL runs — those are still valid D1=0 data points, so
    we score them rather than skip them.
    """
    return all((run_dir / name).exists() for name in _REQUIRED_FOR_SCORING)


def score_run(run_dir: Path) -> dict:
    """Score a single `run_NN/` directory and return the scores.json dict.

    Reads:
      - run_dir/feature_model.als
      - run_dir/feature_model.manifest.json
      - run_dir/alloy_verdicts.json (optional; missing → D1=0)
      - run_dir/mutation_outcomes.json (optional; missing/empty → D3=0)
      - <eval_root>/specs/<cell>/spec.md
      - <repo_root>/patterns.md

    Does NOT write to disk. The caller is responsible for persisting via
    `write_scores(run_dir, scores)`.
    """
    run_dir = run_dir.resolve()
    cell, model, rep, eval_root = _discover_run_layout(run_dir)

    if not is_run_scoreable(run_dir):
        missing = [
            n for n in _REQUIRED_FOR_SCORING if not (run_dir / n).exists()
        ]
        raise ScorerError(
            f"run_dir {run_dir} missing required artefacts: {missing}"
        )

    # --- Read artefacts -----------------------------------------------------
    als_text = (run_dir / "feature_model.als").read_text(encoding="utf-8")
    manifest = json.loads(
        (run_dir / "feature_model.manifest.json").read_text(encoding="utf-8")
    )

    verdicts_path = run_dir / "alloy_verdicts.json"
    if verdicts_path.exists():
        try:
            verdicts = json.loads(verdicts_path.read_text(encoding="utf-8"))
            if not isinstance(verdicts, dict):
                verdicts = {}
        except json.JSONDecodeError:
            verdicts = {}
    else:
        verdicts = {}

    mut_path = run_dir / "mutation_outcomes.json"
    if mut_path.exists():
        try:
            mutation_outcomes = json.loads(
                mut_path.read_text(encoding="utf-8")
            )
            if not isinstance(mutation_outcomes, dict):
                mutation_outcomes = {}
        except json.JSONDecodeError:
            mutation_outcomes = {}
    else:
        mutation_outcomes = {}

    # --- Read source-cell artefacts ----------------------------------------
    spec_path = _spec_md_path(eval_root, cell)
    if not spec_path.exists():
        raise ScorerError(f"spec.md not found at {spec_path} (cell={cell})")
    parsed = parse_spec(spec_path)
    fr_ids = [fr.id for fr in parsed.requirements]

    pattern_catalog = load_pattern_names(_patterns_md_path(eval_root))

    # --- Compute dimensions ------------------------------------------------
    d1, d1_details = compute_d1(als_text, verdicts)
    d2, d2_details = compute_d2(manifest, als_text, pattern_catalog)
    d3, d3_details = compute_d3(mutation_outcomes)
    d4, d4_details = compute_d4(fr_ids, manifest, als_text, verdicts)
    aqs_partial = mean([d1, d2, d3, d4])

    scores = {
        "run_id": f"{cell}/{model}/run_{rep:02d}",
        "cell": cell,
        "model": model,
        "rep": rep,
        "D1": d1,
        "D2": d2,
        "D3": d3,
        "D4": d4,
        "aqs_partial": aqs_partial,
        "scored_at": datetime.now(timezone.utc).isoformat(),
        "details": {
            "D1": d1_details,
            "D2": d2_details,
            "D3": d3_details,
            "D4": d4_details,
        },
    }
    return scores


def write_scores(run_dir: Path, scores: dict) -> Path:
    """Write `scores.json` to `run_dir`."""
    out_path = run_dir / "scores.json"
    out_path.write_text(json.dumps(scores, indent=2), encoding="utf-8")
    return out_path


# ---------------------------------------------------------------------------
# Tree walking
# ---------------------------------------------------------------------------

def iter_run_dirs(runs_root: Path) -> list[Path]:
    """Walk `<runs_root>/<cell>/<model>/run_NN/` and return all run dirs."""
    out: list[Path] = []
    if not runs_root.is_dir():
        return out
    for cell_dir in sorted(p for p in runs_root.iterdir() if p.is_dir()):
        for model_dir in sorted(p for p in cell_dir.iterdir() if p.is_dir()):
            for run_dir in sorted(p for p in model_dir.iterdir() if p.is_dir()):
                if _RE_RUN_NN.match(run_dir.name):
                    out.append(run_dir)
    return out


def score_tree(runs_root: Path, *, force: bool = False) -> dict:
    """Score every run under `runs_root` that's missing `scores.json`.

    Returns a summary dict: {scored, skipped, errored, errors}.
    Per-run errors do not abort the walk; they're recorded in `errors`.
    """
    runs_root = runs_root.resolve()
    summary: dict[str, Any] = {
        "scored": 0,
        "skipped": 0,
        "errored": 0,
        "errors": [],
    }
    for run_dir in iter_run_dirs(runs_root):
        scores_path = run_dir / "scores.json"
        if scores_path.exists() and not force:
            summary["skipped"] += 1
            continue
        if not is_run_scoreable(run_dir):
            summary["errored"] += 1
            summary["errors"].append({
                "run_dir": str(run_dir),
                "reason": "missing required artefacts",
            })
            continue
        try:
            scores = score_run(run_dir)
            write_scores(run_dir, scores)
            summary["scored"] += 1
        except Exception as e:  # pylint: disable=broad-except
            summary["errored"] += 1
            summary["errors"].append({
                "run_dir": str(run_dir),
                "reason": f"{type(e).__name__}: {e}",
                "traceback": traceback.format_exc(),
            })
    return summary


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _print_summary(summary: dict) -> None:
    print(
        f"scored={summary['scored']}  "
        f"skipped={summary['skipped']}  "
        f"errored={summary['errored']}"
    )
    for err in summary.get("errors", []):
        print(f"  [error] {err['run_dir']}: {err['reason']}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="eval/scorer.py",
        description=(
            "Compute AQS dimensions D1–D4 for one run, or walk a tree of "
            "run directories and score every run missing scores.json."
        ),
    )
    ap.add_argument(
        "path",
        type=Path,
        help=(
            "Either a single run_NN/ directory or an eval/runs/ root to walk."
        ),
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Re-score runs that already have a scores.json.",
    )
    args = ap.parse_args(argv)

    target = args.path.resolve()
    if not target.exists():
        print(f"error: path does not exist: {target}", file=sys.stderr)
        return 2

    # Single-run mode iff the directory name matches run_NN/.
    if _RE_RUN_NN.match(target.name):
        scores_path = target / "scores.json"
        if scores_path.exists() and not args.force:
            print(
                f"[skip] {target} — scores.json already exists "
                "(use --force to overwrite)"
            )
            return 0
        try:
            scores = score_run(target)
        except ScorerError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        write_scores(target, scores)
        print(json.dumps(scores, indent=2))
        print(f"[write]   {scores_path}")
        return 0

    # Tree mode.
    summary = score_tree(target, force=args.force)
    _print_summary(summary)
    return 0 if summary["errored"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

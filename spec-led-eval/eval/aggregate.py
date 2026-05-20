"""eval/aggregate.py — Stage-1 aggregator (E4).

Walks every `<eval_root>/runs/<cell>/<model>/run_NN/scores.json` produced
by `eval/scorer.py` (E3), computes the cross-replicate D5 stability
dimension per (cell, model) group as defined in EVALUATION_PLAN.md §3.1
D5, and writes two CSVs:

    eval/results/all_scores.csv      — one row per (cell, model, rep)
    eval/results/cell_summary.csv    — one row per (cell, model)

Both CSVs are written with the stdlib `csv` module — no pandas
dependency. Numeric columns use plain floats. Empty cells (e.g. D5
undefined because too few replicates) are written as the empty string.

D5 algorithm (per EVALUATION_PLAN.md §3.1 D5):

1. For each replicate in a (cell, model) group, normalise every
   assertion name to a key:
   - if the name is in that replicate's `manifest.patterns_applied`,
     key = pattern name (e.g. `LeastPrivilege`);
   - elif the name matches `FR_(\\d+)_.*`, key = `FR-NNN` (zero-padded
     to 3 digits to match the spec.md style);
   - else, key = literal assertion name.
2. Across replicates, collect each key's observed verdicts
   (PASS / FAIL). The key's *appearances* count is the number of
   replicates it appeared in.
3. Per key with appearances ≥ 5: stability = max-verdict-count /
   appearances ∈ [0, 1].
4. D5 (cell) = mean over qualifying keys. If no key reaches the
   floor, D5 = `None` (the cell-summary row writes empty for D5).

Per-cell composite: `aqs_full = mean(D1, D2, D3, D4, D5)` only when D5
is defined; otherwise `aqs_full` is empty and `aqs_partial_mean` is the
useful composite. Both columns are present in `cell_summary.csv`.

CLI:

    python eval/aggregate.py
    python eval/aggregate.py --runs-root eval/runs/ \
                             --results-dir eval/results/
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from statistics import mean
from typing import Any, Iterable

# Mirror scorer.py's path discovery so this script runs with `python
# eval/aggregate.py` from the repo root.
HERE = Path(__file__).resolve().parent          # …/eval
REPO_ROOT = HERE.parent                          # …/spec-led-eval
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

#: D5 floor — keys appearing in fewer than this many replicates are
#: ignored as noise. EVALUATION_PLAN.md §3.1 D5 fixes this at 5 (half of
#: the planned 10-replicate cohort).
D5_MIN_APPEARANCES = 5

#: Run-directory name pattern.
_RE_RUN_NN = re.compile(r"^run_(?P<rep>\d+)$")

#: FR-named assertion pattern. Matches `FR_001_CustomerSubmits`,
#: `FR_017_Retention`, etc.
_RE_FR_ASSERTION = re.compile(r"^FR_(?P<num>\d+)_")


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class RunRecord:
    """The data the aggregator carries through for one replicate."""
    run_id: str
    cell: str
    model: str
    rep: int
    D1: float
    D2: float
    D3: float
    D4: float
    aqs_partial: float
    # Inputs to the D5 step:
    verdicts: dict[str, str] = field(default_factory=dict)
    patterns_applied: list[str] = field(default_factory=list)


@dataclass
class CellSummary:
    """One row of cell_summary.csv."""
    cell: str
    model: str
    n_runs: int
    D1_mean: float
    D2_mean: float
    D3_mean: float
    D4_mean: float
    aqs_partial_mean: float
    D5: float | None
    aqs_full: float | None
    d5_details: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# D5 normalisation
# ---------------------------------------------------------------------------

def normalise_assertion_key(name: str, patterns_applied: Iterable[str]) -> str:
    """Map an assertion name to its D5 normalisation key.

    Priority order (per EVALUATION_PLAN.md §3.1 D5):

    1. If the name is one of `patterns_applied`, return the name as-is.
       The lifter convention is to give each pattern's assertion the
       same name as the pattern itself, so `LeastPrivilege` (assertion)
       maps to `LeastPrivilege` (key).
    2. Elif the name matches `FR_(\\d+)_.*`, return `FR-NNN` with the
       integer zero-padded to 3 digits — matching the spec.md style
       used in `parse_spec` outputs.
    3. Else return the literal assertion name.
    """
    pa = set(patterns_applied or [])
    if name in pa:
        return name
    m = _RE_FR_ASSERTION.match(name)
    if m:
        return f"FR-{int(m.group('num')):03d}"
    return name


def compute_d5(
    runs: list[RunRecord],
    *,
    min_appearances: int = D5_MIN_APPEARANCES,
) -> tuple[float | None, dict[str, Any]]:
    """Compute D5 stability for one (cell, model) cohort.

    `runs` should be every replicate's `RunRecord` for that cohort.

    Returns `(d5, details)` where `d5` is None when no normalised key
    appears in ≥ `min_appearances` replicates.
    """
    if not runs:
        return None, {
            "n_runs": 0,
            "min_appearances": min_appearances,
            "per_key": {},
            "note": "no runs in cohort",
        }

    # key → list of (rep, verdict)
    key_verdicts: dict[str, list[tuple[int, str]]] = defaultdict(list)
    for r in runs:
        pa = r.patterns_applied
        for assertion_name, verdict in (r.verdicts or {}).items():
            key = normalise_assertion_key(assertion_name, pa)
            key_verdicts[key].append((r.rep, verdict))

    per_key: dict[str, dict[str, Any]] = {}
    qualifying_scores: list[float] = []
    for key, hits in key_verdicts.items():
        appearances = len(hits)
        verdicts = [v for _, v in hits]
        counter = Counter(verdicts)
        modal_verdict, modal_count = counter.most_common(1)[0]
        stability = modal_count / appearances if appearances else 0.0
        qualifies = appearances >= min_appearances
        per_key[key] = {
            "appearances": appearances,
            "verdicts": dict(counter),
            "modal_verdict": modal_verdict,
            "modal_count": modal_count,
            "stability": stability,
            "qualifies": qualifies,
        }
        if qualifies:
            qualifying_scores.append(stability)

    if not qualifying_scores:
        return None, {
            "n_runs": len(runs),
            "min_appearances": min_appearances,
            "per_key": per_key,
            "note": (
                f"no key reached the {min_appearances}-replicate floor "
                f"(cohort has {len(runs)} replicate(s))"
            ),
        }
    return mean(qualifying_scores), {
        "n_runs": len(runs),
        "min_appearances": min_appearances,
        "per_key": per_key,
        "n_qualifying_keys": len(qualifying_scores),
    }


# ---------------------------------------------------------------------------
# Walking / loading
# ---------------------------------------------------------------------------

def iter_scored_runs(runs_root: Path) -> list[Path]:
    """Return every `runs/<cell>/<model>/run_NN/` containing `scores.json`."""
    out: list[Path] = []
    if not runs_root.is_dir():
        return out
    for cell_dir in sorted(p for p in runs_root.iterdir() if p.is_dir()):
        for model_dir in sorted(p for p in cell_dir.iterdir() if p.is_dir()):
            for run_dir in sorted(p for p in model_dir.iterdir() if p.is_dir()):
                if not _RE_RUN_NN.match(run_dir.name):
                    continue
                if (run_dir / "scores.json").exists():
                    out.append(run_dir)
    return out


def load_run_record(run_dir: Path) -> RunRecord:
    """Read scores.json + alloy_verdicts.json + manifest into a RunRecord."""
    scores = json.loads((run_dir / "scores.json").read_text(encoding="utf-8"))

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

    manifest_path = run_dir / "feature_model.manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        manifest = {}
    patterns_applied = list(manifest.get("patterns_applied") or [])

    return RunRecord(
        run_id=scores["run_id"],
        cell=scores["cell"],
        model=scores["model"],
        rep=int(scores["rep"]),
        D1=float(scores["D1"]),
        D2=float(scores["D2"]),
        D3=float(scores["D3"]),
        D4=float(scores["D4"]),
        aqs_partial=float(scores["aqs_partial"]),
        verdicts=verdicts,
        patterns_applied=patterns_applied,
    )


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

def aggregate_runs(runs_root: Path) -> tuple[list[RunRecord], list[CellSummary]]:
    """Walk `runs_root`, build per-run + per-cell records.

    Returns `(runs, cells)`. Per-cell rows are sorted by (cell, model).
    """
    runs: list[RunRecord] = []
    for run_dir in iter_scored_runs(runs_root):
        try:
            runs.append(load_run_record(run_dir))
        except (KeyError, ValueError) as e:
            # Malformed scores.json — skip with a warning, don't abort.
            print(
                f"[warn] skipping {run_dir}: {type(e).__name__}: {e}",
                file=sys.stderr,
            )

    # Group by (cell, model).
    cohorts: dict[tuple[str, str], list[RunRecord]] = defaultdict(list)
    for r in runs:
        cohorts[(r.cell, r.model)].append(r)

    cells: list[CellSummary] = []
    for (cell, model), members in sorted(cohorts.items()):
        members_sorted = sorted(members, key=lambda r: r.rep)
        d5, d5_details = compute_d5(members_sorted)
        d1m = mean(r.D1 for r in members_sorted)
        d2m = mean(r.D2 for r in members_sorted)
        d3m = mean(r.D3 for r in members_sorted)
        d4m = mean(r.D4 for r in members_sorted)
        aqs_partial_mean = mean(r.aqs_partial for r in members_sorted)
        if d5 is None:
            aqs_full: float | None = None
        else:
            aqs_full = mean([d1m, d2m, d3m, d4m, d5])
        cells.append(
            CellSummary(
                cell=cell,
                model=model,
                n_runs=len(members_sorted),
                D1_mean=d1m,
                D2_mean=d2m,
                D3_mean=d3m,
                D4_mean=d4m,
                aqs_partial_mean=aqs_partial_mean,
                D5=d5,
                aqs_full=aqs_full,
                d5_details=d5_details,
            )
        )

    return runs, cells


# ---------------------------------------------------------------------------
# CSV writers
# ---------------------------------------------------------------------------

_ALL_SCORES_HEADER = [
    "run_id", "cell", "model", "rep",
    "D1", "D2", "D3", "D4", "aqs_partial",
]

_CELL_SUMMARY_HEADER = [
    "cell", "model", "n_runs",
    "D1_mean", "D2_mean", "D3_mean", "D4_mean",
    "aqs_partial_mean", "D5", "aqs_full",
]


def _fmt_float(x: float | None) -> str:
    """Render a float for CSV; empty string when None."""
    if x is None:
        return ""
    return f"{x:.10g}"


def write_all_scores_csv(runs: list[RunRecord], path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    runs_sorted = sorted(runs, key=lambda r: (r.cell, r.model, r.rep))
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(_ALL_SCORES_HEADER)
        for r in runs_sorted:
            w.writerow([
                r.run_id, r.cell, r.model, r.rep,
                _fmt_float(r.D1), _fmt_float(r.D2),
                _fmt_float(r.D3), _fmt_float(r.D4),
                _fmt_float(r.aqs_partial),
            ])
    return path


def write_cell_summary_csv(cells: list[CellSummary], path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(_CELL_SUMMARY_HEADER)
        for c in cells:
            w.writerow([
                c.cell, c.model, c.n_runs,
                _fmt_float(c.D1_mean), _fmt_float(c.D2_mean),
                _fmt_float(c.D3_mean), _fmt_float(c.D4_mean),
                _fmt_float(c.aqs_partial_mean),
                _fmt_float(c.D5), _fmt_float(c.aqs_full),
            ])
    return path


def write_d5_details_json(cells: list[CellSummary], path: Path) -> Path:
    """Optional sidecar — per-key D5 diagnostics for later inspection."""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        f"{c.cell}/{c.model}": c.d5_details for c in cells
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="eval/aggregate.py",
        description=(
            "Walk eval/runs/<cell>/<model>/run_NN/scores.json, compute D5 "
            "per (cell, model), and write all_scores.csv + cell_summary.csv."
        ),
    )
    ap.add_argument(
        "--runs-root",
        type=Path,
        default=REPO_ROOT / "eval" / "runs",
        help="Directory containing <cell>/<model>/run_NN/ subdirs.",
    )
    ap.add_argument(
        "--results-dir",
        type=Path,
        default=REPO_ROOT / "eval" / "results",
        help="Output directory for CSVs.",
    )
    args = ap.parse_args(argv)

    runs_root = args.runs_root.resolve()
    results_dir = args.results_dir.resolve()

    runs, cells = aggregate_runs(runs_root)
    if not runs:
        print(
            f"[warn] no scored runs found under {runs_root}",
            file=sys.stderr,
        )

    all_path = write_all_scores_csv(runs, results_dir / "all_scores.csv")
    sum_path = write_cell_summary_csv(cells, results_dir / "cell_summary.csv")
    det_path = write_d5_details_json(cells, results_dir / "d5_details.json")

    print(f"[write]   {all_path}  ({len(runs)} row(s))")
    print(f"[write]   {sum_path}  ({len(cells)} row(s))")
    print(f"[write]   {det_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

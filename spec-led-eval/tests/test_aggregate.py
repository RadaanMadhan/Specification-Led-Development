"""tests/test_aggregate.py — pytest coverage for the E4 aggregator.

Covers:
- D5 normalisation key construction (pattern hit, FR-NNN, fallback).
- D5 stability scoring across synthetic 10-replicate cohorts (perfect
  stability, mixed verdicts, sub-floor keys).
- Single-replicate degradation (D5 = None, aqs_full empty).
- CSV writer output schema + numerical content.
- Integration: aggregating the real A-L1/M-best/run_01 fixture produces
  exactly one all_scores row and one cell_summary row with D5 empty.
"""

from __future__ import annotations

import csv
import json
import math
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
EVAL_DIR = REPO_ROOT / "eval"
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import aggregate  # type: ignore  # noqa: E402  — loaded from eval/aggregate.py


REAL_RUN = REPO_ROOT / "eval" / "runs" / "A-L1" / "M-best" / "run_01"


# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

def _make_run_dir(
    base: Path,
    *,
    cell: str,
    model: str,
    rep: int,
    scores: dict,
    verdicts: dict,
    patterns_applied: list[str] | None = None,
) -> Path:
    """Materialise scores.json + alloy_verdicts.json + manifest.json."""
    run_dir = base / "eval" / "runs" / cell / model / f"run_{rep:02d}"
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "scores.json").write_text(
        json.dumps(scores), encoding="utf-8"
    )
    (run_dir / "alloy_verdicts.json").write_text(
        json.dumps(verdicts), encoding="utf-8"
    )
    (run_dir / "feature_model.manifest.json").write_text(
        json.dumps({"patterns_applied": patterns_applied or []}),
        encoding="utf-8",
    )
    return run_dir


def _scores_record(cell: str, model: str, rep: int,
                   d1=1.0, d2=1.0, d3=1.0, d4=1.0) -> dict:
    return {
        "run_id": f"{cell}/{model}/run_{rep:02d}",
        "cell": cell, "model": model, "rep": rep,
        "D1": d1, "D2": d2, "D3": d3, "D4": d4,
        "aqs_partial": (d1 + d2 + d3 + d4) / 4.0,
    }


# ---------------------------------------------------------------------------
# normalise_assertion_key
# ---------------------------------------------------------------------------

def test_key_pattern_hit() -> None:
    """Assertion name matching a declared pattern → pattern name as key."""
    assert (
        aggregate.normalise_assertion_key("LeastPrivilege",
                                          ["LeastPrivilege", "AppendOnly"])
        == "LeastPrivilege"
    )


def test_key_fr_naming() -> None:
    """FR_NNN_-prefixed names → FR-NNN with zero-padded 3 digits."""
    assert (
        aggregate.normalise_assertion_key("FR_001_CustomerSubmits", [])
        == "FR-001"
    )
    assert (
        aggregate.normalise_assertion_key("FR_42_Audit", [])
        == "FR-042"
    )


def test_key_literal_fallback() -> None:
    """No pattern hit, no FR prefix → literal name."""
    assert (
        aggregate.normalise_assertion_key("RandomAssertion", ["LeastPrivilege"])
        == "RandomAssertion"
    )


# ---------------------------------------------------------------------------
# compute_d5
# ---------------------------------------------------------------------------

def _cohort_with_keys(
    n_reps: int,
    key_verdicts: dict[str, list[str]],
    *,
    cell: str = "X-L1",
    model: str = "M-best",
    patterns_applied: list[str] | None = None,
) -> list[aggregate.RunRecord]:
    """Build a cohort of RunRecords.

    `key_verdicts[k][i]` is the verdict for key `k` in replicate `i`
    (or `""` to mean the key didn't appear in that replicate).
    """
    runs: list[aggregate.RunRecord] = []
    pa = patterns_applied or list(key_verdicts.keys())
    for i in range(n_reps):
        verdicts: dict[str, str] = {}
        for key, per_rep in key_verdicts.items():
            v = per_rep[i] if i < len(per_rep) else ""
            if v:
                verdicts[key] = v
        runs.append(
            aggregate.RunRecord(
                run_id=f"{cell}/{model}/run_{i + 1:02d}",
                cell=cell, model=model, rep=i + 1,
                D1=1.0, D2=1.0, D3=1.0, D4=1.0, aqs_partial=1.0,
                verdicts=verdicts,
                patterns_applied=pa,
            )
        )
    return runs


def test_d5_perfect_stability() -> None:
    """A key appearing in 10/10 replicates with same verdict → 1.0."""
    runs = _cohort_with_keys(
        10,
        {"LeastPrivilege": ["PASS"] * 10},
    )
    d5, details = aggregate.compute_d5(runs)
    assert d5 == 1.0
    assert details["per_key"]["LeastPrivilege"]["qualifies"] is True
    assert details["per_key"]["LeastPrivilege"]["stability"] == 1.0


def test_d5_mixed_verdicts() -> None:
    """A key with 7 PASS / 3 FAIL → stability 7/10 = 0.7."""
    runs = _cohort_with_keys(
        10,
        {"AppendOnly": ["PASS"] * 7 + ["FAIL"] * 3},
    )
    d5, _ = aggregate.compute_d5(runs)
    assert math.isclose(d5, 0.7)


def test_d5_sub_floor_key_excluded() -> None:
    """A key appearing only 4 times is excluded entirely."""
    runs = _cohort_with_keys(
        10,
        {
            "Stable": ["PASS"] * 10,
            "Sporadic": ["PASS", "PASS", "PASS", "PASS", "", "", "", "", "", ""],
        },
    )
    d5, details = aggregate.compute_d5(runs)
    # Only Stable qualifies; mean of [1.0] = 1.0
    assert d5 == 1.0
    assert details["per_key"]["Sporadic"]["qualifies"] is False
    assert details["per_key"]["Stable"]["qualifies"] is True


def test_d5_no_qualifying_key_returns_none() -> None:
    """If no key reaches the 5-replicate floor, D5 = None."""
    runs = _cohort_with_keys(
        4,
        {"Stable": ["PASS"] * 4},
    )
    d5, details = aggregate.compute_d5(runs)
    assert d5 is None
    assert "no key reached" in details["note"]


def test_d5_single_replicate_returns_none() -> None:
    """The A-L1 smoke-test case — D5 undefined for a 1-rep cohort."""
    runs = _cohort_with_keys(
        1,
        {"LeastPrivilege": ["PASS"]},
    )
    d5, _ = aggregate.compute_d5(runs)
    assert d5 is None


def test_d5_groups_fr_keys_correctly() -> None:
    """Verdicts on `FR_006_Foo` and `FR_006_Bar` collapse to one FR-006 key."""
    runs: list[aggregate.RunRecord] = []
    for i in range(5):
        runs.append(
            aggregate.RunRecord(
                run_id=f"x/y/run_{i+1:02d}", cell="x", model="y", rep=i + 1,
                D1=1.0, D2=1.0, D3=1.0, D4=1.0, aqs_partial=1.0,
                # Two assertion names that should collapse to FR-006:
                verdicts={"FR_006_Foo": "PASS", "FR_006_Bar": "FAIL"},
                patterns_applied=[],
            )
        )
    d5, details = aggregate.compute_d5(runs)
    # FR-006 appears 5 reps × 2 sub-assertions = 10 verdicts, but
    # appearances counts the number of hits (10), so its modal stability
    # is max(5, 5) / 10 = 0.5.
    fr006 = details["per_key"]["FR-006"]
    assert fr006["appearances"] == 10
    assert fr006["modal_count"] == 5
    assert math.isclose(fr006["stability"], 0.5)
    assert math.isclose(d5, 0.5)


# ---------------------------------------------------------------------------
# aggregate_runs end-to-end on synthetic data
# ---------------------------------------------------------------------------

def test_aggregate_synthetic_two_cohorts(tmp_path: Path) -> None:
    """Two (cell, model) cohorts, each with 5 reps and stable verdicts."""
    for rep in range(1, 6):
        _make_run_dir(
            tmp_path, cell="X-L1", model="M-best", rep=rep,
            scores=_scores_record("X-L1", "M-best", rep),
            verdicts={"LeastPrivilege": "PASS"},
            patterns_applied=["LeastPrivilege"],
        )
        _make_run_dir(
            tmp_path, cell="X-L2", model="M-best", rep=rep,
            scores=_scores_record("X-L2", "M-best", rep, d4=0.5),
            verdicts={"LeastPrivilege": "FAIL"},
            patterns_applied=["LeastPrivilege"],
        )

    runs, cells = aggregate.aggregate_runs(tmp_path / "eval" / "runs")
    assert len(runs) == 10
    assert len(cells) == 2

    c1 = [c for c in cells if c.cell == "X-L1"][0]
    c2 = [c for c in cells if c.cell == "X-L2"][0]
    assert c1.n_runs == 5
    assert c1.D5 == 1.0
    assert c1.aqs_full == 1.0
    assert c2.n_runs == 5
    assert c2.D5 == 1.0           # 5 FAILs is also stable
    # aqs_full for X-L2: mean(1, 1, 1, 0.5, 1) = 0.9
    assert math.isclose(c2.aqs_full, 0.9)


# ---------------------------------------------------------------------------
# CSV output
# ---------------------------------------------------------------------------

def test_csv_outputs_have_expected_schema(tmp_path: Path) -> None:
    for rep in range(1, 6):
        _make_run_dir(
            tmp_path, cell="X-L1", model="M-best", rep=rep,
            scores=_scores_record("X-L1", "M-best", rep),
            verdicts={"LeastPrivilege": "PASS"},
            patterns_applied=["LeastPrivilege"],
        )

    runs, cells = aggregate.aggregate_runs(tmp_path / "eval" / "runs")
    results_dir = tmp_path / "eval" / "results"
    all_path = aggregate.write_all_scores_csv(
        runs, results_dir / "all_scores.csv"
    )
    sum_path = aggregate.write_cell_summary_csv(
        cells, results_dir / "cell_summary.csv"
    )

    with all_path.open() as fh:
        rows = list(csv.DictReader(fh))
    assert len(rows) == 5
    assert {"run_id", "cell", "model", "rep", "D1", "D2", "D3", "D4",
            "aqs_partial"} <= set(rows[0].keys())
    assert rows[0]["cell"] == "X-L1"

    with sum_path.open() as fh:
        srows = list(csv.DictReader(fh))
    assert len(srows) == 1
    assert srows[0]["cell"] == "X-L1"
    assert srows[0]["n_runs"] == "5"
    assert srows[0]["D5"] == "1"
    assert srows[0]["aqs_full"] == "1"


def test_csv_empty_d5_when_below_floor(tmp_path: Path) -> None:
    """A 1-replicate cohort writes empty D5 / aqs_full cells."""
    _make_run_dir(
        tmp_path, cell="X-L1", model="M-best", rep=1,
        scores=_scores_record("X-L1", "M-best", 1),
        verdicts={"LeastPrivilege": "PASS"},
        patterns_applied=["LeastPrivilege"],
    )
    runs, cells = aggregate.aggregate_runs(tmp_path / "eval" / "runs")
    results_dir = tmp_path / "eval" / "results"
    sum_path = aggregate.write_cell_summary_csv(
        cells, results_dir / "cell_summary.csv"
    )
    with sum_path.open() as fh:
        srows = list(csv.DictReader(fh))
    assert srows[0]["D5"] == ""
    assert srows[0]["aqs_full"] == ""


# ---------------------------------------------------------------------------
# Real-fixture integration
# ---------------------------------------------------------------------------

def test_real_a_l1_aggregation() -> None:
    """The live A-L1/run_01 fixture aggregates with the expected aqs_partial.

    Originally written when eval/runs/ contained only A-L1/M-best/run_01,
    this test was a literal "len(runs) == 1" assertion. After the Stage-1
    sweep (E6) populated all 90 runs, that assumption is stale. We now
    look up the specific run_01 record from the broader aggregate and
    assert its scores; the broader sweep is otherwise unconstrained.
    """
    if not REAL_RUN.exists() or not (REAL_RUN / "scores.json").exists():
        pytest.skip("A-L1/run_01 scores.json missing — run E3 first")
    runs_root = REAL_RUN.parents[2]   # …/eval/runs
    runs, cells = aggregate.aggregate_runs(runs_root)

    # Find the A-L1 / M-best / run_01 record specifically.
    matches = [
        r for r in runs
        if r.cell == "A-L1" and r.model == "M-best" and r.rep == 1
    ]
    assert len(matches) == 1, (
        f"expected exactly one A-L1/M-best/run_01 record, got {len(matches)}"
    )
    rec = matches[0]
    assert math.isclose(rec.aqs_partial, 67.5 / 68, rel_tol=1e-9)

    a_l1_summaries = [c for c in cells if c.cell == "A-L1" and c.model == "M-best"]
    assert len(a_l1_summaries) == 1, (
        f"expected one A-L1/M-best cell summary, got {len(a_l1_summaries)}"
    )

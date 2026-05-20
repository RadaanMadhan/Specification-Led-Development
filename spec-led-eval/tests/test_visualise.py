"""tests/test_visualise.py — pytest coverage for the E5 figures module.

Covers:
- parse_cell happy path + rejections.
- mean_and_ci95 zero-width when n < 2.
- collect_patterns_per_cell unions across replicates.
- collect_cost_per_assertion handles missing / malformed cost_log.json.
- Each of the four figures functions: produces a non-empty PNG on a
  synthetic 3×3 fixture.
- Full run() against a complete synthetic fixture writes all 4 PNGs
  into the figures dir with non-trivial sizes.
- Single-cell N=1 smoke run mimicking the live A-L1 state: run() exits
  cleanly, produces every figure it can renderably produce.
"""

from __future__ import annotations

import csv
import json
import random
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")  # NOQA: E402 — keep tests headless

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
EVAL_DIR = REPO_ROOT / "eval"
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))

import visualise  # type: ignore  # noqa: E402

# Non-empty PNG threshold — figures with axes/labels always exceed
# 1 KB; this catches the "wrote a 0-byte placeholder" failure mode.
MIN_PNG_SIZE = 1024


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

def test_parse_cell_happy_path():
    assert visualise.parse_cell("A-L1") == ("A", "L1")
    assert visualise.parse_cell("C-L3") == ("C", "L3")


def test_parse_cell_rejects_unknown_shape():
    with pytest.raises(ValueError):
        visualise.parse_cell("D-L1")
    with pytest.raises(ValueError):
        visualise.parse_cell("A-L9")
    with pytest.raises(ValueError):
        visualise.parse_cell("not-a-cell")


def test_mean_and_ci95_n_lt_2_zero_width():
    m, ci = visualise.mean_and_ci95([0.5])
    assert m == pytest.approx(0.5)
    assert ci == 0.0
    m2, ci2 = visualise.mean_and_ci95([])
    assert m2 is None and ci2 == 0.0


def test_mean_and_ci95_known_sample():
    # 5 obs, mean 0.5, sd 0.1581 → se = 0.0707 → t(0.975, 4) ≈ 2.776
    m, ci = visualise.mean_and_ci95([0.3, 0.4, 0.5, 0.6, 0.7])
    assert m == pytest.approx(0.5)
    # Expected ≈ 2.776 * 0.0707 ≈ 0.196
    assert 0.15 < ci < 0.25


# ---------------------------------------------------------------------------
# Manifest + cost collection
# ---------------------------------------------------------------------------

def _write_run(
    base: Path, cell: str, rep: int,
    *, patterns: list[str] | None = None,
    cost_per_assertion: float | None = None,
) -> Path:
    """Synthesise a minimal run dir with a manifest and cost_log."""
    run_dir = base / "runs" / cell / "M-best" / f"run_{rep:02d}"
    run_dir.mkdir(parents=True, exist_ok=True)
    manifest = {"feature_id": f"synthetic-{cell}-{rep}",
                "patterns_applied": patterns or []}
    (run_dir / "feature_model.manifest.json").write_text(
        json.dumps(manifest)
    )
    cost = {
        "run_id": cell, "model": "M-best",
        "input_tokens": 1000, "output_tokens": 2000,
        "cost_usd": 0.05,
        "cost_per_assertion_usd": cost_per_assertion,
        "elapsed_seconds": 100.0,
    }
    (run_dir / "cost_log.json").write_text(json.dumps(cost))
    return run_dir


def test_collect_patterns_per_cell_unions_across_replicates(tmp_path):
    _write_run(tmp_path, "A-L1", 1, patterns=["P1", "P2"])
    _write_run(tmp_path, "A-L1", 2, patterns=["P2", "P3"])
    _write_run(tmp_path, "B-L2", 1, patterns=["Q1"])
    runs_by_cell = visualise.discover_run_dirs(tmp_path / "runs")
    patterns = visualise.collect_patterns_per_cell(runs_by_cell)
    assert patterns["A-L1"] == {"P1", "P2", "P3"}
    assert patterns["B-L2"] == {"Q1"}


def test_collect_cost_per_assertion_skips_missing_values(tmp_path):
    _write_run(tmp_path, "A-L1", 1, cost_per_assertion=0.02)
    _write_run(tmp_path, "A-L1", 2, cost_per_assertion=None)
    _write_run(tmp_path, "A-L1", 3, cost_per_assertion=0.03)
    runs_by_cell = visualise.discover_run_dirs(tmp_path / "runs")
    costs = visualise.collect_cost_per_assertion(runs_by_cell)
    # The None value is filtered; the two valid values remain.
    assert sorted(costs["A-L1"]) == [0.02, 0.03]


def test_collect_cost_per_assertion_tolerates_malformed_json(tmp_path):
    run_dir = _write_run(tmp_path, "A-L1", 1, cost_per_assertion=0.02)
    (run_dir / "cost_log.json").write_text("not valid json")
    runs_by_cell = visualise.discover_run_dirs(tmp_path / "runs")
    costs = visualise.collect_cost_per_assertion(runs_by_cell)
    assert costs["A-L1"] == []


# ---------------------------------------------------------------------------
# Synthetic fixture builders for full-pipeline tests
# ---------------------------------------------------------------------------

def _write_all_scores_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["run_id", "cell", "model", "rep",
              "D1", "D2", "D3", "D4", "aqs_partial"]
    with path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fields})


def _build_synthetic_eval_dir(
    tmp_path: Path,
    *, reps_per_cell: int = 5, seed: int = 99,
    include_d5: bool = True,
) -> tuple[Path, Path]:
    """Materialise a complete synthetic eval/ tree under tmp_path.

    Returns (results_dir, runs_root).
    """
    rng = random.Random(seed)
    eval_dir = tmp_path / "eval"
    results_dir = eval_dir / "results"
    figures_dir = results_dir / "figures"
    runs_root = eval_dir / "runs"
    results_dir.mkdir(parents=True, exist_ok=True)
    figures_dir.mkdir(parents=True, exist_ok=True)

    # Per-richness underlying means (strong gradient for visual clarity)
    rich_mean = {"L1": 0.5, "L2": 0.7, "L3": 0.9}
    # Per-cell pattern sets that vary by richness
    base_patterns = [f"P{i:02d}" for i in range(1, 13)]
    rows: list[dict] = []
    for dom in ("A", "B", "C"):
        for rich in ("L1", "L2", "L3"):
            cell = f"{dom}-{rich}"
            n_patterns = {"L1": 4, "L2": 8, "L3": 12}[rich]
            patterns = base_patterns[:n_patterns]
            for rep in range(1, reps_per_cell + 1):
                aqs = max(0.0, min(1.0,
                                   rng.gauss(rich_mean[rich], 0.05)))
                cost_per_assertion = (
                    0.05 - 0.005 * {"L1": 0, "L2": 1, "L3": 2}[rich]
                )
                # Write the per-run manifest + cost_log
                _write_run(eval_dir, cell, rep,
                            patterns=patterns,
                            cost_per_assertion=cost_per_assertion)
                rows.append({
                    "run_id": f"{cell}/M-best/run_{rep:02d}",
                    "cell": cell, "model": "M-best", "rep": rep,
                    "D1": aqs, "D2": aqs, "D3": aqs, "D4": aqs,
                    "aqs_partial": aqs,
                })
    _write_all_scores_csv(results_dir / "all_scores.csv", rows)

    if include_d5:
        # Build a d5 that has at least one key per cell with a
        # stability that increases with richness — gives the heatmap
        # something interesting to render.
        d5 = {}
        for dom in ("A", "B", "C"):
            for rich in ("L1", "L2", "L3"):
                cell = f"{dom}-{rich}"
                stability = {"L1": 0.6, "L2": 0.8, "L3": 0.95}[rich]
                d5[f"{cell}/M-best"] = {
                    "n_runs": reps_per_cell, "min_appearances": 5,
                    "per_key": {
                        "LeastPrivilege": {
                            "appearances": reps_per_cell,
                            "verdicts": {"PASS": reps_per_cell},
                            "modal_verdict": "PASS",
                            "modal_count": reps_per_cell,
                            "stability": stability,
                            "qualifies": True,
                        },
                        "FR-001": {
                            "appearances": reps_per_cell,
                            "verdicts": {"PASS": reps_per_cell},
                            "modal_verdict": "PASS",
                            "modal_count": reps_per_cell,
                            "stability": stability,
                            "qualifies": True,
                        },
                    },
                }
        (results_dir / "d5_details.json").write_text(json.dumps(d5))
    else:
        (results_dir / "d5_details.json").write_text("{}")
    return results_dir, runs_root


# ---------------------------------------------------------------------------
# Per-figure tests
# ---------------------------------------------------------------------------

def test_figure_aqs_richness_writes_png(tmp_path):
    results_dir, _ = _build_synthetic_eval_dir(tmp_path)
    rows = visualise.load_all_scores(results_dir / "all_scores.csv")
    out = results_dir / "figures" / "aqs.png"
    ok, reason = visualise.figure_aqs_richness(rows, out)
    assert ok, reason
    assert out.exists() and out.stat().st_size > MIN_PNG_SIZE


def test_figure_aqs_richness_skips_when_empty(tmp_path):
    out = tmp_path / "aqs.png"
    ok, reason = visualise.figure_aqs_richness([], out)
    assert not ok
    assert reason is not None and "aqs_partial" in reason


def test_figure_stability_heatmap_writes_png(tmp_path):
    results_dir, _ = _build_synthetic_eval_dir(tmp_path)
    d5 = visualise.load_d5_details(results_dir / "d5_details.json")
    out = results_dir / "figures" / "heatmap.png"
    ok, reason = visualise.figure_stability_heatmap(d5, out)
    assert ok, reason
    assert out.exists() and out.stat().st_size > MIN_PNG_SIZE


def test_figure_stability_heatmap_skips_when_empty(tmp_path):
    out = tmp_path / "heatmap.png"
    ok, reason = visualise.figure_stability_heatmap({}, out)
    assert not ok


def test_figure_pattern_coverage_writes_png(tmp_path):
    results_dir, runs_root = _build_synthetic_eval_dir(tmp_path)
    runs_by_cell = visualise.discover_run_dirs(runs_root)
    patterns_by_cell = visualise.collect_patterns_per_cell(runs_by_cell)
    out = results_dir / "figures" / "coverage.png"
    ok, reason = visualise.figure_pattern_coverage(patterns_by_cell, out)
    assert ok, reason
    assert out.exists() and out.stat().st_size > MIN_PNG_SIZE


def test_figure_pattern_coverage_skips_when_all_empty(tmp_path):
    out = tmp_path / "coverage.png"
    ok, reason = visualise.figure_pattern_coverage(
        {"A-L1": set(), "B-L2": set()}, out
    )
    assert not ok
    assert "patterns_applied" in (reason or "")


def test_figure_cost_efficiency_writes_png(tmp_path):
    results_dir, runs_root = _build_synthetic_eval_dir(tmp_path)
    rows = visualise.load_all_scores(results_dir / "all_scores.csv")
    runs_by_cell = visualise.discover_run_dirs(runs_root)
    cost_by_cell = visualise.collect_cost_per_assertion(runs_by_cell)
    out = results_dir / "figures" / "cost.png"
    ok, reason = visualise.figure_cost_efficiency(rows, cost_by_cell, out)
    assert ok, reason
    assert out.exists() and out.stat().st_size > MIN_PNG_SIZE


# ---------------------------------------------------------------------------
# Full run() — synthetic 3×3 fixture
# ---------------------------------------------------------------------------

def test_run_writes_all_four_figures_on_synthetic_fixture(tmp_path):
    results_dir, runs_root = _build_synthetic_eval_dir(tmp_path)
    figures_dir = results_dir / "figures"
    outcomes = visualise.run(results_dir, figures_dir, runs_root=runs_root)
    expected = {
        "aqs_richness": "bar_chart_aqs_by_richness.png",
        "stability_heatmap": "verdict_stability_heatmap.png",
        "pattern_coverage": "pattern_coverage.png",
        "cost_efficiency": "cost_efficiency.png",
    }
    for key, fname in expected.items():
        assert outcomes[key]["skipped"] is False, outcomes[key]
        assert (figures_dir / fname).exists()
        assert (figures_dir / fname).stat().st_size > MIN_PNG_SIZE


# ---------------------------------------------------------------------------
# Single-cell N=1 smoke run — mirrors the live A-L1 state
# ---------------------------------------------------------------------------

def _build_single_cell_n1_fixture(tmp_path: Path) -> tuple[Path, Path]:
    """A-L1/M-best/run_01 only, with a 1-replicate d5_details where
    no key qualifies."""
    eval_dir = tmp_path / "eval"
    results_dir = eval_dir / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    _write_all_scores_csv(results_dir / "all_scores.csv", [{
        "run_id": "A-L1/M-best/run_01", "cell": "A-L1", "model": "M-best",
        "rep": 1, "D1": 1.0, "D2": 1.0, "D3": 1.0, "D4": 0.9706,
        "aqs_partial": 0.9926,
    }])
    (results_dir / "d5_details.json").write_text(json.dumps({
        "A-L1/M-best": {
            "n_runs": 1, "min_appearances": 5,
            "per_key": {
                "LeastPrivilege": {
                    "appearances": 1,
                    "verdicts": {"PASS": 1},
                    "modal_verdict": "PASS", "modal_count": 1,
                    "stability": 1.0, "qualifies": False,
                },
                "FR-006": {
                    "appearances": 1,
                    "verdicts": {"FAIL": 1},
                    "modal_verdict": "FAIL", "modal_count": 1,
                    "stability": 1.0, "qualifies": False,
                },
            },
        },
    }))
    _write_run(eval_dir, "A-L1", 1,
                patterns=["LeastPrivilege", "AuditCompleteness"],
                cost_per_assertion=0.03)
    return results_dir, eval_dir / "runs"


def test_run_handles_single_cell_n1_smoke(tmp_path):
    results_dir, runs_root = _build_single_cell_n1_fixture(tmp_path)
    figures_dir = results_dir / "figures"
    outcomes = visualise.run(results_dir, figures_dir, runs_root=runs_root)
    # The run must exit 0 — i.e. simply complete without raising.
    # Figures that can render with N=1: pattern_coverage, cost_efficiency.
    # The AQS bar chart can also draw (with zero error bars).
    # The heatmap renders with the single cell's two keys.
    produced = [k for k, v in outcomes.items() if not v["skipped"]]
    assert len(produced) >= 1, (
        "At least one figure must render on N=1 data; outcomes="
        + repr(outcomes)
    )
    # Pattern coverage and cost efficiency should always be renderable
    # when at least one run with patterns + cost exists.
    assert outcomes["pattern_coverage"]["skipped"] is False
    assert outcomes["cost_efficiency"]["skipped"] is False
    # Stage-2 figures must skip cleanly on single-model data with a reason.
    assert outcomes["aqs_by_model"]["skipped"] is True
    assert outcomes["aqs_by_model"]["reason"]
    assert outcomes["cost_quality_frontier"]["skipped"] is True
    assert outcomes["cost_quality_frontier"]["reason"]
    for key, info in outcomes.items():
        if info["skipped"]:
            assert info["reason"], f"skipped {key} missing reason"
        else:
            png_path = Path(info["path"])
            assert png_path.exists()
            assert png_path.stat().st_size > MIN_PNG_SIZE


# ===========================================================================
# Stage 2 — figure 5 (AQS by model) and figure 6 (cost-quality frontier)
# ===========================================================================

def _write_multi_model_run(
    base: Path, cell: str, model: str, rep: int,
    *, patterns: list[str] | None = None,
    cost_usd: float = 1.0,
    cost_per_assertion: float | None = 0.05,
) -> Path:
    """Stage-2 mirror of `_write_run` — supports arbitrary model tags
    and parameterised cost_usd (Figure 6 reads this)."""
    run_dir = base / "runs" / cell / model / f"run_{rep:02d}"
    run_dir.mkdir(parents=True, exist_ok=True)
    manifest = {"feature_id": f"synthetic-{cell}-{model}-{rep}",
                "patterns_applied": patterns or []}
    (run_dir / "feature_model.manifest.json").write_text(
        json.dumps(manifest)
    )
    cost = {
        "run_id": cell, "model": model,
        "input_tokens": 1000, "output_tokens": 2000,
        "cost_usd": cost_usd,
        "cost_per_assertion_usd": cost_per_assertion,
        "elapsed_seconds": 100.0,
    }
    (run_dir / "cost_log.json").write_text(json.dumps(cost))
    return run_dir


def _build_multi_model_eval_dir(
    tmp_path: Path,
    *, reps_per_cell: int = 5, seed: int = 99,
) -> tuple[Path, Path]:
    """Synthesise a 3 domains × 3 richness × 3 models tree under tmp_path.

    Strong model gradient (M-best high quality + high cost; M-small
    low quality + low cost). Used for Stage-2 figure tests.
    Returns (results_dir, runs_root).
    """
    rng = random.Random(seed)
    eval_dir = tmp_path / "eval"
    results_dir = eval_dir / "results"
    figures_dir = results_dir / "figures"
    runs_root = eval_dir / "runs"
    results_dir.mkdir(parents=True, exist_ok=True)
    figures_dir.mkdir(parents=True, exist_ok=True)

    model_means = {"M-best": 0.95, "M-mid": 0.80, "M-small": 0.60}
    model_costs = {"M-best": 1.00, "M-mid": 0.30, "M-small": 0.07}
    rich_bump = {"L1": -0.02, "L2": 0.0, "L3": 0.02}

    rows: list[dict] = []
    for dom in ("A", "B", "C"):
        for rich in ("L1", "L2", "L3"):
            cell = f"{dom}-{rich}"
            for model, base_mean in model_means.items():
                base_cost = model_costs[model]
                for rep in range(1, reps_per_cell + 1):
                    aqs = max(0.0, min(1.0,
                        rng.gauss(base_mean + rich_bump[rich], 0.04)))
                    cost_usd = max(
                        0.01,
                        rng.gauss(base_cost, base_cost * 0.1),
                    )
                    _write_multi_model_run(
                        eval_dir, cell, model, rep,
                        patterns=[f"P{i}" for i in range(1, 5)],
                        cost_usd=cost_usd,
                        cost_per_assertion=cost_usd / 25.0,
                    )
                    rows.append({
                        "run_id": f"{cell}/{model}/run_{rep:02d}",
                        "cell": cell, "model": model, "rep": rep,
                        "D1": aqs, "D2": aqs, "D3": aqs, "D4": aqs,
                        "aqs_partial": aqs,
                    })
    _write_all_scores_csv(results_dir / "all_scores.csv", rows)
    (results_dir / "d5_details.json").write_text("{}")
    return results_dir, runs_root


# ---------------------------------------------------------------------------
# Helper coverage
# ---------------------------------------------------------------------------

def test_models_present_in_rows_canonical_order():
    rows = [
        {"model": "M-small"}, {"model": "M-best"}, {"model": "M-mid"},
    ]
    assert visualise.models_present_in_rows(rows) == [
        "M-best", "M-mid", "M-small"
    ]


def test_discover_run_dirs_by_model_partitions_correctly(tmp_path):
    _write_multi_model_run(tmp_path, "A-L1", "M-best", 1)
    _write_multi_model_run(tmp_path, "A-L1", "M-small", 1)
    _write_multi_model_run(tmp_path, "B-L2", "M-mid", 1)
    by_cm = visualise.discover_run_dirs_by_model(tmp_path / "runs")
    assert sorted(by_cm.keys()) == [
        ("A-L1", "M-best"), ("A-L1", "M-small"), ("B-L2", "M-mid"),
    ]
    for paths in by_cm.values():
        assert all(p.is_dir() and p.name.startswith("run_") for p in paths)


def test_collect_cost_per_run_by_model_extracts_cost_usd(tmp_path):
    _write_multi_model_run(tmp_path, "A-L1", "M-best", 1, cost_usd=1.23)
    _write_multi_model_run(tmp_path, "A-L1", "M-best", 2, cost_usd=0.91)
    _write_multi_model_run(tmp_path, "A-L1", "M-mid", 1, cost_usd=0.21)
    by_cm = visualise.discover_run_dirs_by_model(tmp_path / "runs")
    costs = visualise.collect_cost_per_run_by_model(by_cm)
    assert sorted(costs[("A-L1", "M-best")]) == pytest.approx([0.91, 1.23])
    assert costs[("A-L1", "M-mid")] == pytest.approx([0.21])


# ---------------------------------------------------------------------------
# figure_aqs_by_model
# ---------------------------------------------------------------------------

def test_figure_aqs_by_model_writes_png_on_multi_model_fixture(tmp_path):
    results_dir, _ = _build_multi_model_eval_dir(tmp_path)
    rows = visualise.load_all_scores(results_dir / "all_scores.csv")
    out = results_dir / "figures" / "aqs_by_model.png"
    ok, reason = visualise.figure_aqs_by_model(rows, out)
    assert ok, reason
    assert out.exists() and out.stat().st_size > MIN_PNG_SIZE


def test_figure_aqs_by_model_skipped_on_single_model_rows(tmp_path):
    """The Stage-1-only fixture has one model — figure must skip."""
    results_dir, _ = _build_synthetic_eval_dir(tmp_path)
    rows = visualise.load_all_scores(results_dir / "all_scores.csv")
    out = results_dir / "figures" / "aqs_by_model.png"
    ok, reason = visualise.figure_aqs_by_model(rows, out)
    assert ok is False
    assert reason is not None
    assert "≥2 models" in reason or "2 models" in reason


def test_figure_aqs_by_model_skipped_on_empty_rows(tmp_path):
    out = tmp_path / "aqs_by_model.png"
    ok, reason = visualise.figure_aqs_by_model([], out)
    assert ok is False
    assert reason is not None


# ---------------------------------------------------------------------------
# figure_cost_quality_frontier
# ---------------------------------------------------------------------------

def test_figure_cost_quality_frontier_writes_png(tmp_path):
    results_dir, runs_root = _build_multi_model_eval_dir(tmp_path)
    rows = visualise.load_all_scores(results_dir / "all_scores.csv")
    by_cm = visualise.discover_run_dirs_by_model(runs_root)
    cost_by_cm = visualise.collect_cost_per_run_by_model(by_cm)
    out = results_dir / "figures" / "frontier.png"
    ok, reason = visualise.figure_cost_quality_frontier(
        rows, cost_by_cm, out
    )
    assert ok, reason
    assert out.exists() and out.stat().st_size > MIN_PNG_SIZE


def test_figure_cost_quality_frontier_skipped_on_single_model(tmp_path):
    results_dir, runs_root = _build_synthetic_eval_dir(tmp_path)
    rows = visualise.load_all_scores(results_dir / "all_scores.csv")
    by_cm = visualise.discover_run_dirs_by_model(runs_root)
    cost_by_cm = visualise.collect_cost_per_run_by_model(by_cm)
    out = results_dir / "figures" / "frontier.png"
    ok, reason = visualise.figure_cost_quality_frontier(
        rows, cost_by_cm, out
    )
    assert ok is False
    assert reason is not None


def test_figure_cost_quality_frontier_skipped_when_no_overlap(tmp_path):
    """Two models in rows but cost_log only has one — every triple
    misses one half, so no point can be plotted."""
    rows = []
    for model in ("M-best", "M-mid"):
        for rep in range(1, 6):
            rows.append({
                "run_id": f"A-L1/{model}/run_{rep:02d}",
                "cell": "A-L1", "model": model, "rep": rep,
                "domain": "A", "richness": "L1",
                "aqs_partial": 0.9,
            })
    # Empty cost dict for both — no points
    out = tmp_path / "frontier.png"
    ok, reason = visualise.figure_cost_quality_frontier(rows, {}, out)
    # With ≥2 models in rows but no cost data, the function still has
    # ≥2 models from the AQS side; however every (model, richness, dom)
    # triple lacks cost data, so it should report no plottable points.
    assert ok is False
    assert reason is not None


# ---------------------------------------------------------------------------
# Full run() — Stage 2 figures appear on multi-model fixture
# ---------------------------------------------------------------------------

def test_run_writes_stage2_figures_on_multi_model_fixture(tmp_path):
    results_dir, runs_root = _build_multi_model_eval_dir(tmp_path)
    figures_dir = results_dir / "figures"
    outcomes = visualise.run(results_dir, figures_dir, runs_root=runs_root)
    # Stage-1 figures still render.
    assert outcomes["aqs_richness"]["skipped"] is False
    assert outcomes["pattern_coverage"]["skipped"] is False
    assert outcomes["cost_efficiency"]["skipped"] is False
    # Stage-2 figures are produced.
    for key in ("aqs_by_model", "cost_quality_frontier"):
        assert outcomes[key]["skipped"] is False, outcomes[key]
        png_path = Path(outcomes[key]["path"])
        assert png_path.exists()
        assert png_path.stat().st_size > MIN_PNG_SIZE


def test_run_keeps_stage1_only_outcome_when_single_model(tmp_path):
    """The Stage-1-only fixture must still produce the 4 Stage-1 figures
    AND skip the 2 Stage-2 figures cleanly (with reasons)."""
    results_dir, runs_root = _build_synthetic_eval_dir(tmp_path)
    figures_dir = results_dir / "figures"
    outcomes = visualise.run(results_dir, figures_dir, runs_root=runs_root)
    for key in (
        "aqs_richness", "stability_heatmap",
        "pattern_coverage", "cost_efficiency",
    ):
        assert outcomes[key]["skipped"] is False
    for key in ("aqs_by_model", "cost_quality_frontier"):
        assert outcomes[key]["skipped"] is True
        assert outcomes[key]["reason"]

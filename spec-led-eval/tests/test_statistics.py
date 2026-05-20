"""tests/test_statistics.py — pytest coverage for the E5 statistics module.

Covers:
- cohen_d pooled-SD formula on hand-computable fixtures.
- run_kruskal graceful skip when any group is below MIN_N_PER_GROUP.
- run_pairwise_mw Bonferroni correction + Cohen's d labelling.
- compute_stage1_statistics end-to-end on synthetic fixtures:
  * "strong effect" — L1 ~ N(0.5, 0.05), L3 ~ N(0.9, 0.05) — should
    yield p < 0.05, Bonferroni-corrected p < 0.05, |d| ≥ 0.8 (large).
  * "no effect" — all groups sampled from N(0.7, 0.05) — should yield
    p > 0.05 and "negligible" Cohen's d label.
  * "insufficient data" — N=1 row — every test marked `skipped`,
    the run() entry-point exits 0 cleanly.
- Integration: run() against a real `eval/results/` shape produces
  both statistics_report.txt and statistics.json with sensible
  content.
"""

from __future__ import annotations

import csv
import json
import random
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
EVAL_DIR = REPO_ROOT / "eval"
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))

import statistics as stats_module  # type: ignore  # noqa: E402

# Sanity: confirm we loaded the eval/statistics.py, not stdlib.
assert hasattr(stats_module, "compute_stage1_statistics"), (
    "Imported the wrong `statistics` module — eval/ must be on sys.path "
    "before the stdlib."
)


# ---------------------------------------------------------------------------
# Cohen's d
# ---------------------------------------------------------------------------

def test_cohen_d_zero_effect_zero():
    d = stats_module.cohen_d([1.0, 2.0, 3.0], [1.0, 2.0, 3.0])
    assert d == pytest.approx(0.0)


def test_cohen_d_large_positive():
    # Two clearly-separated groups: mean diff ~10, sd ~1, d ~ 10
    a = [10.0, 11.0, 12.0, 13.0, 14.0]
    b = [0.0, 1.0, 2.0, 3.0, 4.0]
    d = stats_module.cohen_d(a, b)
    assert d is not None
    assert d > 5.0  # very large


def test_cohen_d_undefined_below_min_n():
    assert stats_module.cohen_d([1.0], [1.0, 2.0, 3.0]) is None
    assert stats_module.cohen_d([1.0, 2.0, 3.0], [1.0]) is None


def test_cohen_d_label_thresholds():
    # Boundary labels per Cohen 1988
    assert stats_module.cohen_d_label(0.0) == "negligible"
    assert stats_module.cohen_d_label(0.15) == "negligible"
    assert stats_module.cohen_d_label(0.2) == "small"
    assert stats_module.cohen_d_label(0.5) == "medium"
    assert stats_module.cohen_d_label(0.8) == "large"
    assert stats_module.cohen_d_label(-1.5) == "large"
    assert stats_module.cohen_d_label(None) == "undefined"


# ---------------------------------------------------------------------------
# run_kruskal & run_pairwise_mw — primitives
# ---------------------------------------------------------------------------

def test_run_kruskal_skip_when_group_below_min():
    res = stats_module.run_kruskal(
        {"a": [1.0, 2.0], "b": [3.0, 4.0, 5.0]}
    )
    assert res["skipped"] is True
    assert "below n=" in (res["skip_reason"] or "")
    assert res["p"] is None and res["h"] is None


def test_run_kruskal_significant_difference():
    res = stats_module.run_kruskal(
        {"a": [0.1, 0.2, 0.15, 0.18, 0.22],
         "b": [0.9, 0.85, 0.88, 0.92, 0.95]}
    )
    assert res["skipped"] is False
    assert res["p"] is not None
    assert res["p"] < 0.05
    assert res["significant"] is True


def test_run_pairwise_mw_skip_propagates():
    res = stats_module.run_pairwise_mw(
        {"L1": [0.5, 0.6, 0.7], "L2": [], "L3": [0.8]},
        pairs=stats_module._RICHNESS_PAIRS,
        bonferroni_k=3,
    )
    assert res["L1-L2"]["skipped"]
    assert res["L1-L3"]["skipped"]
    assert res["L2-L3"]["skipped"]


def test_run_pairwise_mw_bonferroni_caps_at_one():
    # Identical groups → p_raw close to 1, p × 3 should cap at 1.0.
    res = stats_module.run_pairwise_mw(
        {"L1": [0.5, 0.5, 0.5, 0.5, 0.5],
         "L2": [0.5, 0.5, 0.5, 0.5, 0.5],
         "L3": [0.5, 0.5, 0.5, 0.5, 0.5]},
        pairs=stats_module._RICHNESS_PAIRS,
        bonferroni_k=3,
    )
    for pair in ("L1-L2", "L1-L3", "L2-L3"):
        entry = res[pair]
        assert entry["p_corrected"] is not None
        assert entry["p_corrected"] <= 1.0
        # Identical → not significant
        assert entry["significant"] is False


def test_run_pairwise_mw_cohen_d_signed_and_large():
    res = stats_module.run_pairwise_mw(
        {"L1": [0.45, 0.50, 0.48, 0.52, 0.55],
         "L3": [0.88, 0.90, 0.92, 0.91, 0.89]},
        pairs=(("L1", "L3"),),
        bonferroni_k=3,
    )
    entry = res["L1-L3"]
    assert entry["skipped"] is False
    assert entry["cohen_d"] is not None
    assert entry["cohen_d"] < 0   # L1 mean < L3 mean → negative signed
    assert entry["cohen_d_label"] == "large"
    assert entry["p_corrected"] is not None and entry["p_corrected"] < 0.05
    assert entry["significant"] is True


# ---------------------------------------------------------------------------
# compute_stage1_statistics — synthetic fixtures
# ---------------------------------------------------------------------------

def _build_synthetic_rows(
    *, reps_per_cell: int = 10,
    l1_mean: float = 0.5, l1_sd: float = 0.05,
    l2_mean: float = 0.7, l2_sd: float = 0.05,
    l3_mean: float = 0.9, l3_sd: float = 0.05,
    seed: int = 12345,
) -> list[dict]:
    """3 domains × 3 richness × `reps_per_cell` reps. Deterministic
    via the supplied seed so tests are reproducible."""
    rng = random.Random(seed)
    means = {"L1": l1_mean, "L2": l2_mean, "L3": l3_mean}
    sds = {"L1": l1_sd, "L2": l2_sd, "L3": l3_sd}
    rows: list[dict] = []
    for dom in ("A", "B", "C"):
        for rich in ("L1", "L2", "L3"):
            for rep in range(1, reps_per_cell + 1):
                v = rng.gauss(means[rich], sds[rich])
                v = max(0.0, min(1.0, v))
                rows.append({
                    "run_id": f"{dom}-{rich}/M-best/run_{rep:02d}",
                    "cell": f"{dom}-{rich}",
                    "model": "M-best",
                    "rep": rep,
                    "domain": dom,
                    "richness": rich,
                    "D1": v, "D2": v, "D3": v, "D4": v,
                    "aqs_partial": v,
                })
    return rows


def test_compute_stage1_strong_effect():
    rows = _build_synthetic_rows()
    stats = stats_module.compute_stage1_statistics(rows, d5_details={})

    assert stats["n_total_runs"] == 90
    overall = stats["tests"]["overall_richness"]
    assert overall["skipped"] is False
    assert overall["p"] < 0.05
    assert overall["significant"] is True

    pairwise = stats["tests"]["pairwise_richness_aqs"]
    l1_l3 = pairwise["L1-L3"]
    assert l1_l3["skipped"] is False
    assert l1_l3["p_corrected"] is not None
    assert l1_l3["p_corrected"] < 0.05
    assert l1_l3["cohen_d"] is not None
    assert abs(l1_l3["cohen_d"]) >= 0.8
    assert l1_l3["cohen_d_label"] == "large"
    assert l1_l3["significant"] is True


def test_compute_stage1_no_effect():
    # All three groups drawn from the same distribution.
    rows = _build_synthetic_rows(
        l1_mean=0.7, l2_mean=0.7, l3_mean=0.7,
        l1_sd=0.05, l2_sd=0.05, l3_sd=0.05,
        seed=42,
    )
    stats = stats_module.compute_stage1_statistics(rows, d5_details={})
    overall = stats["tests"]["overall_richness"]
    assert overall["skipped"] is False
    assert overall["p"] is not None
    assert overall["p"] > 0.05
    assert overall["significant"] is False

    pairwise = stats["tests"]["pairwise_richness_aqs"]
    for pair_key in ("L1-L2", "L1-L3", "L2-L3"):
        entry = pairwise[pair_key]
        assert entry["skipped"] is False
        assert entry["p_corrected"] is not None
        # Could occasionally drop below 0.05, but with these means we
        # expect "no effect" → at minimum, the effect size should be
        # negligible-or-small.
        assert entry["cohen_d_label"] in ("negligible", "small")


def test_compute_stage1_insufficient_data_skipped_not_crashed():
    rows = [{
        "run_id": "A-L1/M-best/run_01",
        "cell": "A-L1", "model": "M-best", "rep": 1,
        "domain": "A", "richness": "L1",
        "D1": 1.0, "D2": 1.0, "D3": 1.0, "D4": 0.97,
        "aqs_partial": 0.99,
    }]
    stats = stats_module.compute_stage1_statistics(rows, d5_details={})
    overall = stats["tests"]["overall_richness"]
    assert overall["skipped"] is True
    assert overall["p"] is None
    # Pairwise tests should also gracefully skip
    pairwise = stats["tests"]["pairwise_richness_aqs"]
    for pair_key in ("L1-L2", "L1-L3", "L2-L3"):
        assert pairwise[pair_key]["skipped"] is True


# ---------------------------------------------------------------------------
# D5 grouping by richness
# ---------------------------------------------------------------------------

def test_d5_stabilities_by_richness_qualifying_only():
    d5 = {
        "A-L1/M-best": {
            "n_runs": 10,
            "per_key": {
                "K1": {"stability": 0.9, "qualifies": True},
                "K2": {"stability": 0.6, "qualifies": False},
            },
        },
        "B-L3/M-best": {
            "n_runs": 10,
            "per_key": {
                "K3": {"stability": 0.95, "qualifies": True},
            },
        },
    }
    out = stats_module.d5_stabilities_by_richness(d5, qualifying_only=True)
    assert out["L1"] == [0.9]
    assert out["L3"] == [0.95]
    assert out["L2"] == []
    # Now with qualifying_only=False
    out2 = stats_module.d5_stabilities_by_richness(d5, qualifying_only=False)
    assert sorted(out2["L1"]) == [0.6, 0.9]
    assert out2["L3"] == [0.95]


# ---------------------------------------------------------------------------
# load_all_scores + run() end-to-end on synthetic CSV
# ---------------------------------------------------------------------------

def _write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["run_id", "cell", "model", "rep",
              "D1", "D2", "D3", "D4", "aqs_partial"]
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k) for k in fields})


def test_load_all_scores_parses_cell_and_coerces_floats(tmp_path):
    csv_path = tmp_path / "all_scores.csv"
    _write_csv(csv_path, [
        {"run_id": "A-L2/M-best/run_03", "cell": "A-L2", "model": "M-best",
         "rep": 3, "D1": 1.0, "D2": 0.5, "D3": 1.0, "D4": 0.7,
         "aqs_partial": 0.8},
    ])
    rows = stats_module.load_all_scores(csv_path)
    assert len(rows) == 1
    assert rows[0]["domain"] == "A" and rows[0]["richness"] == "L2"
    assert rows[0]["aqs_partial"] == pytest.approx(0.8)


def test_load_all_scores_skips_unparseable_cells(tmp_path, capsys):
    csv_path = tmp_path / "all_scores.csv"
    _write_csv(csv_path, [
        {"run_id": "Z-X9/M-best/run_01", "cell": "Z-X9", "model": "M-best",
         "rep": 1, "D1": 1.0, "D2": 1.0, "D3": 1.0, "D4": 1.0,
         "aqs_partial": 1.0},
        {"run_id": "A-L1/M-best/run_01", "cell": "A-L1", "model": "M-best",
         "rep": 1, "D1": 1.0, "D2": 1.0, "D3": 1.0, "D4": 1.0,
         "aqs_partial": 1.0},
    ])
    rows = stats_module.load_all_scores(csv_path)
    assert len(rows) == 1
    assert rows[0]["cell"] == "A-L1"


def test_run_entrypoint_writes_report_and_json_strong_effect(tmp_path):
    results_dir = tmp_path / "results"
    rows = _build_synthetic_rows()
    _write_csv(results_dir / "all_scores.csv", rows)
    # Synthesise a tiny d5_details with qualifying entries
    d5 = {
        "A-L1/M-best": {
            "n_runs": 10, "min_appearances": 5,
            "per_key": {
                "K1": {"stability": 0.5, "qualifies": True},
                "K2": {"stability": 0.45, "qualifies": True},
                "K3": {"stability": 0.55, "qualifies": True},
            },
        },
        "A-L3/M-best": {
            "n_runs": 10, "min_appearances": 5,
            "per_key": {
                "K1": {"stability": 0.95, "qualifies": True},
                "K2": {"stability": 0.92, "qualifies": True},
                "K3": {"stability": 0.97, "qualifies": True},
            },
        },
    }
    (results_dir / "d5_details.json").write_text(json.dumps(d5))

    stats = stats_module.run(results_dir)
    report_path = results_dir / "statistics_report.txt"
    json_path = results_dir / "statistics.json"
    assert report_path.exists()
    assert json_path.exists()

    # JSON shape
    on_disk = json.loads(json_path.read_text())
    assert on_disk["n_total_runs"] == 90
    overall = on_disk["tests"]["overall_richness"]
    assert overall["p"] < 0.05
    # Report content sanity
    txt = report_path.read_text()
    assert "Stage 1 statistics report" in txt
    assert "Section 1 — Overall richness effect" in txt
    assert "Kruskal-Wallis" in txt


def test_run_entrypoint_handles_missing_inputs(tmp_path):
    """When the results dir is empty, run() must exit 0 and write a
    'no data' report."""
    results_dir = tmp_path / "results"
    results_dir.mkdir()
    stats = stats_module.run(results_dir)
    assert stats["n_total_runs"] == 0
    report = (results_dir / "statistics_report.txt").read_text()
    assert "Insufficient data" in report


def test_run_entrypoint_handles_real_n1_smoke(tmp_path):
    """Mimic the live A-L1/run_01 state (N=1) — every test skipped,
    exit clean."""
    results_dir = tmp_path / "results"
    _write_csv(results_dir / "all_scores.csv", [{
        "run_id": "A-L1/M-best/run_01", "cell": "A-L1", "model": "M-best",
        "rep": 1, "D1": 1.0, "D2": 1.0, "D3": 1.0, "D4": 0.9706,
        "aqs_partial": 0.9926,
    }])
    (results_dir / "d5_details.json").write_text(json.dumps({
        "A-L1/M-best": {"n_runs": 1, "per_key": {}}
    }))
    stats = stats_module.run(results_dir)
    assert stats["n_total_runs"] == 1
    assert stats["tests"]["overall_richness"]["skipped"] is True
    # Output files exist and are non-empty.
    assert (results_dir / "statistics_report.txt").stat().st_size > 0
    assert (results_dir / "statistics.json").stat().st_size > 0


# ===========================================================================
# Stage 2 (H5/H6/H7) — model factor tests
# ===========================================================================

def _build_multi_model_rows(
    *, reps_per_cell: int = 10,
    model_means: dict | None = None,
    sd: float = 0.05,
    seed: int = 31415,
) -> list[dict]:
    """3 domains × 3 richness × N models × reps. Default `model_means`
    gives a strong model gradient (M-best=0.95, M-mid=0.80, M-small=0.60)
    so the H5 Kruskal should detect significance.

    Each combination is sampled independently so within-cell variance
    is real rather than zero (the cohen_d pooled-SD formula breaks
    when both groups have variance 0).
    """
    if model_means is None:
        model_means = {"M-best": 0.95, "M-mid": 0.80, "M-small": 0.60}
    rng = random.Random(seed)
    rows: list[dict] = []
    for dom in ("A", "B", "C"):
        for rich in ("L1", "L2", "L3"):
            for model, base_mean in model_means.items():
                # Add a small richness-conditional bump so the per-richness
                # slices have a model gradient at every richness level
                # (otherwise H5 per-richness would be entirely driven by
                # the pooled distribution).
                rich_bump = {"L1": -0.02, "L2": 0.0, "L3": 0.02}[rich]
                mean = max(0.0, min(1.0, base_mean + rich_bump))
                for rep in range(1, reps_per_cell + 1):
                    v = max(0.0, min(1.0, rng.gauss(mean, sd)))
                    rows.append({
                        "run_id": f"{dom}-{rich}/{model}/run_{rep:02d}",
                        "cell": f"{dom}-{rich}",
                        "model": model, "rep": rep,
                        "domain": dom, "richness": rich,
                        "D1": v, "D2": v, "D3": v, "D4": v,
                        "aqs_partial": v,
                    })
    return rows


# ---------------------------------------------------------------------------
# Helper / primitive coverage
# ---------------------------------------------------------------------------

def test_models_present_canonical_order():
    rows = [
        {"model": "M-small"}, {"model": "M-best"}, {"model": "M-mid"},
        {"model": "M-best"},
    ]
    assert stats_module.models_present(rows) == ["M-best", "M-mid", "M-small"]


def test_models_present_unknown_model_appended_alphabetically():
    rows = [{"model": "M-best"}, {"model": "Z-ad-hoc"}, {"model": "M-mid"}]
    assert stats_module.models_present(rows) == ["M-best", "M-mid", "Z-ad-hoc"]


def test_models_present_empty_rows():
    assert stats_module.models_present([]) == []
    assert stats_module.models_present([{"model": None}]) == []


def test_model_pairs_three_models():
    assert stats_module.model_pairs(["M-best", "M-mid", "M-small"]) == [
        ("M-best", "M-mid"),
        ("M-best", "M-small"),
        ("M-mid", "M-small"),
    ]


def test_model_pairs_two_models_one_pair():
    assert stats_module.model_pairs(["M-best", "M-mid"]) == [
        ("M-best", "M-mid"),
    ]
    assert stats_module.model_pairs(["M-best"]) == []
    assert stats_module.model_pairs([]) == []


def test_d5_stabilities_by_model_pivots_correctly():
    d5 = {
        "A-L1/M-best": {
            "per_key": {
                "K1": {"stability": 0.95, "qualifies": True},
                "K2": {"stability": 0.6,  "qualifies": False},
            },
        },
        "B-L2/M-small": {
            "per_key": {
                "K3": {"stability": 0.70, "qualifies": True},
            },
        },
    }
    out = stats_module.d5_stabilities_by_model(d5, qualifying_only=True)
    assert sorted(out["M-best"]) == [0.95]
    assert sorted(out["M-small"]) == [0.70]
    # qualifying_only=False brings in K2 too
    out2 = stats_module.d5_stabilities_by_model(d5, qualifying_only=False)
    assert sorted(out2["M-best"]) == [0.6, 0.95]


# ---------------------------------------------------------------------------
# compute_stage2_statistics — strong/no/insufficient
# ---------------------------------------------------------------------------

def test_compute_stage2_strong_model_effect():
    rows = _build_multi_model_rows()
    stage2 = stats_module.compute_stage2_statistics(rows, d5_details={})
    assert stage2["models_present"] == ["M-best", "M-mid", "M-small"]

    overall = stage2["tests"]["model_effect_overall"]
    assert overall["skipped"] is False
    assert overall["p"] is not None and overall["p"] < 0.05
    assert overall["significant"] is True

    pairwise = stage2["tests"]["pairwise_model_aqs"]
    assert pairwise["_meta"]["bonferroni_k"] == 3
    best_small = pairwise["M-best-M-small"]
    assert best_small["skipped"] is False
    assert best_small["cohen_d"] is not None
    assert abs(best_small["cohen_d"]) >= 0.8
    assert best_small["cohen_d_label"] == "large"
    assert best_small["significant"] is True

    # Per-richness slices should each detect the gradient
    for rich in ("L1", "L2", "L3"):
        res = stage2["tests"]["model_effect_per_richness"][rich]
        assert res["skipped"] is False
        assert res["p"] is not None and res["p"] < 0.05


def test_compute_stage2_no_model_effect():
    rows = _build_multi_model_rows(
        model_means={"M-best": 0.80, "M-mid": 0.80, "M-small": 0.80},
        sd=0.05, seed=7,
    )
    stage2 = stats_module.compute_stage2_statistics(rows, d5_details={})
    overall = stage2["tests"]["model_effect_overall"]
    assert overall["skipped"] is False
    assert overall["p"] is not None and overall["p"] > 0.05
    pairwise = stage2["tests"]["pairwise_model_aqs"]
    for pair_key in ("M-best-M-mid", "M-best-M-small", "M-mid-M-small"):
        entry = pairwise[pair_key]
        assert entry["skipped"] is False
        assert entry["cohen_d_label"] in ("negligible", "small")


def test_compute_stage2_two_models_pair_k_equals_one():
    """When only two models are present, Bonferroni k is 1 (no
    correction needed because k pairs = 1)."""
    rows = _build_multi_model_rows(
        model_means={"M-best": 0.95, "M-mid": 0.80},
    )
    stage2 = stats_module.compute_stage2_statistics(rows, d5_details={})
    pairwise = stage2["tests"]["pairwise_model_aqs"]
    assert pairwise["_meta"]["bonferroni_k"] == 1


# ---------------------------------------------------------------------------
# H6 lever comparison
# ---------------------------------------------------------------------------

def test_h6_lever_comparison_with_full_data():
    rows = _build_multi_model_rows()
    stage2 = stats_module.compute_stage2_statistics(rows, d5_details={})
    h6 = stage2["tests"]["h6_lever_comparison"]
    assert h6["skipped"] is False
    assert h6["model_lever"]["cohen_d"] is not None
    assert h6["richness_lever"]["cohen_d"] is not None
    assert h6["winner"] in ("model", "richness", "tie")
    # With model_means much larger than the richness bump (±0.02), the
    # model lever should dominate.
    assert h6["winner"] == "model"


def test_h6_lever_comparison_skipped_without_m_small():
    rows = _build_multi_model_rows(
        model_means={"M-best": 0.95, "M-mid": 0.80},
    )
    stage2 = stats_module.compute_stage2_statistics(rows, d5_details={})
    h6 = stage2["tests"]["h6_lever_comparison"]
    assert h6["skipped"] is True
    assert "model_lever" in (h6["skip_reason"] or "")


def test_h6_lever_comparison_skipped_when_m_best_absent():
    # Fully Sonnet/Haiku universe → no M-best, so richness lever also
    # missing
    rows = _build_multi_model_rows(
        model_means={"M-mid": 0.80, "M-small": 0.60},
    )
    stage2 = stats_module.compute_stage2_statistics(rows, d5_details={})
    h6 = stage2["tests"]["h6_lever_comparison"]
    assert h6["skipped"] is True


# ---------------------------------------------------------------------------
# Integration — compute_stage1_statistics auto-merges Stage 2 keys
# ---------------------------------------------------------------------------

def test_compute_stage1_single_model_does_not_emit_stage2():
    """Backward compatibility: with only M-best present, the output dict
    must NOT contain any Stage 2 keys — exactly the E5-era shape."""
    rows = _build_synthetic_rows()
    stats = stats_module.compute_stage1_statistics(rows, d5_details={})
    for key in (
        "model_effect_overall",
        "model_effect_per_richness",
        "model_effect_per_domain",
        "pairwise_model_aqs",
        "h6_lever_comparison",
        "d5_stability_model",
        "pairwise_d5_model",
    ):
        assert key not in stats["tests"], (
            f"Stage 2 key {key} leaked into single-model stats output"
        )
    assert stats.get("models_present") == ["M-best"]


def test_compute_stage1_multi_model_merges_stage2_keys():
    rows = _build_multi_model_rows()
    stats = stats_module.compute_stage1_statistics(rows, d5_details={})
    # Stage 1 keys still present
    assert "overall_richness" in stats["tests"]
    # Stage 2 keys merged in
    for key in (
        "model_effect_overall",
        "model_effect_per_richness",
        "model_effect_per_domain",
        "pairwise_model_aqs",
        "h6_lever_comparison",
        "d5_stability_model",
        "pairwise_d5_model",
    ):
        assert key in stats["tests"], (
            f"missing Stage 2 key {key} on multi-model fixture"
        )
    assert stats["models_present"] == ["M-best", "M-mid", "M-small"]


def test_render_report_includes_stage2_sections_when_present():
    rows = _build_multi_model_rows()
    stats = stats_module.compute_stage1_statistics(rows, d5_details={})
    report = stats_module.render_report(stats)
    assert "Section 5 — Model effect on AQS (H5)" in report
    assert "Section 6 — Lever comparison (H6: model vs richness)" in report
    assert "Section 7 — D5 verdict-stability by model (H7)" in report
    # H6 winner / Cohen's d block should mention both levers
    assert "Model lever" in report
    assert "Richness lever" in report


def test_render_report_excludes_stage2_sections_when_single_model():
    rows = _build_synthetic_rows()
    stats = stats_module.compute_stage1_statistics(rows, d5_details={})
    report = stats_module.render_report(stats)
    assert "Section 5" not in report
    assert "Section 6" not in report
    assert "Section 7" not in report


# ---------------------------------------------------------------------------
# Integration end-to-end via run()
# ---------------------------------------------------------------------------

def test_run_writes_stage2_blocks_to_json_and_report(tmp_path):
    results_dir = tmp_path / "results"
    rows = _build_multi_model_rows()
    _write_csv(results_dir / "all_scores.csv", rows)
    # d5 with qualifying entries that have a model gradient
    d5 = {}
    for dom in ("A", "B", "C"):
        for rich in ("L1", "L2", "L3"):
            cell = f"{dom}-{rich}"
            for model, base in (
                ("M-best", 0.98), ("M-mid", 0.93), ("M-small", 0.75),
            ):
                d5[f"{cell}/{model}"] = {
                    "n_runs": 10, "min_appearances": 5,
                    "per_key": {
                        f"K{n}": {
                            "stability": max(0.0, min(1.0,
                                base + 0.01 * n - 0.02)),
                            "qualifies": True,
                        }
                        for n in range(1, 6)
                    },
                }
    (results_dir / "d5_details.json").write_text(json.dumps(d5))

    stats = stats_module.run(results_dir)
    on_disk = json.loads(
        (results_dir / "statistics.json").read_text()
    )
    assert "model_effect_overall" in on_disk["tests"]
    assert on_disk["models_present"] == ["M-best", "M-mid", "M-small"]
    txt = (results_dir / "statistics_report.txt").read_text()
    assert "Section 5 — Model effect on AQS (H5)" in txt
    assert "Section 7 — D5 verdict-stability by model (H7)" in txt

"""
test_scorer.py
--------------
Pytest tests for scorer.py covering all required cases:
  - perfect score
  - inverted direction (D3 = 0.0)
  - null threshold (D1 = 0.0)
  - plus additional edge cases for robustness

Run from project root:
    pytest eval/tests/test_scorer.py -v
"""

import sys
from pathlib import Path

# Allow importing scorer.py from the eval/ directory
sys.path.insert(0, str(Path(__file__).parent.parent))

from scorer import (
    score_d1,
    score_d2,
    score_d3,
    score_pair,
    score_run,
)
from aggregate import compute_d4


# ── Fixture factories ──────────────────────────────────────────────────────────

def make_gqm(**overrides) -> dict:
    """Return a default well-formed gqm_record, with optional field overrides."""
    defaults = {
        "id":            "gqm-001",
        "waf_code_refs": ["SE:05", "SE:09"],
        "pillar_id":     "security",
        "metric_name":   "auth_coverage_percentage",
        "metric_unit":   "percentage",
    }
    return {**defaults, **overrides}


def make_kpi(**overrides) -> dict:
    """Return a default well-formed kpi_record, with optional field overrides."""
    defaults = {
        "id":                  "kpi-001",
        "gqm_id":              "gqm-001",
        "pillar_id":           "security",
        "threshold_value":     ">= 100%",
        "threshold_numeric":   100.0,
        "threshold_direction": "gte",
        "notes":               "Derived from: FR-001: ensure full auth coverage.",
    }
    return {**defaults, **overrides}


# ══════════════════════════════════════════════════════════════════════════════
# D1 — Threshold specificity
# ══════════════════════════════════════════════════════════════════════════════

class TestD1:
    def test_perfect_gte_nonzero(self):
        """Numeric present, direction gte, value > 0 → 1.0."""
        assert score_d1(make_kpi(threshold_numeric=100.0, threshold_direction="gte")) == 1.0

    def test_perfect_lte_nonzero(self):
        """Numeric present, direction lte, value in (0, 999999) → 1.0."""
        assert score_d1(make_kpi(threshold_numeric=200.0, threshold_direction="lte")) == 1.0

    def test_null_threshold_case(self):
        """Both threshold_numeric and threshold_value are null → 0.0."""
        assert score_d1(make_kpi(threshold_numeric=None, threshold_value=None)) == 0.0

    def test_null_numeric_with_string_value(self):
        """threshold_value present but threshold_numeric is null → 0.5."""
        assert score_d1(make_kpi(threshold_numeric=None, threshold_value="<= 200ms")) == 0.5

    def test_vague_language_acceptable(self):
        """threshold_value contains 'acceptable' → 0.0."""
        assert score_d1(make_kpi(threshold_numeric=None, threshold_value="within acceptable limits")) == 0.0

    def test_vague_language_reasonable(self):
        """threshold_value contains 'reasonable' → 0.0."""
        assert score_d1(make_kpi(threshold_numeric=None, threshold_value="reasonable response time")) == 0.0

    def test_trivial_gte_zero(self):
        """direction=gte but threshold_numeric=0 is trivial → 0.0."""
        assert score_d1(make_kpi(threshold_numeric=0.0, threshold_direction="gte")) == 0.0

    def test_trivial_lte_upper_bound(self):
        """direction=lte but threshold_numeric=999999 is the sentinel trivial upper → 0.0."""
        assert score_d1(make_kpi(threshold_numeric=999999.0, threshold_direction="lte")) == 0.0

    def test_lte_large_but_valid(self):
        """direction=lte, value=5000 is non-trivial → 1.0."""
        assert score_d1(make_kpi(threshold_numeric=5000.0, threshold_direction="lte")) == 1.0


# ══════════════════════════════════════════════════════════════════════════════
# D2 — Directionality coherence
# ══════════════════════════════════════════════════════════════════════════════

class TestD2:
    def test_coherent_latency_lte(self):
        """Latency metric + lte direction → coherent → 1.0."""
        kpi = make_kpi(threshold_direction="lte")
        gqm = make_gqm(metric_name="api_latency_ms", metric_unit="milliseconds")
        assert score_d2(kpi, gqm) == 1.0

    def test_inverted_direction_case(self):
        """Latency metric with gte (wrong direction for latency) → 0.0."""
        kpi = make_kpi(threshold_direction="gte")
        gqm = make_gqm(metric_name="request_latency_ms", metric_unit="milliseconds")
        assert score_d2(kpi, gqm) == 0.0

    def test_coherent_coverage_gte(self):
        """Coverage metric + gte direction → coherent → 1.0."""
        kpi = make_kpi(threshold_direction="gte")
        gqm = make_gqm(metric_name="auth_coverage_percentage", metric_unit="percentage")
        assert score_d2(kpi, gqm) == 1.0

    def test_inverted_coverage_lte(self):
        """Coverage metric with lte direction → wrong → 0.0."""
        kpi = make_kpi(threshold_direction="lte")
        gqm = make_gqm(metric_name="service_uptime_percentage", metric_unit="percentage")
        assert score_d2(kpi, gqm) == 0.0

    def test_no_keyword_match_benefit_of_doubt(self):
        """Metric name matches no keyword list → benefit of doubt → 1.0."""
        kpi = make_kpi(threshold_direction="gte")
        gqm = make_gqm(metric_name="custom_novel_index", metric_unit="count")
        assert score_d2(kpi, gqm) == 1.0

    def test_unit_fallback_when_name_has_no_match(self):
        """metric_name has no keywords; metric_unit='milliseconds' → expect lte."""
        kpi = make_kpi(threshold_direction="lte")
        gqm = make_gqm(metric_name="p95_response", metric_unit="milliseconds")
        assert score_d2(kpi, gqm) == 1.0

    def test_unit_fallback_inverted(self):
        """metric_name has no keywords; metric_unit='milliseconds'; direction gte → 0.0."""
        kpi = make_kpi(threshold_direction="gte")
        gqm = make_gqm(metric_name="p99_response", metric_unit="milliseconds")
        assert score_d2(kpi, gqm) == 0.0


# ══════════════════════════════════════════════════════════════════════════════
# D3 — GQM chain coherence
# ══════════════════════════════════════════════════════════════════════════════

class TestD3:
    def test_perfect_snake_case_valid_unit(self):
        """snake_case metric_name + valid unit → 1.0."""
        assert score_d3(make_gqm(metric_name="auth_coverage_percentage", metric_unit="percentage")) == 1.0

    def test_readable_not_snake_case(self):
        """Spaces in metric_name, valid unit → 0.5."""
        assert score_d3(make_gqm(metric_name="p95 API response time", metric_unit="milliseconds")) == 0.5

    def test_mixed_case_not_snake(self):
        """CamelCase metric_name, valid unit → 0.5."""
        assert score_d3(make_gqm(metric_name="AuthCoveragePercentage", metric_unit="percentage")) == 0.5

    def test_sentence_fragment_with_verb(self):
        """metric_name contains verb 'is' → sentence fragment → 0.0."""
        assert score_d3(make_gqm(metric_name="is the system available", metric_unit="percentage")) == 0.0

    def test_sentence_with_should(self):
        """metric_name is a space-separated sentence starting with 'should' → 0.0."""
        assert score_d3(make_gqm(metric_name="should return within limits", metric_unit="milliseconds")) == 0.0

    def test_missing_metric_unit(self):
        """metric_unit is None → 0.0."""
        assert score_d3(make_gqm(metric_name="auth_coverage_percentage", metric_unit=None)) == 0.0

    def test_invalid_metric_unit(self):
        """metric_unit not in valid set → 0.0."""
        assert score_d3(make_gqm(metric_name="auth_coverage", metric_unit="requests_per_second")) == 0.0

    def test_valid_units_all_accepted(self):
        """Each valid unit string should not penalise an otherwise-perfect name."""
        for unit in ("percentage", "milliseconds", "seconds", "hours", "currency", "count"):
            result = score_d3(make_gqm(metric_name="some_metric_value", metric_unit=unit))
            assert result == 1.0, f"unit '{unit}' was rejected unexpectedly"


# ══════════════════════════════════════════════════════════════════════════════
# Perfect score case (all dimensions = 1.0)
# ══════════════════════════════════════════════════════════════════════════════

class TestScorePair:
    def test_perfect_score_case(self):
        """All three kqs_partial dimensions should be 1.0 for a well-formed pair."""
        kpi = make_kpi()
        gqm = make_gqm()
        result = score_pair(kpi, gqm, "A-L1", "A-L1_run_01")
        assert result["d1"] == 1.0
        assert result["d2"] == 1.0
        assert result["d3"] == 1.0
        assert result["kqs_partial"] == 1.0

    def test_null_gqm_drops_gqm_dimensions(self):
        """Missing gqm_record → d2, d3 all 0.0."""
        kpi = make_kpi()
        result = score_pair(kpi, None, "A-L1", "A-L1_run_01")
        assert result["d2"] == 0.0
        assert result["d3"] == 0.0

    def test_spec_id_parsed_correctly(self):
        """context and richness are parsed from spec_id."""
        result = score_pair(make_kpi(), make_gqm(), "C-L3", "C-L3_run_05")
        assert result["context"]  == "C"
        assert result["richness"] == "L3"

    def test_fr_id_extracted_from_notes(self):
        """FR id is extracted from the notes field."""
        kpi = make_kpi(notes="Derived from: FR-002: some requirement text.")
        result = score_pair(kpi, make_gqm(), "B-L2", "B-L2_run_01")
        assert result["fr_id"] == "FR-002"

    def test_fr_id_unknown_when_notes_missing(self):
        """No FR pattern in notes → fr_id='unknown'."""
        kpi = make_kpi(notes="No FR reference here.")
        result = score_pair(kpi, make_gqm(), "A-L1", "A-L1_run_01")
        assert result["fr_id"] == "unknown"

    def test_kqs_partial_is_three_dim_mean(self):
        """kqs_partial = mean(d1, d2, d3) to 4 decimal places."""
        kpi = make_kpi(threshold_numeric=None, threshold_value="<= 200ms",
                       threshold_direction="lte")
        gqm = make_gqm(metric_name="api_latency_ms", metric_unit="milliseconds")
        result = score_pair(kpi, gqm, "B-L3", "B-L3_run_07")
        expected = round((result["d1"] + result["d2"] + result["d3"]) / 3, 4)
        assert result["kqs_partial"] == expected


class TestScoreRun:
    def test_score_run_returns_one_entry_per_kpi(self):
        """score_run should yield one scored record per kpi_record."""
        gqm = [make_gqm()]
        kpis = [make_kpi(), make_kpi(id="kpi-002")]
        results = score_run("A-L1", 1, gqm, kpis)
        assert len(results) == 2

    def test_score_run_empty_kpis(self):
        """Empty kpi_records → empty result list."""
        results = score_run("A-L1", 1, [make_gqm()], [])
        assert results == []

    def test_score_run_run_id_format(self):
        """run_id should follow the A-L1_run_03 format."""
        results = score_run("A-L2", 3, [make_gqm()], [make_kpi()])
        assert results[0]["run_id"] == "A-L2_run_03"


# ══════════════════════════════════════════════════════════════════════════════
# D4 — Monte Carlo stability (from aggregate.py)
# ══════════════════════════════════════════════════════════════════════════════

class TestComputeD4:
    def test_identical_values_perfectly_stable(self):
        """All identical → std=0 → cv=0 → D4=1.0."""
        assert compute_d4([100.0, 100.0, 100.0]) == 1.0

    def test_insufficient_data(self):
        """< 2 values → D4=0.5."""
        assert compute_d4([]) == 0.5
        assert compute_d4([100.0]) == 0.5

    def test_high_variance_approaches_zero(self):
        """Very high variance → cv ≈ 1 → D4 close to 0 (clamped floor is 0.0)."""
        result = compute_d4([1.0, 1000.0])
        assert result < 0.1

    def test_zero_mean_returns_zero(self):
        """Mean=0 → cv undefined → D4=0.0."""
        assert compute_d4([0.0, 0.0]) == 0.0

    def test_low_variance_near_one(self):
        """Low variance around a non-zero mean → D4 close to 1.0."""
        result = compute_d4([99.0, 100.0, 101.0, 100.0, 99.5])
        assert result > 0.9

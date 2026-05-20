"""tests/test_scorer.py — pytest coverage for the E3 AQS scorer.

Synthesises minimal run directories on a `tmp_path` for the D1, D2, D3, D4
edge cases, plus one integration test against the real A-L1/M-best/run_01
fixture produced by the E2 live smoke test.

All tests run fully offline — no API access required.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import pytest

# Make `eval/scorer.py` importable. The scorer file is a thin module that
# expects `<repo>` to be on `sys.path` (it inserts it itself), but pytest
# can also load it directly.
REPO_ROOT = Path(__file__).resolve().parent.parent
EVAL_DIR = REPO_ROOT / "eval"
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import scorer  # type: ignore  # noqa: E402  — loaded from eval/scorer.py


REAL_RUN = REPO_ROOT / "eval" / "runs" / "A-L1" / "M-best" / "run_01"


# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

def _write_run(
    base: Path,
    *,
    cell: str = "X-L1",
    model: str = "M-best",
    rep: int = 1,
    als_text: str = "",
    manifest: dict | None = None,
    verdicts: dict | None = None,
    mutation_outcomes: dict | None = None,
    cost_log: dict | None = None,
    spec_md: str | None = None,
    patterns_md: str | None = None,
) -> Path:
    """Materialise a fake eval-root layout under `base` and return run_dir.

    The layout mirrors the real one:
        base/
          eval/
            runs/<cell>/<model>/run_NN/{als, manifest, verdicts, mut, cost}
            specs/<cell>/spec.md
          patterns.md
    """
    run_dir = base / "eval" / "runs" / cell / model / f"run_{rep:02d}"
    run_dir.mkdir(parents=True, exist_ok=True)

    (run_dir / "feature_model.als").write_text(als_text, encoding="utf-8")
    (run_dir / "feature_model.manifest.json").write_text(
        json.dumps(manifest or {}), encoding="utf-8"
    )
    if verdicts is not None:
        (run_dir / "alloy_verdicts.json").write_text(
            json.dumps(verdicts), encoding="utf-8"
        )
    if mutation_outcomes is not None:
        (run_dir / "mutation_outcomes.json").write_text(
            json.dumps(mutation_outcomes), encoding="utf-8"
        )
    (run_dir / "cost_log.json").write_text(
        json.dumps(cost_log or {"run_id": cell, "cost_usd": 0.0}),
        encoding="utf-8",
    )

    spec_dir = base / "eval" / "specs" / cell
    spec_dir.mkdir(parents=True, exist_ok=True)
    if spec_md is None:
        spec_md = (
            "# Feature Specification: Synthetic\n\n"
            "### User Story 1 - Smoke (Priority: P1)\n\n"
            "## Requirements\n\n"
            "### Functional Requirements\n\n"
            "- **FR-001**: Synthetic requirement one.\n"
            "- **FR-002**: Synthetic requirement two.\n"
        )
    (spec_dir / "spec.md").write_text(spec_md, encoding="utf-8")

    if patterns_md is None:
        patterns_md = (
            "# Verification Pattern Catalogue\n\n"
            "## Patterns\n\n"
            "### LeastPrivilege\n\n- description\n\n"
            "### AuditCompleteness\n\n- description\n\n"
        )
    (base / "patterns.md").write_text(patterns_md, encoding="utf-8")

    return run_dir


# ---------------------------------------------------------------------------
# D1 — Compilability
# ---------------------------------------------------------------------------

def test_d1_parse_fail_empty_verdicts(tmp_path: Path) -> None:
    """Empty alloy_verdicts.json → D1 = 0.0 (PARSE_FAIL)."""
    run_dir = _write_run(
        tmp_path,
        als_text="assert Foo { some none } check Foo for 3\n",
        verdicts={},                       # PARSE_FAIL signal
    )
    scores = scorer.score_run(run_dir)
    assert scores["D1"] == 0.0


def test_d1_zero_asserts_in_als(tmp_path: Path) -> None:
    """A non-empty .als with no `assert` declarations → D1 = 0.5."""
    run_dir = _write_run(
        tmp_path,
        als_text="sig Foo {}\npred P { some Foo }\n",   # no asserts
        verdicts={},
    )
    scores = scorer.score_run(run_dir)
    assert scores["D1"] == 0.5


def test_d1_full_pass(tmp_path: Path) -> None:
    """Verdicts non-empty AND ≥ 1 assert → D1 = 1.0."""
    run_dir = _write_run(
        tmp_path,
        als_text=(
            "sig Foo {}\n"
            "assert Foo { some none }\n"
            "check Foo for 3\n"
        ),
        verdicts={"Foo": "PASS"},
    )
    scores = scorer.score_run(run_dir)
    assert scores["D1"] == 1.0


def test_d1_real_a_l1_fixture() -> None:
    """Integration: real A-L1 run scores D1=1.0."""
    if not REAL_RUN.exists():
        pytest.skip("A-L1/run_01 fixture missing")
    scores = scorer.score_run(REAL_RUN)
    assert scores["D1"] == 1.0


# ---------------------------------------------------------------------------
# D2 — Pattern grounding
# ---------------------------------------------------------------------------

def test_d2_hallucinated_pattern(tmp_path: Path) -> None:
    """A pattern name not in the catalogue → that pattern scores 0.0."""
    run_dir = _write_run(
        tmp_path,
        als_text=(
            "pred LeastPrivilege { some none }\n"
            "pred MadeUpPattern { some none }\n"
            "assert LeastPrivilege { LeastPrivilege }\n"
            "check LeastPrivilege for 3\n"
        ),
        manifest={"patterns_applied": ["LeastPrivilege", "MadeUpPattern"]},
        verdicts={"LeastPrivilege": "PASS"},
        patterns_md=(
            "# Catalogue\n\n"
            "### LeastPrivilege\n\n- description\n\n"
            # MadeUpPattern intentionally absent
        ),
    )
    scores = scorer.score_run(run_dir)
    # (1.0 [LeastPrivilege, in catalog + pred] + 0.0 [hallucinated]) / 2 = 0.5
    assert scores["D2"] == 0.5


def test_d2_catalog_name_no_pred(tmp_path: Path) -> None:
    """Valid catalog name but no matching `pred` → 0.5."""
    run_dir = _write_run(
        tmp_path,
        als_text=(
            # LeastPrivilege is declared in patterns_applied but never
            # appears as a pred in the .als.
            "sig Foo {}\nassert Bar { some none }\ncheck Bar for 3\n"
        ),
        manifest={"patterns_applied": ["LeastPrivilege"]},
        verdicts={"Bar": "PASS"},
    )
    scores = scorer.score_run(run_dir)
    assert scores["D2"] == 0.5


def test_d2_full_match(tmp_path: Path) -> None:
    """Catalog name + matching pred → 1.0."""
    run_dir = _write_run(
        tmp_path,
        als_text=(
            "pred LeastPrivilege { some none }\n"
            "pred AuditCompleteness { some none }\n"
            "assert LeastPrivilege { LeastPrivilege }\n"
            "check LeastPrivilege for 3\n"
        ),
        manifest={"patterns_applied": ["LeastPrivilege", "AuditCompleteness"]},
        verdicts={"LeastPrivilege": "PASS"},
    )
    scores = scorer.score_run(run_dir)
    assert scores["D2"] == 1.0


def test_d2_empty_patterns_applied(tmp_path: Path) -> None:
    """An empty patterns_applied list → D2 = 0.0 (documented behaviour)."""
    run_dir = _write_run(
        tmp_path,
        als_text="assert Bar { some none }\ncheck Bar for 3\n",
        manifest={"patterns_applied": []},
        verdicts={"Bar": "PASS"},
    )
    scores = scorer.score_run(run_dir)
    assert scores["D2"] == 0.0


# ---------------------------------------------------------------------------
# D3 — Mutation discrimination
# ---------------------------------------------------------------------------

def test_d3_all_bit(tmp_path: Path) -> None:
    run_dir = _write_run(
        tmp_path,
        als_text="assert Foo { some none } check Foo for 3\n",
        verdicts={"Foo": "PASS"},
        mutation_outcomes={
            "F_One": {"targeted_asserts": {"A": "BIT", "B": "BIT"},
                      "all_bit": True},
            "F_Two": {"targeted_asserts": {"C": "BIT"}, "all_bit": True},
        },
    )
    scores = scorer.score_run(run_dir)
    assert scores["D3"] == 1.0


def test_d3_overconstraint_mixed(tmp_path: Path) -> None:
    """One target all-BIT, one target has VACUOUS_OVERCONSTRAINT → 0.75."""
    run_dir = _write_run(
        tmp_path,
        als_text="assert Foo { some none } check Foo for 3\n",
        verdicts={"Foo": "PASS"},
        mutation_outcomes={
            "F_One": {"targeted_asserts": {"A": "BIT", "B": "BIT"},
                      "all_bit": True},
            "F_Two": {"targeted_asserts": {
                "C": "BIT", "D": "VACUOUS_OVERCONSTRAINT"
            }, "all_bit": False},
        },
    )
    scores = scorer.score_run(run_dir)
    # (1.0 + 0.5) / 2 = 0.75
    assert scores["D3"] == 0.75


def test_d3_tautology_zero_for_that_target(tmp_path: Path) -> None:
    """A target containing any VACUOUS_TAUTOLOGY scores 0.0 regardless."""
    run_dir = _write_run(
        tmp_path,
        als_text="assert Foo { some none } check Foo for 3\n",
        verdicts={"Foo": "PASS"},
        mutation_outcomes={
            "F_One": {"targeted_asserts": {"A": "BIT", "B": "BIT"},
                      "all_bit": True},
            "F_Two": {"targeted_asserts": {
                "C": "BIT", "D": "VACUOUS_TAUTOLOGY"
            }, "all_bit": False},
        },
    )
    scores = scorer.score_run(run_dir)
    # (1.0 + 0.0) / 2 = 0.5
    assert scores["D3"] == 0.5


def test_d3_skipped_target_excluded(tmp_path: Path) -> None:
    """A `skipped: true` target is dropped from the D3 mean entirely."""
    run_dir = _write_run(
        tmp_path,
        als_text="assert Foo { some none } check Foo for 3\n",
        verdicts={"Foo": "PASS"},
        mutation_outcomes={
            "F_One": {"targeted_asserts": {"A": "BIT"}, "all_bit": True},
            "F_Missing": {
                "targeted_asserts": {},
                "all_bit": False,
                "skipped": True,
                "skip_reason": "fact not found",
            },
        },
    )
    scores = scorer.score_run(run_dir)
    # mean of [1.0] only
    assert scores["D3"] == 1.0
    details = scores["details"]["D3"]
    assert "F_Missing" in details["skipped"]


def test_d3_empty_outcomes(tmp_path: Path) -> None:
    """No mutation outcomes at all → D3 = 0.0."""
    run_dir = _write_run(
        tmp_path,
        als_text="assert Foo { some none } check Foo for 3\n",
        verdicts={"Foo": "PASS"},
        mutation_outcomes={},
    )
    scores = scorer.score_run(run_dir)
    assert scores["D3"] == 0.0


# ---------------------------------------------------------------------------
# D4 — FR coverage and verdict
# ---------------------------------------------------------------------------

_TWO_FR_SPEC = (
    "# Feature Specification: Synth\n\n"
    "## Requirements\n\n"
    "### Functional Requirements\n\n"
    "- **FR-001**: Required behaviour one.\n"
    "- **FR-002**: Required behaviour two.\n"
)


def test_d4_uncovered_fr(tmp_path: Path) -> None:
    """FR-002 has no matching assertion → that FR scores 0.0."""
    run_dir = _write_run(
        tmp_path,
        spec_md=_TWO_FR_SPEC,
        als_text=(
            "assert FR_001_Foo { some none }\n"
            "check FR_001_Foo for 3\n"
        ),
        manifest={"fr_assertion_map": {"FR-001": ["FR_001_Foo"]}},
        verdicts={"FR_001_Foo": "PASS"},
    )
    scores = scorer.score_run(run_dir)
    # (1.0 + 0.0) / 2 = 0.5
    assert scores["D4"] == 0.5


def test_d4_all_fail(tmp_path: Path) -> None:
    """All FRs have matching assertions but every assertion FAILed → 0.5 each."""
    run_dir = _write_run(
        tmp_path,
        spec_md=_TWO_FR_SPEC,
        als_text=(
            "assert FR_001_Foo { some none }\n"
            "check FR_001_Foo for 3\n"
            "assert FR_002_Bar { some none }\n"
            "check FR_002_Bar for 3\n"
        ),
        manifest={"fr_assertion_map": {
            "FR-001": ["FR_001_Foo"], "FR-002": ["FR_002_Bar"]
        }},
        verdicts={"FR_001_Foo": "FAIL", "FR_002_Bar": "FAIL"},
    )
    scores = scorer.score_run(run_dir)
    assert scores["D4"] == 0.5


def test_d4_full_pass(tmp_path: Path) -> None:
    run_dir = _write_run(
        tmp_path,
        spec_md=_TWO_FR_SPEC,
        als_text=(
            "assert FR_001_Foo { some none }\n"
            "check FR_001_Foo for 3\n"
            "assert FR_002_Bar { some none }\n"
            "check FR_002_Bar for 3\n"
        ),
        manifest={"fr_assertion_map": {
            "FR-001": ["FR_001_Foo"], "FR-002": ["FR_002_Bar"]
        }},
        verdicts={"FR_001_Foo": "PASS", "FR_002_Bar": "PASS"},
    )
    scores = scorer.score_run(run_dir)
    assert scores["D4"] == 1.0


# ---------------------------------------------------------------------------
# Integration test — real A-L1/run_01 fixture
# ---------------------------------------------------------------------------

def test_integration_real_a_l1_run_01() -> None:
    """Score the real smoke-test run end-to-end.

    Expected based on the on-disk artefacts:

    - D1 = 1.0 (29 verdicts, 29 asserts)
    - D2 = 1.0 (all 12 patterns_applied are in patterns.md and have preds)
    - D3 = 1.0 (all 7 targets BIT)
    - D4 = 16.5 / 17 (16 FRs PASS; FR-006 is FAIL-only → 0.5)
    """
    if not REAL_RUN.exists():
        pytest.skip("A-L1/run_01 fixture missing")
    scores = scorer.score_run(REAL_RUN)

    assert scores["D1"] == 1.0
    assert scores["D2"] == 1.0
    assert scores["D3"] == 1.0

    expected_d4 = 16.5 / 17
    assert math.isclose(scores["D4"], expected_d4, rel_tol=1e-9), (
        f"D4 expected {expected_d4}, got {scores['D4']}"
    )

    expected_aqs = (1.0 + 1.0 + 1.0 + expected_d4) / 4
    assert math.isclose(scores["aqs_partial"], expected_aqs, rel_tol=1e-9)

    # Sanity: FR-006 must be the half-credit FR in the per-FR breakdown.
    per_fr = scores["details"]["D4"]["per_fr"]
    assert per_fr["FR-006"]["score"] == 0.5
    other_frs = [fr for fr in per_fr if fr != "FR-006"]
    assert all(per_fr[fr]["score"] == 1.0 for fr in other_frs)


# ---------------------------------------------------------------------------
# CLI / tree-walking smoke tests
# ---------------------------------------------------------------------------

def test_score_tree_skips_existing(tmp_path: Path) -> None:
    """`score_tree` should skip runs that already have scores.json."""
    run_dir = _write_run(
        tmp_path,
        als_text="assert Foo { some none } check Foo for 3\n",
        verdicts={"Foo": "PASS"},
        mutation_outcomes={
            "F_One": {"targeted_asserts": {"A": "BIT"}, "all_bit": True},
        },
        manifest={"patterns_applied": ["LeastPrivilege"]},
    )
    # First pass scores it.
    summary1 = scorer.score_tree(tmp_path / "eval" / "runs")
    assert summary1["scored"] == 1
    assert summary1["skipped"] == 0

    # Second pass should skip the already-scored run.
    summary2 = scorer.score_tree(tmp_path / "eval" / "runs")
    assert summary2["scored"] == 0
    assert summary2["skipped"] == 1


def test_score_tree_continues_past_errors(tmp_path: Path) -> None:
    """A broken run shouldn't abort the rest of the walk."""
    # Run #1: scoreable.
    _write_run(
        tmp_path,
        cell="A-OK", rep=1,
        als_text="assert Foo { some none } check Foo for 3\n",
        verdicts={"Foo": "PASS"},
        manifest={"patterns_applied": ["LeastPrivilege"]},
    )
    # Run #2: missing cost_log.json (not scoreable).
    broken = (
        tmp_path / "eval" / "runs" / "B-BAD" / "M-best" / "run_01"
    )
    broken.mkdir(parents=True)
    (broken / "feature_model.als").write_text("", encoding="utf-8")
    (broken / "feature_model.manifest.json").write_text("{}", encoding="utf-8")

    summary = scorer.score_tree(tmp_path / "eval" / "runs")
    assert summary["scored"] == 1
    assert summary["errored"] == 1

"""eval/statistics.py — Stage-1 + Stage-2 statistical analysis (E5 + Stage 2).

Consumes the CSVs E4 produced (`eval/results/all_scores.csv`,
`eval/results/d5_details.json`) and runs:

- The Stage-1 statistical machinery pre-registered in
  EVALUATION_PLAN.md §5 on the richness factor (H1–H4).
- The Stage-2 statistical machinery pre-registered in
  EVALUATION_PLAN.md §5 on the model factor (H5–H7), gated on
  multi-model data presence — so existing Stage 1-only reports stay
  bit-identical when only `M-best` is on disk.

Stage 1 tests (per EVALUATION_PLAN.md §5 Stage-1 block):

1. Overall richness effect — Kruskal-Wallis H on per-run
   `aqs_partial` grouped by richness (L1/L2/L3), pooled across
   domains.
2. Per-domain richness effect — one Kruskal-Wallis per domain
   (A/B/C).
3. Pairwise richness contrasts — Mann-Whitney U on
   L1-vs-L2, L1-vs-L3, L2-vs-L3, Bonferroni-corrected for 3
   comparisons (p × 3, capped at 1.0).
4. Cohen's d for each pairwise contrast (pooled-SD).
5. Stability differences — Kruskal-Wallis on per-key D5 stability
   values across richness, then pairwise Mann-Whitney with
   Bonferroni.

Stage 2 tests (per EVALUATION_PLAN.md §5 Stage-2 block, re-enabled
2026-05-19 — see [[project_eval_stage2_plan]]):

6. Overall model effect (H5) — Kruskal-Wallis H on `aqs_partial`
   grouped by model.
7. Per-richness model effect (H5) — one Kruskal-Wallis per richness
   level.
8. Per-domain model effect (H5) — one Kruskal-Wallis per domain.
9. Pairwise model contrasts (H5) — Mann-Whitney + Bonferroni
   correction (k = C(n_models, 2)) + Cohen's d on every model pair.
10. H6 "lever comparison" — |Cohen's d(M-best vs M-small at L2)|
    against |Cohen's d(L1 vs L3 at M-best)|. The larger value
    answers H6 ("which lever is bigger — better model or richer
    spec?").
11. Per-key D5 stability by model (H7) — Kruskal + pairwise MW.

α = 0.05. Cohen's d interpretation (Cohen 1988):
    small  ≥ 0.2,  medium ≥ 0.5,  large ≥ 0.8.

Graceful degradation. If any group has fewer than `MIN_N_PER_GROUP`
(= 3) observations, the relevant test is `skipped` with a
`skip_reason` rather than raising. The single-cell smoke run
(N = 1 on A-L1) therefore exits 0 cleanly and writes a report
saying "insufficient data — run Stage-1 sweep (E6) first".

Outputs:

    eval/results/statistics_report.txt   — human-readable report
    eval/results/statistics.json         — machine-readable shape

CLI:

    python eval/statistics.py
    python eval/statistics.py --results-dir eval/results/
"""

from __future__ import annotations

import argparse
import csv
import datetime as _dt
import importlib.util as _importlib_util
import json
import math
import os as _os
import re
import sys
from pathlib import Path
from typing import Iterable, Mapping, Sequence


# ---------------------------------------------------------------------------
# Re-export stdlib `statistics` symbols. This file is named `statistics.py`
# and lives inside `eval/`, so when callers put `eval/` on sys.path (the
# pytest fixtures in this repo do exactly that) this module *shadows* the
# stdlib `statistics`. Existing sibling modules (`eval/aggregate.py`,
# `eval/scorer.py`) do `from statistics import mean`, expecting stdlib —
# so we load the stdlib by absolute file path and re-export its names
# from the top of this module. That way `from statistics import mean`
# keeps resolving to the canonical stdlib implementation regardless of
# sys.path order.
# ---------------------------------------------------------------------------

def _load_stdlib_statistics():  # pragma: no cover — import-time bootstrap
    """Locate the *stdlib* `statistics` module by walking sys.path entries
    that don't contain THIS file. Returns the loaded module."""
    here = Path(__file__).resolve().parent
    candidates: list[Path] = []
    for d in sys.path:
        if not d or Path(d).resolve() == here:
            continue
        p = Path(d) / "statistics.py"
        if p.exists():
            candidates.append(p)
        p_pkg = Path(d) / "statistics" / "__init__.py"
        if p_pkg.exists():
            candidates.append(p_pkg)
    # Also try the well-known stdlib install dir (libpython).
    candidates.append(
        Path(_os.path.dirname(_os.__file__)) / "statistics.py"
    )
    for path in candidates:
        if not path.exists():
            continue
        spec = _importlib_util.spec_from_file_location(
            "_eval_stdlib_statistics", path
        )
        if spec is None or spec.loader is None:
            continue
        mod = _importlib_util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    raise ImportError(
        "Could not locate the stdlib `statistics` module on sys.path."
    )


_stdlib_stats = _load_stdlib_statistics()

# Re-export every public symbol from stdlib statistics so that
# `from statistics import mean` (or median / stdev / variance / fmean
# / NormalDist / etc.) continues to resolve correctly when this file
# is the loaded `statistics` module.
for _name in dir(_stdlib_stats):
    if _name.startswith("_"):
        continue
    globals().setdefault(_name, getattr(_stdlib_stats, _name))
del _name

try:
    from scipy.stats import kruskal as _scipy_kruskal
    from scipy.stats import mannwhitneyu as _scipy_mannwhitneyu
except ImportError as exc:  # pragma: no cover — module-load failure
    raise SystemExit(
        "eval/statistics.py requires scipy. Install with: "
        "pip install --break-system-packages scipy"
    ) from exc


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ALPHA = 0.05
MIN_N_PER_GROUP = 3          # Kruskal-Wallis / MW are unreliable below this
N_PAIRWISE_RICHNESS = 3      # L1-L2, L1-L3, L2-L3 — Bonferroni divisor
RICHNESS_LEVELS = ("L1", "L2", "L3")
DOMAINS = ("A", "B", "C")
DOMAIN_NAMES = {"A": "Banking", "B": "SaaS", "C": "Healthcare"}

# Canonical model ordering — when present, models are reported in this
# order in tables / report sections. Models outside this list are
# appended in alphabetical order so an unexpected tier (e.g. an ad-hoc
# experimental tier) still surfaces in the report instead of silently
# dropping.
CANONICAL_MODEL_ORDER: tuple[str, ...] = ("M-best", "M-mid", "M-small")

# H6 contrast is hard-pinned per EVALUATION_PLAN.md §9 — "model lever"
# is the M-best vs M-small contrast at L2; "richness lever" is the
# L1 vs L3 contrast at M-best.
H6_MODEL_LEVER_PAIR = ("M-best", "M-small")
H6_MODEL_LEVER_RICHNESS = "L2"
H6_RICHNESS_LEVER_PAIR = ("L1", "L3")
H6_RICHNESS_LEVER_MODEL = "M-best"

# Cell name shape: "<domain><sep><richness>" — domain ∈ {A,B,C},
# richness ∈ {L1,L2,L3}. Accept either dash or no-separator.
_CELL_RE = re.compile(r"^(?P<domain>[A-C])-?(?P<richness>L[123])$")

# Cohen's d interpretation thresholds
_COHEN_THRESHOLDS = ((0.8, "large"), (0.5, "medium"), (0.2, "small"))


# ---------------------------------------------------------------------------
# Stats primitives (manual — `statistics.py` cannot import the stdlib
# `statistics` module without shadowing itself when this file is the
# entry-point script).
# ---------------------------------------------------------------------------

def _mean(xs: Sequence[float]) -> float:
    return sum(xs) / len(xs)


def _median(xs: Sequence[float]) -> float:
    s = sorted(xs)
    n = len(s)
    mid = n // 2
    if n % 2:
        return float(s[mid])
    return (s[mid - 1] + s[mid]) / 2.0


def _variance(xs: Sequence[float]) -> float:
    """Sample variance (Bessel-corrected). Requires n ≥ 2."""
    m = _mean(xs)
    return sum((x - m) ** 2 for x in xs) / (len(xs) - 1)


def _stdev(xs: Sequence[float]) -> float:
    return math.sqrt(_variance(xs))


# ---------------------------------------------------------------------------
# Cell parsing
# ---------------------------------------------------------------------------

def parse_cell(cell: str) -> tuple[str, str]:
    """Parse "A-L1" → ("A", "L1"). Raises ValueError on unknown shape."""
    m = _CELL_RE.match(cell)
    if not m:
        raise ValueError(f"Cannot parse cell name: {cell!r}")
    return m.group("domain"), m.group("richness")


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_all_scores(path: Path) -> list[dict]:
    """Return list of {run_id, cell, model, rep, D1..D4, aqs_partial}.

    Numeric fields are coerced to float (None / empty → None).
    Adds `domain` and `richness` parsed from the cell name.
    Rows whose cell cannot be parsed are skipped with a stderr note
    (they're not valid eval data).
    """
    rows: list[dict] = []
    with path.open("r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        for raw in reader:
            try:
                domain, richness = parse_cell(raw["cell"])
            except ValueError as exc:
                print(f"[skip] {exc}", file=sys.stderr)
                continue
            row = {
                "run_id": raw["run_id"],
                "cell": raw["cell"],
                "model": raw["model"],
                "rep": int(raw["rep"]) if raw.get("rep") else None,
                "domain": domain,
                "richness": richness,
            }
            for col in ("D1", "D2", "D3", "D4", "aqs_partial"):
                v = raw.get(col, "")
                row[col] = float(v) if v not in ("", None) else None
            rows.append(row)
    return rows


def load_d5_details(path: Path) -> dict:
    """Return d5_details.json as-is (keyed by `<cell>/<model>`)."""
    return json.loads(path.read_text(encoding="utf-8"))


def d5_stabilities_by_richness(
    d5_details: Mapping[str, dict],
    *,
    qualifying_only: bool = True,
) -> dict[str, list[float]]:
    """Pivot the per-key stability values into per-richness lists.

    Each per_key entry contributes one stability observation. When
    `qualifying_only` is True (the default), only keys with the
    `qualifies` flag set are included — i.e. keys that reached the
    5-replicate floor and therefore contributed to D5 itself.
    """
    out: dict[str, list[float]] = {r: [] for r in RICHNESS_LEVELS}
    for cell_model_key, payload in d5_details.items():
        cell = cell_model_key.split("/", 1)[0]
        try:
            _, richness = parse_cell(cell)
        except ValueError:
            continue
        per_key = payload.get("per_key", {})
        for _key_name, info in per_key.items():
            if qualifying_only and not info.get("qualifies"):
                continue
            stab = info.get("stability")
            if stab is None:
                continue
            out[richness].append(float(stab))
    return out


def d5_stabilities_by_model(
    d5_details: Mapping[str, dict],
    *,
    qualifying_only: bool = True,
) -> dict[str, list[float]]:
    """Pivot the per-key stability values into per-model lists.

    Stage-2 (H7) mirror of `d5_stabilities_by_richness`. d5_details is
    keyed by `<cell>/<model>`; we extract the model side. Each per_key
    entry contributes one stability observation, filtered the same way
    as the richness pivot.
    """
    out: dict[str, list[float]] = {}
    for cell_model_key, payload in d5_details.items():
        parts = cell_model_key.split("/", 1)
        if len(parts) != 2:
            continue
        cell, model = parts
        try:
            parse_cell(cell)  # ignore parse-failed cells
        except ValueError:
            continue
        per_key = payload.get("per_key", {})
        for _key_name, info in per_key.items():
            if qualifying_only and not info.get("qualifies"):
                continue
            stab = info.get("stability")
            if stab is None:
                continue
            out.setdefault(model, []).append(float(stab))
    return out


def models_present(rows: Iterable[Mapping]) -> list[str]:
    """Sorted unique model values across rows, with canonical order
    applied where applicable.

    `CANONICAL_MODEL_ORDER` is honoured for the three pre-registered
    tiers; any additional model values are appended alphabetically.
    Rows missing a model key are ignored.
    """
    seen: set[str] = set()
    for r in rows:
        m = r.get("model")
        if m:
            seen.add(str(m))
    ordered: list[str] = [m for m in CANONICAL_MODEL_ORDER if m in seen]
    extras = sorted(m for m in seen if m not in set(CANONICAL_MODEL_ORDER))
    return ordered + extras


def model_pairs(models: Sequence[str]) -> list[tuple[str, str]]:
    """Every 2-combination of models, preserving the input ordering.

    For (M-best, M-mid, M-small) this returns:
        (M-best, M-mid), (M-best, M-small), (M-mid, M-small)
    """
    pairs: list[tuple[str, str]] = []
    for i in range(len(models)):
        for j in range(i + 1, len(models)):
            pairs.append((models[i], models[j]))
    return pairs


# ---------------------------------------------------------------------------
# Statistical primitives
# ---------------------------------------------------------------------------

def cohen_d(x: Sequence[float], y: Sequence[float]) -> float | None:
    """Pooled-SD Cohen's d. Returns None if either side has < 2 obs
    or pooled SD is 0 (no variance → effect size undefined).

    Signed: positive when mean(x) > mean(y).
    """
    nx, ny = len(x), len(y)
    if nx < 2 or ny < 2:
        return None
    mx, my = _mean(x), _mean(y)
    vx, vy = _variance(x), _variance(y)
    pooled_var = ((nx - 1) * vx + (ny - 1) * vy) / (nx + ny - 2)
    if pooled_var <= 0:
        return None
    return (mx - my) / math.sqrt(pooled_var)


def cohen_d_label(d: float | None) -> str:
    """Cohen 1988 interpretation. None → 'undefined'; |d| < 0.2 → 'negligible'."""
    if d is None:
        return "undefined"
    abs_d = abs(d)
    for thresh, label in _COHEN_THRESHOLDS:
        if abs_d >= thresh:
            return label
    return "negligible"


def _group_summary(values: Sequence[float]) -> dict:
    """Descriptive stats — used for the report header per group."""
    n = len(values)
    if n == 0:
        return {"n": 0, "mean": None, "median": None,
                "stdev": None, "min": None, "max": None}
    return {
        "n": n,
        "mean": _mean(values),
        "median": _median(values),
        "stdev": _stdev(values) if n >= 2 else 0.0,
        "min": min(values),
        "max": max(values),
    }


def run_kruskal(
    groups: Mapping[str, Sequence[float]],
    *,
    min_n: int = MIN_N_PER_GROUP,
) -> dict:
    """Kruskal-Wallis on >= 2 groups.

    Returns:
        {
            "test": "kruskal_wallis",
            "groups": {name: _group_summary(...)},
            "h": float | None,
            "p": float | None,
            "significant": bool | None,
            "skipped": bool,
            "skip_reason": str | None,
        }
    """
    group_summaries = {name: _group_summary(list(vs)) for name, vs in groups.items()}
    result = {
        "test": "kruskal_wallis",
        "groups": group_summaries,
        "h": None,
        "p": None,
        "significant": None,
        "skipped": False,
        "skip_reason": None,
    }
    non_empty = {n: list(vs) for n, vs in groups.items() if len(vs) > 0}
    if len(non_empty) < 2:
        result["skipped"] = True
        result["skip_reason"] = (
            f"need >=2 non-empty groups, got {len(non_empty)}"
        )
        return result
    small = [n for n, vs in non_empty.items() if len(vs) < min_n]
    if small:
        result["skipped"] = True
        result["skip_reason"] = (
            f"groups below n={min_n}: {sorted(small)}"
        )
        return result
    h, p = _scipy_kruskal(*non_empty.values())
    result["h"] = float(h)
    result["p"] = float(p)
    result["significant"] = bool(p < ALPHA)
    return result


def run_pairwise_mw(
    groups: Mapping[str, Sequence[float]],
    *,
    pairs: Sequence[tuple[str, str]],
    bonferroni_k: int,
    min_n: int = MIN_N_PER_GROUP,
) -> dict[str, dict]:
    """Pairwise Mann-Whitney U with Bonferroni correction + Cohen's d.

    Each pair contributes:
        {
            "test": "mann_whitney_u",
            "groups": {a: summary, b: summary},
            "u": float | None, "p_raw": float | None,
            "p_corrected": float | None,
            "cohen_d": float | None,
            "cohen_d_label": str,
            "significant": bool | None,
            "skipped": bool, "skip_reason": str | None,
        }
    """
    out: dict[str, dict] = {}
    for a, b in pairs:
        vs_a = list(groups.get(a, ()))
        vs_b = list(groups.get(b, ()))
        entry: dict = {
            "test": "mann_whitney_u",
            "groups": {
                a: _group_summary(vs_a),
                b: _group_summary(vs_b),
            },
            "u": None,
            "p_raw": None,
            "p_corrected": None,
            "cohen_d": None,
            "cohen_d_label": "undefined",
            "significant": None,
            "skipped": False,
            "skip_reason": None,
        }
        if len(vs_a) < min_n or len(vs_b) < min_n:
            entry["skipped"] = True
            entry["skip_reason"] = (
                f"need n>={min_n} per group, got "
                f"{a}={len(vs_a)} {b}={len(vs_b)}"
            )
            out[f"{a}-{b}"] = entry
            continue
        u, p_raw = _scipy_mannwhitneyu(vs_a, vs_b, alternative="two-sided")
        p_corr = min(1.0, float(p_raw) * bonferroni_k)
        d = cohen_d(vs_a, vs_b)
        entry.update(
            u=float(u),
            p_raw=float(p_raw),
            p_corrected=p_corr,
            cohen_d=d,
            cohen_d_label=cohen_d_label(d),
            significant=bool(p_corr < ALPHA),
        )
        out[f"{a}-{b}"] = entry
    return out


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

_RICHNESS_PAIRS: tuple[tuple[str, str], ...] = (
    ("L1", "L2"),
    ("L1", "L3"),
    ("L2", "L3"),
)


def _group_by_richness(rows: Iterable[dict], *, metric: str,
                      domain: str | None = None) -> dict[str, list[float]]:
    out: dict[str, list[float]] = {r: [] for r in RICHNESS_LEVELS}
    for row in rows:
        if domain is not None and row["domain"] != domain:
            continue
        v = row.get(metric)
        if v is None:
            continue
        out[row["richness"]].append(float(v))
    return out


def _group_by_model(
    rows: Iterable[dict], *, metric: str,
    models: Sequence[str],
    domain: str | None = None,
    richness: str | None = None,
) -> dict[str, list[float]]:
    """Stage-2 sibling of `_group_by_richness`.

    Returns a dict pre-populated with every model in `models` (empty
    lists for absent models) so downstream Kruskal / MW code can tell
    "missing model" apart from "model with zero observations". Optional
    `domain` / `richness` filters narrow the rows.
    """
    out: dict[str, list[float]] = {m: [] for m in models}
    for row in rows:
        m = row.get("model")
        if m not in out:
            continue
        if domain is not None and row.get("domain") != domain:
            continue
        if richness is not None and row.get("richness") != richness:
            continue
        v = row.get(metric)
        if v is None:
            continue
        out[m].append(float(v))
    return out


def compute_stage1_statistics(
    rows: list[dict],
    d5_details: Mapping[str, dict],
) -> dict:
    """Compute every Stage-1 test from the loaded rows + d5_details.

    Returns the dict that will be serialised to statistics.json.
    """
    overall = run_kruskal(_group_by_richness(rows, metric="aqs_partial"))
    per_domain: dict[str, dict] = {}
    for dom in DOMAINS:
        per_domain[dom] = run_kruskal(
            _group_by_richness(rows, metric="aqs_partial", domain=dom)
        )
    pairwise = run_pairwise_mw(
        _group_by_richness(rows, metric="aqs_partial"),
        pairs=_RICHNESS_PAIRS,
        bonferroni_k=N_PAIRWISE_RICHNESS,
    )
    d5_groups = d5_stabilities_by_richness(d5_details, qualifying_only=True)
    d5_overall = run_kruskal(d5_groups)
    d5_pairwise = run_pairwise_mw(
        d5_groups,
        pairs=_RICHNESS_PAIRS,
        bonferroni_k=N_PAIRWISE_RICHNESS,
    )
    n_per_richness = {
        r: sum(1 for row in rows if row["richness"] == r)
        for r in RICHNESS_LEVELS
    }
    n_per_domain = {
        d: sum(1 for row in rows if row["domain"] == d) for d in DOMAINS
    }
    models = models_present(rows)
    n_per_model = {
        m: sum(1 for row in rows if row.get("model") == m) for m in models
    }
    stats: dict = {
        "generated_at": _dt.datetime.now(_dt.timezone.utc).isoformat(
            timespec="seconds"
        ),
        "alpha": ALPHA,
        "n_total_runs": len(rows),
        "n_per_richness": n_per_richness,
        "n_per_domain": n_per_domain,
        "models_present": models,
        "n_per_model": n_per_model,
        "tests": {
            "overall_richness": {**overall, "metric": "aqs_partial",
                                  "hypothesis": "H1"},
            "per_domain_richness": {
                dom: {**res, "metric": "aqs_partial",
                      "domain": dom, "domain_name": DOMAIN_NAMES[dom]}
                for dom, res in per_domain.items()
            },
            "pairwise_richness_aqs": {
                **pairwise, "metric": "aqs_partial",
                "_meta": {"bonferroni_k": N_PAIRWISE_RICHNESS,
                          "hypothesis": "H1"},
            },
            "d5_stability_richness": {**d5_overall,
                                      "metric": "d5_per_key_stability",
                                      "hypothesis": "H3"},
            "pairwise_d5_richness": {
                **d5_pairwise, "metric": "d5_per_key_stability",
                "_meta": {"bonferroni_k": N_PAIRWISE_RICHNESS,
                          "hypothesis": "H3"},
            },
        },
    }

    # Stage 2 is purely additive — merged in only when ≥2 models are
    # present in the rows. Single-model output is bit-identical to the
    # E5-era shape, so existing Stage 1-only reports stay clean.
    if len(models) >= 2:
        stage2 = compute_stage2_statistics(rows, d5_details, models=models)
        stats["tests"].update(stage2["tests"])
        stats["stage2_models_present"] = stage2["models_present"]

    return stats


def compute_stage2_statistics(
    rows: list[dict],
    d5_details: Mapping[str, dict],
    *,
    models: Sequence[str] | None = None,
) -> dict:
    """Compute every Stage-2 test (H5/H6/H7) from the loaded rows +
    d5_details.

    Returns a dict shaped like::

        {
            "models_present": list[str],
            "tests": {
                "model_effect_overall":        Kruskal block,
                "model_effect_per_richness":   {L1: Kruskal, ...},
                "model_effect_per_domain":     {A: Kruskal, ...},
                "pairwise_model_aqs":          {pair: MW block, _meta: ...},
                "h6_lever_comparison":         {...},
                "d5_stability_model":          Kruskal block,
                "pairwise_d5_model":           {pair: MW block, _meta: ...},
            },
        }

    Designed to be called either standalone (for tests) or by
    `compute_stage1_statistics` when it detects multi-model data.

    If only one (or zero) models are present the function still
    returns a structurally valid dict, but every Kruskal / MW block
    is `skipped` with a `skip_reason`.
    """
    if models is None:
        models = models_present(rows)
    models = list(models)

    pairs = model_pairs(models)
    pair_k = max(1, len(pairs))  # Bonferroni divisor — no correction for k<2

    # H5: overall model effect on AQS partial, pooled across cells.
    overall = run_kruskal(_group_by_model(rows, metric="aqs_partial",
                                          models=models))

    # H5: per-richness slices.
    per_richness: dict[str, dict] = {}
    for rich in RICHNESS_LEVELS:
        per_richness[rich] = run_kruskal(_group_by_model(
            rows, metric="aqs_partial", models=models, richness=rich,
        ))

    # H5: per-domain slices.
    per_domain: dict[str, dict] = {}
    for dom in DOMAINS:
        per_domain[dom] = run_kruskal(_group_by_model(
            rows, metric="aqs_partial", models=models, domain=dom,
        ))

    # H5 pairwise MW + Bonferroni + Cohen's d.
    pairwise = run_pairwise_mw(
        _group_by_model(rows, metric="aqs_partial", models=models),
        pairs=pairs,
        bonferroni_k=pair_k,
    )

    # H6 "lever comparison" — does picking a better model dominate
    # picking a richer spec, or vice versa?
    h6 = _compute_h6_lever_comparison(rows, models=models)

    # H7: D5 stability by model.
    d5_by_model = d5_stabilities_by_model(d5_details, qualifying_only=True)
    # Re-key so absent models are explicit empties.
    d5_by_model = {m: d5_by_model.get(m, []) for m in models}
    d5_overall = run_kruskal(d5_by_model)
    d5_pairwise = run_pairwise_mw(
        d5_by_model, pairs=pairs, bonferroni_k=pair_k,
    )

    return {
        "models_present": models,
        "tests": {
            "model_effect_overall": {
                **overall, "metric": "aqs_partial",
                "hypothesis": "H5",
            },
            "model_effect_per_richness": {
                r: {**res, "metric": "aqs_partial",
                    "richness": r, "hypothesis": "H5"}
                for r, res in per_richness.items()
            },
            "model_effect_per_domain": {
                dom: {**res, "metric": "aqs_partial",
                      "domain": dom, "domain_name": DOMAIN_NAMES[dom],
                      "hypothesis": "H5"}
                for dom, res in per_domain.items()
            },
            "pairwise_model_aqs": {
                **pairwise, "metric": "aqs_partial",
                "_meta": {"bonferroni_k": pair_k,
                          "hypothesis": "H5"},
            },
            "h6_lever_comparison": h6,
            "d5_stability_model": {
                **d5_overall, "metric": "d5_per_key_stability",
                "hypothesis": "H7",
            },
            "pairwise_d5_model": {
                **d5_pairwise, "metric": "d5_per_key_stability",
                "_meta": {"bonferroni_k": pair_k,
                          "hypothesis": "H7"},
            },
        },
    }


def _compute_h6_lever_comparison(
    rows: list[dict], *, models: Sequence[str],
) -> dict:
    """H6 — which lever has the larger effect on AQS, model or richness?

    Computes both Cohen's d values per EVALUATION_PLAN.md §9:

        d_model    = cohen_d(M-best @ L2, M-small @ L2)  on aqs_partial
        d_richness = cohen_d(L1 @ M-best, L3 @ M-best)    on aqs_partial

    The block is `skipped` (with reason) when either lever lacks the
    required data — e.g. M-small absent, or L2 with no replicates.
    """
    have_model = (H6_MODEL_LEVER_PAIR[0] in models
                  and H6_MODEL_LEVER_PAIR[1] in models)

    record: dict = {
        "metric": "aqs_partial",
        "hypothesis": "H6",
        "model_lever": {
            "pair": list(H6_MODEL_LEVER_PAIR),
            "at_richness": H6_MODEL_LEVER_RICHNESS,
            "cohen_d": None,
            "cohen_d_abs": None,
            "cohen_d_label": "undefined",
            "n_a": 0, "n_b": 0,
        },
        "richness_lever": {
            "pair": list(H6_RICHNESS_LEVER_PAIR),
            "at_model": H6_RICHNESS_LEVER_MODEL,
            "cohen_d": None,
            "cohen_d_abs": None,
            "cohen_d_label": "undefined",
            "n_a": 0, "n_b": 0,
        },
        "winner": None,
        "skipped": False,
        "skip_reason": None,
    }

    # ---- model lever -----------------------------------------------------
    a_vals = _filter_values(
        rows, metric="aqs_partial",
        model=H6_MODEL_LEVER_PAIR[0], richness=H6_MODEL_LEVER_RICHNESS,
    )
    b_vals = _filter_values(
        rows, metric="aqs_partial",
        model=H6_MODEL_LEVER_PAIR[1], richness=H6_MODEL_LEVER_RICHNESS,
    )
    record["model_lever"]["n_a"] = len(a_vals)
    record["model_lever"]["n_b"] = len(b_vals)
    d_model: float | None = None
    if have_model and len(a_vals) >= 2 and len(b_vals) >= 2:
        d_model = cohen_d(a_vals, b_vals)
        record["model_lever"]["cohen_d"] = d_model
        record["model_lever"]["cohen_d_abs"] = (
            abs(d_model) if d_model is not None else None
        )
        record["model_lever"]["cohen_d_label"] = cohen_d_label(d_model)

    # ---- richness lever --------------------------------------------------
    a_r = _filter_values(
        rows, metric="aqs_partial",
        model=H6_RICHNESS_LEVER_MODEL,
        richness=H6_RICHNESS_LEVER_PAIR[0],
    )
    b_r = _filter_values(
        rows, metric="aqs_partial",
        model=H6_RICHNESS_LEVER_MODEL,
        richness=H6_RICHNESS_LEVER_PAIR[1],
    )
    record["richness_lever"]["n_a"] = len(a_r)
    record["richness_lever"]["n_b"] = len(b_r)
    d_richness: float | None = None
    if (H6_RICHNESS_LEVER_MODEL in models
            and len(a_r) >= 2 and len(b_r) >= 2):
        d_richness = cohen_d(a_r, b_r)
        record["richness_lever"]["cohen_d"] = d_richness
        record["richness_lever"]["cohen_d_abs"] = (
            abs(d_richness) if d_richness is not None else None
        )
        record["richness_lever"]["cohen_d_label"] = cohen_d_label(d_richness)

    # ---- verdict ---------------------------------------------------------
    if d_model is None or d_richness is None:
        record["skipped"] = True
        missing = []
        if d_model is None:
            missing.append(
                f"model_lever ({H6_MODEL_LEVER_PAIR[0]} vs "
                f"{H6_MODEL_LEVER_PAIR[1]} at {H6_MODEL_LEVER_RICHNESS})"
            )
        if d_richness is None:
            missing.append(
                f"richness_lever ({H6_RICHNESS_LEVER_PAIR[0]} vs "
                f"{H6_RICHNESS_LEVER_PAIR[1]} at "
                f"{H6_RICHNESS_LEVER_MODEL})"
            )
        record["skip_reason"] = (
            "insufficient data: " + ", ".join(missing)
        )
        return record

    am, ar = abs(d_model), abs(d_richness)
    if am > ar:
        record["winner"] = "model"
        record["winner_margin"] = am - ar
    elif ar > am:
        record["winner"] = "richness"
        record["winner_margin"] = ar - am
    else:
        record["winner"] = "tie"
        record["winner_margin"] = 0.0
    return record


def _filter_values(
    rows: Iterable[dict], *, metric: str,
    model: str | None = None,
    richness: str | None = None,
    domain: str | None = None,
) -> list[float]:
    """Tiny helper — return the `metric` column for rows matching every
    supplied filter. Used by the H6 lever comparison."""
    out: list[float] = []
    for r in rows:
        if model is not None and r.get("model") != model:
            continue
        if richness is not None and r.get("richness") != richness:
            continue
        if domain is not None and r.get("domain") != domain:
            continue
        v = r.get(metric)
        if v is None:
            continue
        out.append(float(v))
    return out


# ---------------------------------------------------------------------------
# Reporting (plain-text)
# ---------------------------------------------------------------------------

def _fmt_float(v, *, digits: int = 4) -> str:
    if v is None:
        return "—"
    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
        return str(v)
    return f"{v:.{digits}f}"


def _format_group_line(name: str, summary: dict) -> str:
    return (
        f"    {name}: n={summary['n']:>3}  "
        f"mean={_fmt_float(summary['mean'])}  "
        f"median={_fmt_float(summary['median'])}  "
        f"sd={_fmt_float(summary['stdev'])}  "
        f"min={_fmt_float(summary['min'])}  "
        f"max={_fmt_float(summary['max'])}"
    )


def _format_kruskal_block(title: str, result: dict, indent: str = "") -> str:
    lines = [f"{indent}{title}"]
    lines.append(f"{indent}  Metric: {result.get('metric', '—')}")
    for name, summary in result["groups"].items():
        lines.append(indent + _format_group_line(name, summary))
    if result.get("skipped"):
        lines.append(f"{indent}  Result: SKIPPED ({result['skip_reason']})")
    else:
        sig = "yes" if result["significant"] else "no"
        lines.append(
            f"{indent}  Kruskal-Wallis: H = {_fmt_float(result['h'])}, "
            f"p = {_fmt_float(result['p'], digits=4)}, "
            f"significant (α={ALPHA}) = {sig}"
        )
    return "\n".join(lines)


def _format_pairwise_block(title: str, results: Mapping[str, dict],
                            indent: str = "") -> str:
    lines = [f"{indent}{title}"]
    meta = results.get("_meta") or {}
    bk = meta.get("bonferroni_k")
    if bk:
        lines.append(
            f"{indent}  Bonferroni correction: k = {bk} "
            f"(p_corrected = min(1, p × k))"
        )
    for pair_key, entry in results.items():
        if pair_key.startswith("_") or not isinstance(entry, dict) \
                or "groups" not in entry:
            # Skip non-pair siblings like `metric`, `hypothesis`, `_meta`.
            continue
        a, b = pair_key.split("-", 1)
        lines.append(f"{indent}  {a} vs {b}")
        for name, summary in entry["groups"].items():
            lines.append(indent + _format_group_line(name, summary))
        if entry.get("skipped"):
            lines.append(
                f"{indent}    Result: SKIPPED ({entry['skip_reason']})"
            )
            continue
        sig = "yes" if entry["significant"] else "no"
        lines.append(
            f"{indent}    Mann-Whitney U = {_fmt_float(entry['u'])}, "
            f"p_raw = {_fmt_float(entry['p_raw'])}, "
            f"p_corrected = {_fmt_float(entry['p_corrected'])}"
        )
        lines.append(
            f"{indent}    Cohen's d = {_fmt_float(entry['cohen_d'])}  "
            f"({entry['cohen_d_label']})"
        )
        lines.append(f"{indent}    Significant (α={ALPHA}): {sig}")
    return "\n".join(lines)


def render_report(stats: dict) -> str:
    """Render the human-readable plain-text statistics report."""
    lines: list[str] = []
    lines.append("=" * 76)
    lines.append("spec-led-eval — Stage 1 statistics report (E5)")
    lines.append("=" * 76)
    lines.append(f"Generated at:    {stats['generated_at']}")
    lines.append(f"α:               {stats['alpha']}")
    lines.append(f"N total runs:    {stats['n_total_runs']}")
    lines.append("N per richness:  " + ", ".join(
        f"{r}={n}" for r, n in stats["n_per_richness"].items()
    ))
    lines.append("N per domain:    " + ", ".join(
        f"{d}={n}" for d, n in stats["n_per_domain"].items()
    ))
    lines.append("")
    if stats["n_total_runs"] == 0:
        lines.append(
            "Insufficient data — eval/results/all_scores.csv contains "
            "no rows. Run the Stage-1 sweep (E6) first."
        )
        lines.append("")
        lines.append("=" * 76)
        return "\n".join(lines) + "\n"

    sufficient = any(
        n >= MIN_N_PER_GROUP for n in stats["n_per_richness"].values()
    )
    if not sufficient:
        lines.append(
            "Insufficient data — no richness group has the "
            f"minimum n={MIN_N_PER_GROUP} required for non-parametric "
            "tests. The Stage-1 sweep (E6) produces 30 runs per "
            "richness level. Re-run statistics.py after the sweep."
        )
        lines.append("")

    lines.append("-" * 76)
    lines.append("Section 1 — Overall richness effect (H1)")
    lines.append("-" * 76)
    lines.append(_format_kruskal_block(
        "1.1 Overall AQS partial vs richness (pooled across domains)",
        stats["tests"]["overall_richness"],
    ))
    lines.append("")

    lines.append("-" * 76)
    lines.append("Section 2 — Per-domain richness effect (H1)")
    lines.append("-" * 76)
    for dom in DOMAINS:
        res = stats["tests"]["per_domain_richness"][dom]
        title = f"2.{DOMAINS.index(dom) + 1} {dom} ({DOMAIN_NAMES[dom]})"
        lines.append(_format_kruskal_block(title, res))
        lines.append("")

    lines.append("-" * 76)
    lines.append("Section 3 — Pairwise richness contrasts on AQS partial (H1)")
    lines.append("-" * 76)
    lines.append(_format_pairwise_block(
        "3.1 Mann-Whitney U + Bonferroni + Cohen's d",
        stats["tests"]["pairwise_richness_aqs"],
    ))
    lines.append("")

    lines.append("-" * 76)
    lines.append("Section 4 — D5 verdict-stability differences (H3)")
    lines.append("-" * 76)
    lines.append(_format_kruskal_block(
        "4.1 Per-key D5 stability vs richness",
        stats["tests"]["d5_stability_richness"],
    ))
    lines.append("")
    lines.append(_format_pairwise_block(
        "4.2 Pairwise D5 contrasts (Mann-Whitney + Bonferroni)",
        stats["tests"]["pairwise_d5_richness"],
    ))
    lines.append("")

    if "model_effect_overall" in stats["tests"]:
        lines.append(_render_stage2_block(stats))

    lines.append("=" * 76)
    lines.append("End of report.")
    lines.append("=" * 76)
    return "\n".join(lines) + "\n"


def _render_stage2_block(stats: dict) -> str:
    """Render Sections 5–7 (Stage 2 — model factor; H5/H6/H7).

    Only called when `compute_stage1_statistics` detected multi-model
    data and merged the Stage-2 test keys into `stats["tests"]`.
    """
    lines: list[str] = []
    models = stats.get("stage2_models_present") or stats.get("models_present") or []
    n_per_model = stats.get("n_per_model", {})

    lines.append("-" * 76)
    lines.append("Section 5 — Model effect on AQS (H5)")
    lines.append("-" * 76)
    lines.append("Models present:  " + ", ".join(
        f"{m} (n={n_per_model.get(m, 0)})" for m in models
    ))
    lines.append("")
    lines.append(_format_kruskal_block(
        "5.1 Overall AQS partial vs model (pooled across cells)",
        stats["tests"]["model_effect_overall"],
    ))
    lines.append("")
    for r in RICHNESS_LEVELS:
        if r not in stats["tests"]["model_effect_per_richness"]:
            continue
        res = stats["tests"]["model_effect_per_richness"][r]
        title = (
            f"5.{RICHNESS_LEVELS.index(r) + 2} Model effect at "
            f"richness = {r}"
        )
        lines.append(_format_kruskal_block(title, res))
        lines.append("")
    for dom in DOMAINS:
        if dom not in stats["tests"]["model_effect_per_domain"]:
            continue
        res = stats["tests"]["model_effect_per_domain"][dom]
        title = (
            f"5.{len(RICHNESS_LEVELS) + 1 + DOMAINS.index(dom) + 1}"
            f" Model effect in domain {dom} ({DOMAIN_NAMES[dom]})"
        )
        lines.append(_format_kruskal_block(title, res))
        lines.append("")
    lines.append(_format_pairwise_block(
        f"5.{len(RICHNESS_LEVELS) + len(DOMAINS) + 2} "
        "Pairwise model contrasts on AQS partial (MW + Bonferroni)",
        stats["tests"]["pairwise_model_aqs"],
    ))
    lines.append("")

    lines.append("-" * 76)
    lines.append("Section 6 — Lever comparison (H6: model vs richness)")
    lines.append("-" * 76)
    lines.append(_format_h6_block(stats["tests"]["h6_lever_comparison"]))
    lines.append("")

    lines.append("-" * 76)
    lines.append("Section 7 — D5 verdict-stability by model (H7)")
    lines.append("-" * 76)
    lines.append(_format_kruskal_block(
        "7.1 Per-key D5 stability vs model",
        stats["tests"]["d5_stability_model"],
    ))
    lines.append("")
    lines.append(_format_pairwise_block(
        "7.2 Pairwise D5 contrasts by model (MW + Bonferroni)",
        stats["tests"]["pairwise_d5_model"],
    ))
    lines.append("")

    return "\n".join(lines)


def _format_h6_block(record: Mapping) -> str:
    lines: list[str] = []
    ml = record["model_lever"]
    rl = record["richness_lever"]
    lines.append(
        f"  Model lever:    "
        f"{ml['pair'][0]} vs {ml['pair'][1]} at richness="
        f"{ml['at_richness']}"
    )
    lines.append(
        f"    n_a={ml['n_a']}  n_b={ml['n_b']}  "
        f"Cohen's d = {_fmt_float(ml['cohen_d'])}  "
        f"|d| = {_fmt_float(ml['cohen_d_abs'])}  "
        f"({ml['cohen_d_label']})"
    )
    lines.append(
        f"  Richness lever: "
        f"{rl['pair'][0]} vs {rl['pair'][1]} at model="
        f"{rl['at_model']}"
    )
    lines.append(
        f"    n_a={rl['n_a']}  n_b={rl['n_b']}  "
        f"Cohen's d = {_fmt_float(rl['cohen_d'])}  "
        f"|d| = {_fmt_float(rl['cohen_d_abs'])}  "
        f"({rl['cohen_d_label']})"
    )
    if record.get("skipped"):
        lines.append(f"  Verdict: SKIPPED ({record['skip_reason']})")
    else:
        winner = record.get("winner", "?")
        margin = record.get("winner_margin")
        lines.append(
            f"  Winner: {winner} "
            f"(|d| margin = {_fmt_float(margin)})"
        )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def run(results_dir: Path) -> dict:
    """Run the full Stage-1 statistics pipeline against `results_dir`.

    Reads `all_scores.csv` and `d5_details.json`, writes
    `statistics_report.txt` + `statistics.json` next to them. Returns
    the statistics dict that was written. Never raises on
    insufficient data — produces graceful skip markers instead.
    """
    results_dir = Path(results_dir)
    scores_path = results_dir / "all_scores.csv"
    d5_path = results_dir / "d5_details.json"
    if not scores_path.exists():
        print(
            f"[statistics] {scores_path} not found — "
            "writing 'no data' report and exiting 0.",
            file=sys.stderr,
        )
        rows: list[dict] = []
    else:
        rows = load_all_scores(scores_path)
    d5_details = load_d5_details(d5_path) if d5_path.exists() else {}

    stats = compute_stage1_statistics(rows, d5_details)
    report = render_report(stats)
    (results_dir / "statistics_report.txt").write_text(report, encoding="utf-8")
    (results_dir / "statistics.json").write_text(
        json.dumps(stats, indent=2, sort_keys=False, default=_json_default)
        + "\n",
        encoding="utf-8",
    )
    print(report)
    return stats


def _json_default(obj):  # pragma: no cover — defensive
    if isinstance(obj, set):
        return sorted(obj)
    raise TypeError(f"Unserialisable: {type(obj)}")


def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Stage-1 statistical analysis (E5).",
    )
    p.add_argument(
        "--results-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "results",
        help="Directory containing all_scores.csv + d5_details.json "
             "(default: eval/results/).",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = _build_arg_parser().parse_args(argv)
    run(args.results_dir)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())

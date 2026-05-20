"""eval/visualise.py — Stage-1 + Stage-2 headline figures.

Produces the four Stage-1 figures pre-registered in
EVALUATION_PLAN.md §6 plus the two Stage-2 figures re-enabled
2026-05-19 (see [[project_eval_stage2_plan]]):

1. `bar_chart_aqs_by_richness.png` — grouped bar chart, 3 domains
   × 3 richness levels, mean `aqs_partial` with 95% CI error bars.
   Reads `all_scores.csv`.
2. `verdict_stability_heatmap.png` — D5 per (cell × normalised
   assertion-key group). Reads `d5_details.json`. Rows = cells,
   columns = keys present in ≥ 2 cells (sparse keys filtered for
   readability). Cell value = stability ∈ [0, 1].
3. `pattern_coverage.png` — number of distinct patterns activated
   per cell (union of `patterns_applied` across the cell's
   replicates), grouped by richness. Reads each run's
   `feature_model.manifest.json`.
4. `cost_efficiency.png` — dual-axis: cost-per-assertion (USD)
   and mean AQS vs richness, one line per domain. Reads each
   run's `cost_log.json` + `all_scores.csv`.
5. `bar_chart_aqs_by_model.png` (Stage 2) — three panels, one per
   domain, each with 3 richness × N models = up to 9 bars (mean
   `aqs_partial` ± 95% CI). Reads `all_scores.csv`. Skipped
   gracefully when only one model is present (Stage 1-only data).
6. `cost_quality_frontier.png` (Stage 2) — scatter of mean
   cost-per-run (USD, x-axis) against mean `aqs_partial` (y-axis),
   one point per (model, richness, domain) triple. The Pareto
   frontier (top-left points) is the practitioner takeaway. Reads
   each run's `cost_log.json` + `all_scores.csv`. Skipped when only
   one model is present.

Backend: matplotlib `Agg` (non-interactive). All figures saved
at 150 dpi.

Graceful degradation. If the source data has fewer cells / runs
than a figure needs, that figure is skipped with a stderr note
and the script keeps going. Single-cell N=1 smoke runs still
exit 0.

CLI:

    python eval/visualise.py
    python eval/visualise.py --results-dir eval/results/ \
                              --figures-dir eval/results/figures/
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable, Mapping, Sequence

import matplotlib
matplotlib.use("Agg")  # NOQA: E402 — must precede pyplot import
import matplotlib.pyplot as plt  # NOQA: E402
from matplotlib.patches import Patch  # NOQA: E402

try:
    from scipy.stats import t as _scipy_t
except ImportError as exc:  # pragma: no cover — module load failure
    raise SystemExit(
        "eval/visualise.py requires scipy. Install with: "
        "pip install --break-system-packages scipy"
    ) from exc


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

RICHNESS_LEVELS = ("L1", "L2", "L3")
DOMAINS = ("A", "B", "C")
DOMAIN_NAMES = {"A": "Banking", "B": "SaaS", "C": "Healthcare"}
DOMAIN_COLOURS = {"A": "#1f77b4", "B": "#ff7f0e", "C": "#2ca02c"}
RICHNESS_COLOURS = {"L1": "#a6cee3", "L2": "#1f78b4", "L3": "#08306b"}
RICHNESS_HATCH = {"L1": "", "L2": "//", "L3": "xx"}

DPI = 150
FIG_FILES = {
    "aqs_richness": "bar_chart_aqs_by_richness.png",
    "stability_heatmap": "verdict_stability_heatmap.png",
    "pattern_coverage": "pattern_coverage.png",
    "cost_efficiency": "cost_efficiency.png",
    # Stage 2 — re-enabled 2026-05-19
    "aqs_by_model": "bar_chart_aqs_by_model.png",
    "cost_quality_frontier": "cost_quality_frontier.png",
}

# Stage-2 model ordering + colours. M-best is canonical first to keep
# legends consistent across figures.
CANONICAL_MODEL_ORDER: tuple[str, ...] = ("M-best", "M-mid", "M-small")
MODEL_COLOURS: dict[str, str] = {
    "M-best":  "#1b4f72",   # deep blue
    "M-mid":   "#2980b9",   # mid blue
    "M-small": "#85c1e9",   # light blue
}
MODEL_MARKERS: dict[str, str] = {
    "M-best":  "o",
    "M-mid":   "s",
    "M-small": "^",
}

_CELL_RE = re.compile(r"^(?P<domain>[A-C])-?(?P<richness>L[123])$")
_FR_RE = re.compile(r"^FR_(\d+)_.*")


# ---------------------------------------------------------------------------
# Stats primitives (manual — sibling `statistics.py` shadows stdlib
# `statistics` when `eval/` is on sys.path).
# ---------------------------------------------------------------------------

def _mean(xs: Sequence[float]) -> float:
    return sum(xs) / len(xs)


def _stdev(xs: Sequence[float]) -> float:
    n = len(xs)
    m = _mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1))


# ---------------------------------------------------------------------------
# Parsing / loading
# ---------------------------------------------------------------------------

def parse_cell(cell: str) -> tuple[str, str]:
    m = _CELL_RE.match(cell)
    if not m:
        raise ValueError(f"Cannot parse cell name: {cell!r}")
    return m.group("domain"), m.group("richness")


def load_all_scores(path: Path) -> list[dict]:
    """Return per-run rows with `domain`/`richness` added. Skips rows
    whose cell can't be parsed (and warns to stderr)."""
    rows: list[dict] = []
    if not path.exists():
        return rows
    with path.open("r", encoding="utf-8", newline="") as fh:
        for raw in csv.DictReader(fh):
            try:
                domain, richness = parse_cell(raw["cell"])
            except ValueError as exc:
                print(f"[visualise] skip row: {exc}", file=sys.stderr)
                continue
            row = {
                "run_id": raw["run_id"],
                "cell": raw["cell"],
                "model": raw["model"],
                "rep": int(raw["rep"]) if raw.get("rep") else None,
                "domain": domain,
                "richness": richness,
            }
            v = raw.get("aqs_partial", "")
            row["aqs_partial"] = float(v) if v not in ("", None) else None
            rows.append(row)
    return rows


def load_d5_details(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def discover_run_dirs(runs_root: Path) -> dict[str, list[Path]]:
    """Walk runs_root → {cell: [run_dir, ...]} (sorted)."""
    out: dict[str, list[Path]] = defaultdict(list)
    if not runs_root.exists():
        return out
    for cell_dir in sorted(runs_root.iterdir()):
        if not cell_dir.is_dir():
            continue
        try:
            parse_cell(cell_dir.name)
        except ValueError:
            continue
        for model_dir in sorted(cell_dir.iterdir()):
            if not model_dir.is_dir():
                continue
            for run_dir in sorted(model_dir.iterdir()):
                if run_dir.is_dir() and run_dir.name.startswith("run_"):
                    out[cell_dir.name].append(run_dir)
    return out


def discover_run_dirs_by_model(
    runs_root: Path,
) -> dict[tuple[str, str], list[Path]]:
    """Like `discover_run_dirs` but keyed by (cell, model).

    Each Stage-2 figure that compares models needs the per-(cell, model)
    cohort separately rather than the union across models. Returns
    {(cell, model): [run_dir, ...]} sorted.
    """
    out: dict[tuple[str, str], list[Path]] = defaultdict(list)
    if not runs_root.exists():
        return out
    for cell_dir in sorted(runs_root.iterdir()):
        if not cell_dir.is_dir():
            continue
        try:
            parse_cell(cell_dir.name)
        except ValueError:
            continue
        for model_dir in sorted(cell_dir.iterdir()):
            if not model_dir.is_dir():
                continue
            for run_dir in sorted(model_dir.iterdir()):
                if run_dir.is_dir() and run_dir.name.startswith("run_"):
                    out[(cell_dir.name, model_dir.name)].append(run_dir)
    return out


def collect_cost_per_run_by_model(
    runs_by_cell_model: Mapping[tuple[str, str], Sequence[Path]],
) -> dict[tuple[str, str], list[float]]:
    """Per (cell, model) list of `cost_usd` floats from cost_log.json.

    Skips missing files / malformed JSON / None values silently. Used
    by Stage-2 Figure 6 (cost-quality frontier).
    """
    out: dict[tuple[str, str], list[float]] = {}
    for key, run_dirs in runs_by_cell_model.items():
        vals: list[float] = []
        for run_dir in run_dirs:
            cost_path = run_dir / "cost_log.json"
            if not cost_path.exists():
                continue
            try:
                cost = json.loads(cost_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue
            v = cost.get("cost_usd")
            if v is None:
                continue
            try:
                vals.append(float(v))
            except (TypeError, ValueError):
                continue
        out[key] = vals
    return out


def models_present_in_rows(rows: Iterable[Mapping]) -> list[str]:
    """Return present models with canonical M-best/M-mid/M-small ordering.

    Unknown models (tier strings outside the canonical three) are
    appended alphabetically — mirror of statistics.models_present.
    """
    seen: set[str] = set()
    for r in rows:
        m = r.get("model")
        if m:
            seen.add(str(m))
    ordered = [m for m in CANONICAL_MODEL_ORDER if m in seen]
    extras = sorted(m for m in seen if m not in set(CANONICAL_MODEL_ORDER))
    return ordered + extras


def collect_patterns_per_cell(
    runs_by_cell: Mapping[str, Sequence[Path]],
) -> dict[str, set[str]]:
    """Union of `patterns_applied` across each cell's replicates."""
    out: dict[str, set[str]] = {}
    for cell, run_dirs in runs_by_cell.items():
        union: set[str] = set()
        for run_dir in run_dirs:
            manifest_path = run_dir / "feature_model.manifest.json"
            if not manifest_path.exists():
                continue
            try:
                manifest = json.loads(
                    manifest_path.read_text(encoding="utf-8")
                )
            except json.JSONDecodeError:
                continue
            patterns = manifest.get("patterns_applied") or []
            union.update(patterns)
        out[cell] = union
    return out


def collect_cost_per_assertion(
    runs_by_cell: Mapping[str, Sequence[Path]],
) -> dict[str, list[float]]:
    """Per-cell list of `cost_per_assertion_usd` floats (skips
    missing / null values)."""
    out: dict[str, list[float]] = {}
    for cell, run_dirs in runs_by_cell.items():
        vals: list[float] = []
        for run_dir in run_dirs:
            cost_path = run_dir / "cost_log.json"
            if not cost_path.exists():
                continue
            try:
                cost = json.loads(cost_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue
            v = cost.get("cost_per_assertion_usd")
            if v is None:
                continue
            try:
                vals.append(float(v))
            except (TypeError, ValueError):
                continue
        out[cell] = vals
    return out


# ---------------------------------------------------------------------------
# Statistics helpers (local — no dependency on statistics.py)
# ---------------------------------------------------------------------------

def mean_and_ci95(values: Sequence[float]) -> tuple[float | None, float]:
    """Returns (mean, ci_halfwidth). ci_halfwidth = 0 when n < 2
    (single observation has no spread).
    """
    n = len(values)
    if n == 0:
        return None, 0.0
    m = _mean(values)
    if n < 2:
        return m, 0.0
    sd = _stdev(values)
    se = sd / math.sqrt(n)
    # Two-sided 95% via Student-t with n-1 dof.
    t_crit = float(_scipy_t.ppf(0.975, df=n - 1))
    return m, t_crit * se


# ---------------------------------------------------------------------------
# Figure 1 — bar_chart_aqs_by_richness.png
# ---------------------------------------------------------------------------

def figure_aqs_richness(
    rows: list[dict], out_path: Path,
) -> tuple[bool, str | None]:
    """Grouped bar chart: 3 domains × 3 richness × mean aqs_partial
    with 95% CI error bars."""
    # Partition rows by (domain, richness).
    bucket: dict[tuple[str, str], list[float]] = defaultdict(list)
    for row in rows:
        if row.get("aqs_partial") is None:
            continue
        bucket[(row["domain"], row["richness"])].append(row["aqs_partial"])

    if not bucket:
        return False, "no aqs_partial values in all_scores.csv"

    fig, ax = plt.subplots(figsize=(10, 6))
    n_dom = len(DOMAINS)
    n_rich = len(RICHNESS_LEVELS)
    bar_width = 0.8 / n_rich
    x_base = list(range(n_dom))

    drew_any = False
    for i, rich in enumerate(RICHNESS_LEVELS):
        means, errs = [], []
        for dom in DOMAINS:
            vs = bucket.get((dom, rich), [])
            m, ci = mean_and_ci95(vs)
            means.append(m if m is not None else 0.0)
            errs.append(ci)
        offsets = [
            xb + (i - (n_rich - 1) / 2.0) * bar_width for xb in x_base
        ]
        ax.bar(
            offsets,
            means,
            width=bar_width,
            yerr=errs,
            color=RICHNESS_COLOURS[rich],
            edgecolor="black",
            label=rich,
            capsize=4,
        )
        # Annotate n
        for off, dom in zip(offsets, DOMAINS):
            n = len(bucket.get((dom, rich), []))
            if n:
                drew_any = True
                ax.text(
                    off,
                    -0.04,
                    f"n={n}",
                    ha="center",
                    va="top",
                    fontsize=7,
                    color="grey",
                )

    ax.set_xticks(x_base)
    ax.set_xticklabels(
        [f"{d}\n{DOMAIN_NAMES[d]}" for d in DOMAINS]
    )
    ax.set_ylim(0, 1.05)
    ax.set_ylabel("AQS partial (mean ± 95% CI)")
    ax.set_xlabel("Application domain")
    ax.set_title(
        "Mean AQS partial by domain × richness (Stage 1, M-best)"
    )
    ax.axhline(0.5, color="grey", linewidth=0.5, linestyle=":")
    ax.legend(title="Richness", loc="lower right")
    ax.grid(axis="y", linewidth=0.3, alpha=0.5)

    fig.tight_layout()
    fig.savefig(out_path, dpi=DPI)
    plt.close(fig)
    if not drew_any:
        return False, "no non-empty (domain, richness) cells to plot"
    return True, None


# ---------------------------------------------------------------------------
# Figure 2 — verdict_stability_heatmap.png
# ---------------------------------------------------------------------------

def figure_stability_heatmap(
    d5_details: Mapping[str, dict], out_path: Path,
    *, min_cell_appearances: int = 2,
) -> tuple[bool, str | None]:
    """D5 per (cell × normalised-key) heatmap. Filters keys that
    appear in fewer than `min_cell_appearances` cells for readability.
    """
    if not d5_details:
        return False, "d5_details.json is empty / missing"
    # Collect per-cell stability per key.
    per_cell_keys: dict[str, dict[str, float]] = {}
    for cm_key, payload in d5_details.items():
        cell = cm_key.split("/", 1)[0]
        per_key = payload.get("per_key", {})
        per_cell_keys[cell] = {
            k: float(info["stability"])
            for k, info in per_key.items()
            if info.get("stability") is not None
        }
    cells = sorted(per_cell_keys.keys())
    # Count which keys appear in ≥ min cells.
    key_count: dict[str, int] = defaultdict(int)
    for keys in per_cell_keys.values():
        for k in keys:
            key_count[k] += 1
    keys = [k for k, c in key_count.items() if c >= min_cell_appearances]
    if not keys:
        # Fall back: show every key (single-cell N=1 smoke case).
        keys = sorted({k for keys in per_cell_keys.values() for k in keys})
        if not keys:
            return False, "no per-key stability values in d5_details.json"
        filter_note = (
            f" (no keys recurred ≥{min_cell_appearances} cells; "
            "showing all keys)"
        )
    else:
        filter_note = (
            f" (keys recurring in ≥{min_cell_appearances} cells; "
            f"{len(keys)} of {len(key_count)})"
        )

    # Order keys: patterns first, then FR-NNN sorted numerically, then others.
    def _sort_key(k: str):
        if _FR_RE.match(k) or k.startswith("FR-"):
            num = re.search(r"\d+", k)
            return (1, int(num.group()) if num else 0, k)
        return (0, 0, k)
    keys = sorted(keys, key=_sort_key)

    # Build matrix.
    nan = float("nan")
    matrix = []
    for cell in cells:
        row_vals = [per_cell_keys[cell].get(k, nan) for k in keys]
        matrix.append(row_vals)

    fig_w = max(6.5, 0.55 * len(keys) + 2.5)
    fig_h = max(4.5, 0.45 * len(cells) + 2.0)
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))
    import numpy as np
    arr = np.array(matrix, dtype=float)
    im = ax.imshow(arr, aspect="auto", cmap="RdYlGn",
                   vmin=0.0, vmax=1.0)
    ax.set_xticks(range(len(keys)))
    ax.set_xticklabels(keys, rotation=45, ha="right", fontsize=8)
    ax.set_yticks(range(len(cells)))
    ax.set_yticklabels(cells, fontsize=9)
    # Annotate
    for r, cell in enumerate(cells):
        for c, key in enumerate(keys):
            v = per_cell_keys[cell].get(key)
            if v is None:
                continue
            ax.text(
                c, r, f"{v:.2f}",
                ha="center", va="center", fontsize=7,
                color="black" if 0.35 <= v <= 0.75 else (
                    "white" if v < 0.35 else "black"
                ),
            )
    cbar = fig.colorbar(im, ax=ax, fraction=0.025, pad=0.02)
    cbar.set_label("Per-key stability (D5 component)")
    ax.set_xlabel("Normalised assertion key" + filter_note)
    ax.set_ylabel("Cell")
    ax.set_title(
        "Verdict-stability heatmap — D5 per cell × assertion key"
    )
    fig.tight_layout()
    fig.savefig(out_path, dpi=DPI)
    plt.close(fig)
    return True, None


# ---------------------------------------------------------------------------
# Figure 3 — pattern_coverage.png
# ---------------------------------------------------------------------------

def figure_pattern_coverage(
    patterns_by_cell: Mapping[str, set[str]], out_path: Path,
) -> tuple[bool, str | None]:
    """Distinct patterns activated per cell, grouped/coloured by richness."""
    cells_with_data = [
        c for c, s in patterns_by_cell.items() if len(s) > 0
    ]
    if not cells_with_data:
        return False, "no manifest patterns_applied found in any run"

    # Sort cells: by richness then by domain.
    def _cell_sort(c: str):
        d, r = parse_cell(c)
        return (RICHNESS_LEVELS.index(r), DOMAINS.index(d))
    sorted_cells = sorted(patterns_by_cell.keys(), key=_cell_sort)

    counts = [len(patterns_by_cell[c]) for c in sorted_cells]
    richnesses = [parse_cell(c)[1] for c in sorted_cells]
    colours = [RICHNESS_COLOURS[r] for r in richnesses]

    fig, ax = plt.subplots(figsize=(10, 5.5))
    bars = ax.bar(
        range(len(sorted_cells)),
        counts,
        color=colours,
        edgecolor="black",
    )
    ax.set_xticks(range(len(sorted_cells)))
    ax.set_xticklabels(sorted_cells, rotation=0)
    ax.set_ylabel("Distinct patterns activated (cell-wide union)")
    ax.set_xlabel("Cell")
    ax.set_title(
        "Pattern activation breadth per cell (Stage 1, M-best) — H4"
    )

    for bar, n in zip(bars, counts):
        ax.text(
            bar.get_x() + bar.get_width() / 2.0,
            bar.get_height() + 0.15,
            str(n),
            ha="center", va="bottom", fontsize=8,
        )

    handles = [
        Patch(facecolor=RICHNESS_COLOURS[r], edgecolor="black", label=r)
        for r in RICHNESS_LEVELS
    ]
    ax.legend(handles=handles, title="Richness", loc="upper left")
    ax.grid(axis="y", linewidth=0.3, alpha=0.5)
    fig.tight_layout()
    fig.savefig(out_path, dpi=DPI)
    plt.close(fig)
    return True, None


# ---------------------------------------------------------------------------
# Figure 4 — cost_efficiency.png
# ---------------------------------------------------------------------------

def figure_cost_efficiency(
    rows: list[dict],
    cost_by_cell: Mapping[str, Sequence[float]],
    out_path: Path,
) -> tuple[bool, str | None]:
    """Dual-axis: cost-per-assertion (USD) and mean AQS vs richness.
    One line per domain on each axis.
    """
    # Mean AQS partial per (domain, richness).
    aqs_bucket: dict[tuple[str, str], list[float]] = defaultdict(list)
    for row in rows:
        if row.get("aqs_partial") is None:
            continue
        aqs_bucket[(row["domain"], row["richness"])].append(row["aqs_partial"])
    # Mean cost-per-assertion per (domain, richness) from cost_by_cell.
    cost_bucket: dict[tuple[str, str], list[float]] = defaultdict(list)
    for cell, vals in cost_by_cell.items():
        try:
            dom, rich = parse_cell(cell)
        except ValueError:
            continue
        cost_bucket[(dom, rich)].extend(vals)

    if not aqs_bucket and not cost_bucket:
        return False, "no AQS or cost-per-assertion data"

    fig, ax_cost = plt.subplots(figsize=(10, 6))
    ax_aqs = ax_cost.twinx()
    x_positions = list(range(len(RICHNESS_LEVELS)))

    plotted = False
    for dom in DOMAINS:
        colour = DOMAIN_COLOURS[dom]
        cost_means = []
        cost_present = []
        aqs_means = []
        aqs_present = []
        for r in RICHNESS_LEVELS:
            cs = cost_bucket.get((dom, r), [])
            if cs:
                cost_means.append(_mean(cs))
                cost_present.append(True)
            else:
                cost_means.append(float("nan"))
                cost_present.append(False)
            asu = aqs_bucket.get((dom, r), [])
            if asu:
                aqs_means.append(_mean(asu))
                aqs_present.append(True)
            else:
                aqs_means.append(float("nan"))
                aqs_present.append(False)
        if any(cost_present):
            ax_cost.plot(
                x_positions, cost_means,
                color=colour, marker="o", linewidth=2,
                label=f"{dom} cost/assertion",
            )
            plotted = True
        if any(aqs_present):
            ax_aqs.plot(
                x_positions, aqs_means,
                color=colour, marker="s", linewidth=1.5,
                linestyle="--",
                label=f"{dom} mean AQS",
            )
            plotted = True

    ax_cost.set_xticks(x_positions)
    ax_cost.set_xticklabels(RICHNESS_LEVELS)
    ax_cost.set_xlabel("Richness")
    ax_cost.set_ylabel("Cost per assertion (USD)", color="#444444")
    ax_aqs.set_ylabel("Mean AQS partial", color="#444444")
    ax_aqs.set_ylim(0, 1.05)
    ax_cost.set_title(
        "Cost efficiency — cost/assertion (solid) vs mean AQS (dashed) "
        "by richness, per domain"
    )

    # Merged legend
    h1, l1 = ax_cost.get_legend_handles_labels()
    h2, l2 = ax_aqs.get_legend_handles_labels()
    ax_cost.legend(h1 + h2, l1 + l2, loc="upper left", fontsize=8)
    ax_cost.grid(axis="y", linewidth=0.3, alpha=0.5)
    fig.tight_layout()
    fig.savefig(out_path, dpi=DPI)
    plt.close(fig)
    if not plotted:
        return False, "no series had any points"
    return True, None


# ---------------------------------------------------------------------------
# Figure 5 — bar_chart_aqs_by_model.png  (Stage 2)
# ---------------------------------------------------------------------------

def figure_aqs_by_model(
    rows: list[dict], out_path: Path,
) -> tuple[bool, str | None]:
    """Three panels (one per domain), each panel has 3 richness × N
    models bars with mean `aqs_partial` ± 95% CI.

    Skipped (False) when only one model is present — Stage-1 figure 1
    already covers single-model data.
    """
    models = models_present_in_rows(rows)
    if len(models) < 2:
        return False, (
            "Stage-2 figure_aqs_by_model needs ≥2 models in all_scores.csv "
            f"(present: {models or '∅'}). Skipped — Stage 1 only."
        )

    # bucket[(domain, richness, model)] = [aqs_partial values]
    bucket: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    for row in rows:
        if row.get("aqs_partial") is None:
            continue
        if row.get("model") not in models:
            continue
        bucket[(row["domain"], row["richness"], row["model"])].append(
            row["aqs_partial"]
        )

    if not bucket:
        return False, "no aqs_partial values for any (domain, richness, model)"

    n_dom = len(DOMAINS)
    fig, axes = plt.subplots(
        1, n_dom, figsize=(4.5 * n_dom, 5.5), sharey=True,
    )
    if n_dom == 1:
        axes = [axes]

    n_rich = len(RICHNESS_LEVELS)
    n_models = len(models)
    bar_width = 0.8 / n_models
    x_base = list(range(n_rich))

    drew_any = False
    for ax, dom in zip(axes, DOMAINS):
        for i, model in enumerate(models):
            means, errs = [], []
            for rich in RICHNESS_LEVELS:
                vs = bucket.get((dom, rich, model), [])
                m, ci = mean_and_ci95(vs)
                means.append(m if m is not None else 0.0)
                errs.append(ci)
            offsets = [
                xb + (i - (n_models - 1) / 2.0) * bar_width for xb in x_base
            ]
            colour = MODEL_COLOURS.get(model, f"C{i}")
            ax.bar(
                offsets, means, width=bar_width, yerr=errs,
                color=colour, edgecolor="black", capsize=3,
                label=model if ax is axes[0] else None,
            )
            for off, rich in zip(offsets, RICHNESS_LEVELS):
                n = len(bucket.get((dom, rich, model), []))
                if n:
                    drew_any = True
                    ax.text(
                        off, -0.03, f"n={n}",
                        ha="center", va="top", fontsize=6, color="grey",
                    )
        ax.set_xticks(x_base)
        ax.set_xticklabels(RICHNESS_LEVELS)
        ax.set_ylim(0, 1.05)
        ax.set_xlabel("Richness")
        ax.set_title(f"{dom} — {DOMAIN_NAMES[dom]}")
        ax.grid(axis="y", linewidth=0.3, alpha=0.5)
        ax.axhline(0.5, color="grey", linewidth=0.4, linestyle=":")
    axes[0].set_ylabel("AQS partial (mean ± 95% CI)")
    axes[0].legend(title="Model", loc="lower right", fontsize=8)
    fig.suptitle("AQS partial by domain × richness × model (Stage 2, H5)")
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(out_path, dpi=DPI)
    plt.close(fig)
    if not drew_any:
        return False, "no non-empty (domain, richness, model) cells to plot"
    return True, None


# ---------------------------------------------------------------------------
# Figure 6 — cost_quality_frontier.png  (Stage 2)
# ---------------------------------------------------------------------------

def figure_cost_quality_frontier(
    rows: list[dict],
    cost_by_cell_model: Mapping[tuple[str, str], Sequence[float]],
    out_path: Path,
) -> tuple[bool, str | None]:
    """Scatter: X = mean cost-per-run (USD), Y = mean aqs_partial.

    One point per (model, richness, domain) triple. Coloured by model;
    marker shape by model so colour-blind readers can still distinguish
    series. Pareto-frontier points (top-left, i.e. high AQS at low cost)
    are highlighted with a thin connecting line.

    Skipped when fewer than two distinct models are present in either
    the AQS rows or the cost data — at that point Stage-1's
    `cost_efficiency` figure already covers single-model economics.
    """
    aqs_models = set(models_present_in_rows(rows))
    cost_models = {key[1] for key in cost_by_cell_model.keys()}
    models = [m for m in CANONICAL_MODEL_ORDER
              if m in (aqs_models | cost_models)]
    extras = sorted(
        (aqs_models | cost_models) - set(CANONICAL_MODEL_ORDER)
    )
    models = models + extras
    if len(models) < 2:
        return False, (
            "Stage-2 figure_cost_quality_frontier needs ≥2 models "
            f"(present: {models or '∅'}). Skipped — Stage 1 only."
        )

    # Mean aqs_partial per (model, richness, domain).
    aqs_bucket: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    for row in rows:
        if row.get("aqs_partial") is None:
            continue
        if row.get("model") not in models:
            continue
        aqs_bucket[(row["model"], row["richness"], row["domain"])].append(
            row["aqs_partial"]
        )

    # Mean cost per (model, richness, domain). cost_by_cell_model is
    # keyed by (cell, model), so we re-bucket by domain × richness.
    cost_bucket: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    for (cell, model), vals in cost_by_cell_model.items():
        try:
            dom, rich = parse_cell(cell)
        except ValueError:
            continue
        if model not in models:
            continue
        cost_bucket[(model, rich, dom)].extend(vals)

    # Build point list — only triples with BOTH cost and aqs data.
    points: list[dict] = []
    for model in models:
        for rich in RICHNESS_LEVELS:
            for dom in DOMAINS:
                aqs_vals = aqs_bucket.get((model, rich, dom), [])
                cost_vals = cost_bucket.get((model, rich, dom), [])
                if not aqs_vals or not cost_vals:
                    continue
                points.append({
                    "model": model,
                    "richness": rich,
                    "domain": dom,
                    "mean_cost": _mean(cost_vals),
                    "mean_aqs": _mean(aqs_vals),
                    "n_aqs": len(aqs_vals),
                    "n_cost": len(cost_vals),
                })

    if not points:
        return False, (
            "no (model, richness, domain) triple has BOTH cost and "
            "aqs_partial values"
        )

    fig, ax = plt.subplots(figsize=(10, 6))
    by_model: dict[str, list[dict]] = defaultdict(list)
    for p in points:
        by_model[p["model"]].append(p)
    for model in models:
        pts = by_model.get(model, [])
        if not pts:
            continue
        xs = [p["mean_cost"] for p in pts]
        ys = [p["mean_aqs"] for p in pts]
        ax.scatter(
            xs, ys,
            color=MODEL_COLOURS.get(model, "#888888"),
            marker=MODEL_MARKERS.get(model, "o"),
            s=70, edgecolor="black", linewidth=0.6,
            label=model, alpha=0.85, zorder=3,
        )
        # Annotate each point with its richness/domain combo.
        for p in pts:
            ax.annotate(
                f"{p['domain']}-{p['richness']}",
                (p["mean_cost"], p["mean_aqs"]),
                textcoords="offset points", xytext=(5, 4),
                fontsize=6, color="#444444",
            )

    # Pareto frontier: maximise AQS, minimise cost. Sort by cost asc;
    # walk through and keep points whose AQS exceeds the running max.
    sorted_pts = sorted(points, key=lambda p: (p["mean_cost"], -p["mean_aqs"]))
    frontier: list[dict] = []
    best_aqs = -1.0
    for p in sorted_pts:
        if p["mean_aqs"] > best_aqs:
            frontier.append(p)
            best_aqs = p["mean_aqs"]
    if len(frontier) >= 2:
        fx = [p["mean_cost"] for p in frontier]
        fy = [p["mean_aqs"] for p in frontier]
        ax.plot(
            fx, fy,
            color="#333333", linestyle=":", linewidth=1.2, alpha=0.5,
            zorder=2, label="Pareto frontier",
        )

    ax.set_xlabel("Mean cost per run (USD)")
    ax.set_ylabel("Mean AQS partial")
    ax.set_ylim(0, 1.05)
    ax.set_xscale("log")
    ax.grid(True, which="both", linewidth=0.3, alpha=0.4)
    ax.set_title(
        "Cost / quality frontier — mean AQS vs mean $/run "
        "by (model, richness, domain)"
    )
    ax.legend(title="Model", loc="lower right", fontsize=8)

    fig.tight_layout()
    fig.savefig(out_path, dpi=DPI)
    plt.close(fig)
    return True, None


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

def run(results_dir: Path, figures_dir: Path,
        runs_root: Path | None = None) -> dict[str, dict]:
    """Produce every renderable figure under `figures_dir`.

    Returns a dict {fig_key: {"path": Path|None, "skipped": bool,
    "reason": str|None}} so callers can see what got built and why.
    """
    results_dir = Path(results_dir)
    figures_dir = Path(figures_dir)
    figures_dir.mkdir(parents=True, exist_ok=True)

    if runs_root is None:
        runs_root = results_dir.parent / "runs"
    runs_root = Path(runs_root)

    rows = load_all_scores(results_dir / "all_scores.csv")
    d5_details = load_d5_details(results_dir / "d5_details.json")
    runs_by_cell = discover_run_dirs(runs_root)
    runs_by_cell_model = discover_run_dirs_by_model(runs_root)
    patterns_by_cell = collect_patterns_per_cell(runs_by_cell)
    cost_by_cell = collect_cost_per_assertion(runs_by_cell)
    cost_by_cell_model = collect_cost_per_run_by_model(runs_by_cell_model)

    outcomes: dict[str, dict] = {}

    def _emit(key: str, fn):
        out_path = figures_dir / FIG_FILES[key]
        try:
            ok, reason = fn()
        except Exception as exc:  # pragma: no cover — defensive
            print(f"[visualise] figure {key} crashed: {exc!r}",
                  file=sys.stderr)
            outcomes[key] = {"path": None, "skipped": True,
                             "reason": f"exception: {exc!r}"}
            return
        if ok:
            outcomes[key] = {"path": str(out_path),
                             "skipped": False, "reason": None}
            print(f"[visualise] wrote {out_path}")
        else:
            outcomes[key] = {"path": None, "skipped": True, "reason": reason}
            print(f"[visualise] skipped {key}: {reason}", file=sys.stderr)

    _emit("aqs_richness",
          lambda: figure_aqs_richness(rows,
                                       figures_dir / FIG_FILES["aqs_richness"]))
    _emit("stability_heatmap",
          lambda: figure_stability_heatmap(
              d5_details,
              figures_dir / FIG_FILES["stability_heatmap"]))
    _emit("pattern_coverage",
          lambda: figure_pattern_coverage(
              patterns_by_cell,
              figures_dir / FIG_FILES["pattern_coverage"]))
    _emit("cost_efficiency",
          lambda: figure_cost_efficiency(
              rows, cost_by_cell,
              figures_dir / FIG_FILES["cost_efficiency"]))
    # Stage 2 — automatically skipped on single-model data.
    _emit("aqs_by_model",
          lambda: figure_aqs_by_model(
              rows, figures_dir / FIG_FILES["aqs_by_model"]))
    _emit("cost_quality_frontier",
          lambda: figure_cost_quality_frontier(
              rows, cost_by_cell_model,
              figures_dir / FIG_FILES["cost_quality_frontier"]))

    produced = sum(1 for o in outcomes.values() if not o["skipped"])
    skipped = sum(1 for o in outcomes.values() if o["skipped"])
    print(
        f"[visualise] {produced} figure(s) produced, {skipped} skipped."
    )
    return outcomes


def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Stage-1 headline figures (E5).",
    )
    default_results = Path(__file__).resolve().parent / "results"
    p.add_argument(
        "--results-dir", type=Path, default=default_results,
        help="Directory containing all_scores.csv + d5_details.json "
             "(default: eval/results/).",
    )
    p.add_argument(
        "--figures-dir", type=Path, default=None,
        help="Directory where PNGs are written (default: "
             "<results-dir>/figures/).",
    )
    p.add_argument(
        "--runs-root", type=Path, default=None,
        help="Directory containing per-run artefacts (default: "
             "<results-dir>/../runs/).",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = _build_arg_parser().parse_args(argv)
    figures_dir = (
        args.figures_dir if args.figures_dir is not None
        else args.results_dir / "figures"
    )
    run(args.results_dir, figures_dir, runs_root=args.runs_root)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())

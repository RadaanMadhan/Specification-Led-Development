"""
scorer.py
---------
Deterministic KPI Quality Score (KQS) scorer.

Loads a (kpi_record, gqm_record) pair and returns D1, D3, D4 dimension scores
plus kqs_partial = mean(D1, D3, D4).
D5 is computed externally at aggregation time because it requires multiple runs
of the same (spec_id, fr_id, metric_name).

Usage:
    python scorer.py <gqm_output.json> <kpi_output.json> <spec_id> <run_n>

Or import and call score_run() / score_pair() directly.
"""

import json
import re
from pathlib import Path


# ── D3 keyword sets ────────────────────────────────────────────────────────────
LTE_KEYWORDS = {
    "latency", "time", "seconds", "ms", "milliseconds", "error",
    "cost", "mttr", "duration", "overhead", "spend",
}
GTE_KEYWORDS = {
    "coverage", "uptime", "availability", "success", "rate",
    "percentage", "score", "throughput", "sla",
}

# ── D4 constants ───────────────────────────────────────────────────────────────
VALID_METRIC_UNITS = {
    "percentage", "milliseconds", "seconds", "hours", "currency", "count",
}
SNAKE_CASE_RE = re.compile(r"^[a-z][a-z0-9_]*$")
VERB_RE = re.compile(
    r"\b(is|are|was|were|should|must|ensure|contain|verify|check|measure|"
    r"calculate|determine|indicate|shows|returns|provides)\b",
    re.IGNORECASE,
)

VAGUE_WORDS = {"acceptable", "reasonable", "appropriate", "adequate", "sufficient"}


# ══════════════════════════════════════════════════════════════════════════════
# D1 — Threshold specificity
# ══════════════════════════════════════════════════════════════════════════════

def score_d1(kpi_record: dict) -> float:
    """
    Scores threshold specificity from a kpi_output record.

    Args:
        kpi_record: single dict from kpi_output.json. Expected keys:
                    threshold_numeric (float | None), threshold_value (str | None),
                    threshold_direction (str).

    Returns:
        1.0 — threshold_numeric is not null AND value is non-trivial
              (gte: numeric > 0; lte: 0 < numeric < 999999)
        0.5 — threshold_value string present but threshold_numeric is null
        0.0 — both null, empty, or threshold_value contains vague language

    Edge cases:
        - None threshold_value AND None numeric → 0.0
        - threshold_numeric == 0 with direction "gte" → 0.0 (trivial)
        - threshold_numeric >= 999999 with direction "lte" → 0.0 (trivial upper bound)
    """
    numeric = kpi_record.get("threshold_numeric")
    value_str = kpi_record.get("threshold_value") or ""
    direction = kpi_record.get("threshold_direction", "")

    if any(w in value_str.lower() for w in VAGUE_WORDS):
        return 0.0

    if numeric is None:
        return 0.5 if value_str.strip() else 0.0

    if direction == "gte":
        non_trivial = numeric > 0
    elif direction == "lte":
        non_trivial = 0 < numeric < 999999
    else:
        non_trivial = numeric > 0

    return 1.0 if non_trivial else 0.0


# ══════════════════════════════════════════════════════════════════════════════
# D3 — Directionality coherence
# ══════════════════════════════════════════════════════════════════════════════

def _classify_direction(text: str) -> str | None:
    """
    Classifies a metric name or unit as 'lte', 'gte', or None.

    Args:
        text: metric_name or metric_unit string to inspect.

    Returns:
        'lte' if only lte keywords found, 'gte' if only gte keywords found,
        None if both or neither are found (caller applies benefit of doubt).

    Edge cases:
        - Mixed keywords (e.g. "error_rate") → None (ambiguous, caller scores 1.0)
    """
    tokens = set(re.sub(r"[_\s]+", " ", text.lower()).split())
    has_lte = bool(tokens & LTE_KEYWORDS)
    has_gte = bool(tokens & GTE_KEYWORDS)

    if has_lte and not has_gte:
        return "lte"
    if has_gte and not has_lte:
        return "gte"
    return None


def score_d3(kpi_record: dict, gqm_record: dict) -> float:
    """
    Scores directionality coherence between threshold direction and metric semantics.

    Args:
        kpi_record: single dict from kpi_output.json (needs threshold_direction).
        gqm_record: matching dict from gqm_output.json (needs metric_name, metric_unit).

    Returns:
        1.0 — direction matches keyword category of metric_name or metric_unit,
              OR no keywords match in either field (benefit of the doubt)
        0.0 — direction is inverted relative to keyword match

    Edge cases:
        - metric_name matches neither keyword list → fall through to metric_unit check
        - both metric_name and metric_unit give no match → 1.0 (benefit of doubt)
        - ambiguous keyword mix in metric_name → None → check metric_unit
    """
    direction = kpi_record.get("threshold_direction", "")
    metric_name = gqm_record.get("metric_name", "") or ""
    metric_unit = gqm_record.get("metric_unit", "") or ""

    expected = _classify_direction(metric_name)
    if expected is None:
        expected = _classify_direction(metric_unit)

    if expected is None:
        return 1.0

    return 1.0 if direction == expected else 0.0


# ══════════════════════════════════════════════════════════════════════════════
# D4 — GQM chain coherence
# ══════════════════════════════════════════════════════════════════════════════

def score_d4(gqm_record: dict) -> float:
    """
    Scores GQM chain coherence from a gqm_output record.

    Args:
        gqm_record: single dict from gqm_output.json (needs metric_name, metric_unit).

    Returns:
        1.0 — metric_name matches snake_case pattern AND metric_unit is in valid set
        0.5 — metric_name is readable but not snake_case (spaces or mixed case)
        0.0 — metric_name contains a verb (sentence fragment), or metric_unit is
              missing / not in the valid set

    Edge cases:
        - Empty or None metric_name → 0.0
        - metric_unit present but not in VALID_METRIC_UNITS → 0.0
        - metric_name passes snake_case but metric_unit is invalid → 0.0
    """
    metric_name = (gqm_record.get("metric_name") or "").strip()
    metric_unit = (gqm_record.get("metric_unit") or "").strip().lower()

    if not metric_name:
        return 0.0

    if not metric_unit or metric_unit not in VALID_METRIC_UNITS:
        return 0.0

    if VERB_RE.search(metric_name):
        return 0.0

    if SNAKE_CASE_RE.match(metric_name):
        return 1.0

    return 0.5


# ══════════════════════════════════════════════════════════════════════════════
# Pair and run scoring
# ══════════════════════════════════════════════════════════════════════════════

def _extract_fr_id(kpi_record: dict) -> str:
    """
    Extracts the FR identifier from the kpi_record notes field.

    Args:
        kpi_record: single dict from kpi_output.json.

    Returns:
        FR identifier string (e.g. 'FR-001'), or 'unknown' if not found.

    Edge cases:
        - None or empty notes → 'unknown'
        - Notes with no FR-NNN pattern → 'unknown'
    """
    notes = kpi_record.get("notes") or ""
    m = re.search(r"(FR-\d+)", notes)
    return m.group(1) if m else "unknown"


def score_pair(
    kpi_record: dict,
    gqm_record: dict | None,
    spec_id: str,
    run_id: str,
) -> dict:
    """
    Scores a single (kpi_record, gqm_record) pair across dimensions D1, D3, D4.

    kqs_partial = mean(D1, D3, D4) — three dimensions.

    Args:
        kpi_record: single dict from kpi_output.json.
        gqm_record: matching dict from gqm_output.json, joined by
                    kpi_record['gqm_id'] == gqm_record['id']. May be None
                    if the join fails (all GQM-dependent scores → 0.0).
        spec_id:    experiment spec identifier, e.g. 'A-L1'.
        run_id:     run identifier, e.g. 'A-L1_run_03'.

    Returns:
        Dict with fields: run_id, spec_id, richness, context, fr_id, kpi_id,
        gqm_id, pillar_id, metric_name, threshold_numeric, threshold_direction,
        waf_code_refs, d1, d3, d4, kqs_partial.

    Edge cases:
        - gqm_record is None → d3, d4 all 0.0
        - spec_id shorter than 4 chars → context/richness default to '?'
    """
    d1 = score_d1(kpi_record)
    d3 = score_d3(kpi_record, gqm_record) if gqm_record else 0.0
    d4 = score_d4(gqm_record) if gqm_record else 0.0
    kqs_partial = round((d1 + d3 + d4) / 3, 4)

    context  = spec_id[0] if spec_id else "?"
    richness = spec_id[2:] if len(spec_id) >= 4 else "?"

    return {
        "run_id":              run_id,
        "spec_id":             spec_id,
        "richness":            richness,
        "context":             context,
        "fr_id":               _extract_fr_id(kpi_record),
        "kpi_id":              kpi_record.get("id"),
        "gqm_id":              kpi_record.get("gqm_id"),
        "pillar_id":           kpi_record.get("pillar_id") or (
                                   gqm_record.get("pillar_id") if gqm_record else None
                               ),
        "metric_name":         gqm_record.get("metric_name") if gqm_record else None,
        "threshold_numeric":   kpi_record.get("threshold_numeric"),
        "threshold_direction": kpi_record.get("threshold_direction"),
        "waf_code_refs":       gqm_record.get("waf_code_refs") if gqm_record else [],
        "d1":                  d1,
        "d3":                  d3,
        "d4":                  d4,
        "kqs_partial":         kqs_partial,
    }


def score_run(
    spec_id: str,
    run_n: int,
    gqm_records: list,
    kpi_records: list,
) -> list:
    """
    Scores all KPI records from a single pipeline run.

    Args:
        spec_id:     experiment spec identifier, e.g. 'A-L1'.
        run_n:       run number (1-10).
        gqm_records: parsed list from gqm_output.json.
        kpi_records: parsed list from kpi_output.json.

    Returns:
        List of scored record dicts (one per kpi_record).

    Edge cases:
        - gqm_records empty → all d3/d4 scores are 0.0
        - kpi_records empty → returns empty list
        - kpi_record references gqm_id not in gqm_records → gqm_record=None
    """
    run_id = f"{spec_id}_run_{run_n:02d}"
    gqm_by_id = {r["id"]: r for r in gqm_records}

    results = []
    for kpi in kpi_records:
        gqm = gqm_by_id.get(kpi.get("gqm_id"))
        results.append(score_pair(kpi, gqm, spec_id, run_id))

    return results


# ── CLI entry point ────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import sys

    if len(sys.argv) < 3:
        print("Usage: python scorer.py <gqm_output.json> <kpi_output.json> [spec_id] [run_n]")
        sys.exit(1)

    gqm_records = json.loads(Path(sys.argv[1]).read_text())
    kpi_records = json.loads(Path(sys.argv[2]).read_text())
    spec_id = sys.argv[3] if len(sys.argv) > 3 else "unknown"
    run_n = int(sys.argv[4]) if len(sys.argv) > 4 else 0

    scores = score_run(spec_id, run_n, gqm_records, kpi_records)
    print(json.dumps(scores, indent=2))

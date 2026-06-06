#!/usr/bin/env python3
"""Transformation helpers for dashboard-ready records."""

from __future__ import annotations

from typing import Any


def score_cards(metrics: dict[str, Any]) -> dict[str, float]:
    return {
        "structural": round(float(metrics.get("structural_score", 0.0)) * 10.0, 1),
        "fr_coverage": round(float(metrics.get("fr_score", 0.0)) * 10.0, 1),
        "invariant": round(float(metrics.get("invariant_score", 0.0)) * 10.0, 1),
        "security": round(float(metrics.get("security_score", 0.0)) * 10.0, 1),
    }


def test_pie(metrics: dict[str, Any]) -> list[dict[str, Any]]:
    total = int(metrics.get("total_test_functions", 0) or 0)
    assertion = int(metrics.get("assertion_tests", 0) or 0)
    mutation = int(metrics.get("mutation_tests", 0) or 0)
    kpi = int(metrics.get("kpi_tests", 0) or 0)
    fr = int(metrics.get("fr_tests", 0) or 0)
    other = max(0, total - (assertion + mutation + kpi + fr))
    return [
        {"label": "Assertion", "value": assertion},
        {"label": "Mutation", "value": mutation},
        {"label": "KPI", "value": kpi},
        {"label": "FR", "value": fr},
        {"label": "Other", "value": other},
    ]


def cost_pie(cost_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {"label": row.get("phase", "Unknown"), "value": float(row.get("cost", 0.0) or 0.0)}
        for row in cost_rows
    ]


def quality_vs_cost(metrics: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "track": "Guided",
            "cost": float(metrics.get("guided_cost", 0.0) or 0.0),
            "score": float(metrics.get("guided_total", 0.0) or 0.0),
            "cost_per_point": float(metrics.get("guided_cost_per_point", 0.0) or 0.0),
        },
        {
            "track": "Baseline",
            "cost": float(metrics.get("baseline_cost", 0.0) or 0.0),
            "score": float(metrics.get("baseline_total", 0.0) or 0.0),
            "cost_per_point": float(metrics.get("baseline_cost_per_point", 0.0) or 0.0),
        },
    ]


def cost_cards(metrics: dict[str, Any]) -> dict[str, float]:
    return {
        "cache_hit_rate": float(metrics.get("cache_hit_rate", 0.0) or 0.0),
        "cache_savings": float(metrics.get("cache_savings", 0.0) or 0.0),
        "guided_cost_per_point": float(metrics.get("guided_cost_per_point", 0.0) or 0.0),
        "baseline_cost_per_point": float(metrics.get("baseline_cost_per_point", 0.0) or 0.0),
        "total_cost": float(metrics.get("total_cost", 0.0) or 0.0),
    }

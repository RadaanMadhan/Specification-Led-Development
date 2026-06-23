"""Smoke tests for KPI classification and extraction."""

from __future__ import annotations

from pathlib import Path
from speceval.kpi_extractor import classify_kpi, extract_all_kpis, KPI

def test_classify_kpi() -> None:
    # Test cases that should be Technical
    assert classify_kpi("Success Rate", "Audit write success rate = 100%", "Checks if writing succeeds") == "Technical"
    assert classify_kpi("Latency", "Response time under 50ms", "") == "Technical"
    assert classify_kpi("Scalability", "Handle 1000 concurrent requests", "") == "Technical"
    assert classify_kpi("Other Category", "Database latency", "") == "Technical"
    assert classify_kpi("Other Category", "Alloy predicate evaluateRisk", "pred executeTransfer") == "Technical"

    # Test cases that should be Business
    assert classify_kpi("Propensity Score", "Alloy predicate evaluateRisk", "pred executeTransfer") == "Business"
    assert classify_kpi("Propensity Score", "Insufficient-fund rejection propensity", "Predictive scoring") == "Business"
    assert classify_kpi("Cost Efficiency", "Reduce infrastructure cost", "") == "Business"
    assert classify_kpi("User Satisfaction", "NPS score >= 50", "") == "Business"
    assert classify_kpi("Compliance", "Audit retention policy", "SOX compliance") == "Business"
    assert classify_kpi("Other", "User churn rate", "Determine if user leaves") == "Business"


def test_kpi_extraction_and_collection() -> None:
    spec_md = """
## Formal Requirements & Advanced KPI Mapping

| KPI Category | Specific Business Metric | Formal Constraint (Alloy Concept) | Measurement & Telemetry Strategy |
| :--- | :--- | :--- | :--- |
| **Success Rate** | Transfer completion rate | `pred executeTransfer` | Log to DB |
| **Propensity Score** | Account risk profile score | `sig Account` | Batch job |
"""
    collection = extract_all_kpis(
        feature_id="test-feature",
        spec_md=spec_md,
        user_prompt="I want a high availability system with low latency and compliance checks.",
        feature_name="Test Feature"
    )

    # Let's check merged KPIs and their types
    kpis = collection.merged_kpis
    # Transfer completion rate (category: Success Rate) -> Technical
    # Account risk profile score (category: Propensity Score) -> Business
    # Availability (from prompt) -> Technical
    # Latency (from prompt) -> Technical
    # Compliance (from prompt) -> Business

    tech_kpis = [k for k in kpis if k.kpi_type == "Technical"]
    bus_kpis = [k for k in kpis if k.kpi_type == "Business"]

    assert len(tech_kpis) >= 3  # Success Rate, Availability, Latency
    assert len(bus_kpis) >= 2   # Propensity Score, Compliance

    d = collection.to_dict()
    assert d["metadata"]["total_technical_kpis"] == len(tech_kpis)
    assert d["metadata"]["total_business_kpis"] == len(bus_kpis)


if __name__ == "__main__":
    test_classify_kpi()
    test_kpi_extraction_and_collection()
    print("OK — KPI classifier tests passed.")

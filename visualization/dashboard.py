#!/usr/bin/env python3
"""Streamlit dashboard for visualization of pipeline runs."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

try:
    from .ingest import DEFAULT_DB_PATH
    from .transform import cost_cards, cost_pie, quality_vs_cost, score_cards, test_pie
except ImportError:  # pragma: no cover - supports direct execution by Streamlit
    from ingest import DEFAULT_DB_PATH
    from transform import cost_cards, cost_pie, quality_vs_cost, score_cards, test_pie


def connect(db_path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(db_path)
    connection.row_factory = sqlite3.Row
    return connection


def list_runs(connection: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = connection.execute(
        "SELECT run_id, timestamp, goal, guided_total, baseline_total, total_cost FROM runs_metrics ORDER BY timestamp DESC"
    ).fetchall()
    return [dict(row) for row in rows]


def load_run(connection: sqlite3.Connection, run_id: str) -> dict[str, Any]:
    row = connection.execute("SELECT * FROM runs_metrics WHERE run_id = ?", (run_id,)).fetchone()
    if row is None:
        raise KeyError(run_id)
    return dict(row)


def load_cost_rows(connection: sqlite3.Connection, run_id: str) -> list[dict[str, Any]]:
    rows = connection.execute(
        "SELECT phase, cost FROM cost_breakdown WHERE run_id = ? ORDER BY phase",
        (run_id,),
    ).fetchall()
    return [dict(row) for row in rows]


def load_raw_data(connection: sqlite3.Connection, run_id: str) -> tuple[dict[str, Any], str]:
    row = connection.execute(
        "SELECT raw_kpis_json, raw_comparison_report_md FROM runs_raw WHERE run_id = ?",
        (run_id,),
    ).fetchone()
    if row is None:
        return {}, ""
    
    kpis = {}
    if row["raw_kpis_json"]:
        try:
            kpis = json.loads(row["raw_kpis_json"])
        except Exception:
            pass
            
    return kpis, row["raw_comparison_report_md"] or ""


def get_kpi_type(kpi: dict[str, Any]) -> str:
    if "kpi_type" in kpi:
        return kpi["kpi_type"]
    # Fallback classification
    category = kpi.get("category", "").lower()
    tech_cats = {"success rate", "error rate", "availability", "latency", "throughput", "security", "performance", "reliability", "scalability", "data quality", "data integrity", "data immutability"}
    if any(tc in category for tc in tech_cats):
        return "Technical"
    return "Business"


def render_status_badge(status: str) -> str:
    status_lower = status.lower()
    if "fulfilled" in status_lower:
        return '<span style="color:#1b5e20;background-color:#e8f5e9;padding:3px 10px;border-radius:12px;font-size:0.85em;font-weight:bold;margin-right:8px;border:1px solid #c8e6c9;">🟢 Fulfilled</span>'
    elif "measure" in status_lower:
        return '<span style="color:#e65100;background-color:#fff3e0;padding:3px 10px;border-radius:12px;font-size:0.85em;font-weight:bold;margin-right:8px;border:1px solid #ffe0b2;">🟡 To be measured</span>'
    else:
        return '<span style="color:#b71c1c;background-color:#ffebee;padding:3px 10px;border-radius:12px;font-size:0.85em;font-weight:bold;margin-right:8px;border:1px solid #ffcdd2;">🔴 Missing</span>'


def render_app() -> None:
    import altair as alt
    import streamlit as st

    connection = connect(DEFAULT_DB_PATH)
    try:
        st.set_page_config(page_title="Spec-Led Dev Dashboard", layout="wide")
        
        # Premium Custom CSS
        st.markdown(
            """
            <style>
            .kpi-card {
                background-color: rgba(128, 128, 128, 0.05);
                padding: 18px;
                border-radius: 8px;
                border: 1px solid rgba(128, 128, 128, 0.15);
                margin-bottom: 12px;
            }
            .kpi-title {
                font-weight: 600;
                font-size: 1.1rem;
                margin-bottom: 6px;
            }
            .kpi-meta {
                font-size: 0.9rem;
                color: gray;
                margin-bottom: 10px;
            }
            .kpi-detail {
                font-size: 0.95rem;
                margin-top: 5px;
            }
            </style>
            """,
            unsafe_allow_html=True,
        )

        st.title("Specification-Led Development Dashboard")

        runs = list_runs(connection)
        if not runs:
            st.warning("No ingested runs found. Run `python -m pipeline.visualization.visualize` first.")
            return

        run_map = {f"{row['run_id']} | {row.get('goal', '')}": row["run_id"] for row in runs}
        selected = st.sidebar.selectbox("Select Pipeline Run", list(run_map.keys()))
        run_id = run_map[selected]
        
        metrics = load_run(connection, run_id)
        kpis_data, comparison_report = load_raw_data(connection, run_id)
        all_kpis = kpis_data.get("kpis", [])
        
        st.caption(f"Run ID: **{metrics['run_id']}** • Description: **{metrics.get('goal', '')}**")
        st.markdown("---")

        # Create tabs
        tab_business, tab_technical = st.tabs(["📊 Business Overview", "🛠️ Technical Details"])

        with tab_business:
            # 1. Verdict Banner
            verdict = metrics.get("verdict", "UNKNOWN")
            if verdict == "GUIDED_WINS":
                st.success("🏆 **Verdict: GUIDED WINS** — Verification-guided code generation produced significantly higher quality software.")
            elif verdict == "BASELINE_WINS":
                st.warning("🏆 **Verdict: BASELINE WINS** — Description-only track achieved a better outcome.")
            else:
                st.info("🏆 **Verdict: TIE** — Both tracks achieved comparable performance.")

            # 2. Key Business Metrics
            st.write("")
            col_kpis, col_costs = st.columns([3, 2])

            with col_kpis:
                st.subheader("🎯 Business KPI Fulfillment")
                
                # Separate Business KPIs
                all_kpis = kpis_data.get("kpis", [])
                business_kpis = [k for k in all_kpis if get_kpi_type(k) == "Business"]
                
                if business_kpis:
                    total_bus = len(business_kpis)
                    fulfilled_bus = sum(1 for k in business_kpis if k.get("status") == "Fulfilled")
                    measured_bus = sum(1 for k in business_kpis if k.get("status") == "To be measured")
                    missing_bus = sum(1 for k in business_kpis if k.get("status") == "Missing")

                    col_b1, col_b2, col_b3, col_b4 = st.columns(4)
                    col_b1.metric("Total Business KPIs", total_bus)
                    col_b2.metric("🟢 Fulfilled", fulfilled_bus)
                    col_b2.caption("Addressed in Spec")
                    col_b3.metric("🟡 To be measured", measured_bus)
                    col_b3.caption("Needs runtime metric")
                    col_b4.metric("🔴 Missing", missing_bus)
                    col_b4.caption("Not addressed")

                    st.write("")
                    st.write("**Filter Business KPIs by Status:**")
                    bus_status_filter = st.radio(
                        "Show status:",
                        ["All", "Fulfilled", "To be measured", "Missing"],
                        key="business_kpi_status_filter",
                        horizontal=True
                    )

                    # Apply filter
                    filtered_business_kpis = business_kpis
                    if bus_status_filter != "All":
                        filtered_business_kpis = [k for k in business_kpis if k.get("status") == bus_status_filter]

                    st.write(f"Showing {len(filtered_business_kpis)} of {total_bus} Business KPIs:")
                    for k in filtered_business_kpis:
                        status_html = render_status_badge(k.get("status", "Missing"))
                        with st.container():
                            st.markdown(
                                f"""
                                <div class="kpi-card">
                                    <div class="kpi-title">{status_html} {k.get('name', 'Unnamed KPI')}</div>
                                    <div class="kpi-meta">Category: <b>{k.get('category', 'General')}</b> | Source: <i>{k.get('source', 'unknown')} ({k.get('source_location', 'N/A')})</i></div>
                                    <div class="kpi-detail">📝 <b>Description:</b> {k.get('description', 'No description')}</div>
                                    <div class="kpi-detail">⏱️ <b>Measurement Strategy:</b> {k.get('measurement_strategy', 'N/A')}</div>
                                    {f'<div class="kpi-detail">⛓️ <b>Formal Constraint:</b> <code>{k.get("formal_constraint")}</code></div>' if k.get("formal_constraint") else ''}
                                </div>
                                """,
                                unsafe_allow_html=True
                            )
                else:
                    st.info("No business KPIs extracted for this run.")


            with col_costs:
                st.subheader("💰 Execution Costs")
                cost_summary = cost_cards(metrics)
                
                col_c1, col_c2 = st.columns(2)
                col_c1.metric("Total Execution Cost", f"${cost_summary['total_cost']:.2f}")
                col_c2.metric("Cache Savings", f"${cost_summary['cache_savings']:.2f}", delta=f"{cost_summary['cache_hit_rate']:.1f}% hit rate")

                col_c3, col_c4 = st.columns(2)
                col_c3.metric("Guided Track Cost", f"${metrics.get('guided_cost', 0.0):.2f}")
                col_c4.metric("Baseline Track Cost", f"${metrics.get('baseline_cost', 0.0):.2f}")

                st.write("")
                st.write("**Cost Allocation by Phase**")
                cost_rows = load_cost_rows(connection, run_id)
                if cost_rows:
                    cost_chart = (
                        alt.Chart(alt.Data(values=cost_pie(cost_rows)))
                        .mark_arc(innerRadius=50)
                        .encode(theta="value:Q", color="label:N", tooltip=["label:N", "value:Q"])
                    )
                    st.altair_chart(cost_chart, width='stretch')
                else:
                    st.info("No cost breakdown rows found.")

                st.write("")
                st.write("**Cost Efficiency Comparison**")
                st.table(quality_vs_cost(metrics))

            # 3. LLM Comparison Report
            if comparison_report:
                st.markdown("---")
                st.subheader("📄 Qualitative Comparison Report")
                with st.expander("Show detailed report from the LLM Judge", expanded=True):
                    st.markdown(comparison_report)

        with tab_technical:
            # 1. Verification Quality Scores
            st.subheader("⚙️ Verification Quality Scores (Guided Track)")
            score = score_cards(metrics)
            
            col_t1, col_t2, col_t3, col_t4, col_t5 = st.columns(5)
            score_value = score['structural']
            metric = metrics.get('patterns_expected', 0)
            col_t1.metric("Structural Completeness", f"{int(score_value/100*metric)}/{metric}")
            col_t1.caption(f"{score_value} % of patterns checked")

            score_value = score['fr_coverage']
            metric = metrics.get('frs_expected', 0)
            col_t2.metric("FR Coverage", f"{int(score_value/100*metric)}/{metric}")
            col_t2.caption(f"{score_value} % of functional reqs")

            score_value = score['invariant']
            metric = metrics.get('facts_expected', 0)
            col_t3.metric("Invariant Enforcement", f"{int(score_value/100*metric)}/{metric}")
            col_t3.caption(f"{score_value} % of Alloy invariants")

            score_value = score['security']
            col_t4.metric("Security Posture", f"{score_value} %")
            col_t4.caption("checklist of security controls")

            score_value = score.get('kpi', 0.0)
            col_t5.metric("KPI Instrumentation", f"{score_value} %")
            col_t5.caption("of KPIs instrumented")

            # 2. Test Composition and KPI constants
            st.write("")
            col_test_comp, col_tech_kpis = st.columns([1, 1])

            with col_test_comp:
                st.subheader("🧪 Test Suite Composition")
                st.metric("Total Test Functions Generated", int(metrics.get("total_test_functions", 0) or 0))
                test_chart = (
                    alt.Chart(alt.Data(values=test_pie(metrics)))
                    .mark_arc(innerRadius=50)
                    .encode(theta="value:Q", color="label:N", tooltip=["label:N", "value:Q"])
                )
                st.altair_chart(test_chart, width='stretch')

            with col_tech_kpis:
                st.subheader("🛠️ KPI Alignment & Verification")
                
                if all_kpis:
                    st.write("**Filter KPIs by Category:**")
                    category_filter = st.radio(
                        "Show category:",
                        ["All", "Technical", "Business"],
                        key="tech_kpi_category_filter",
                        horizontal=True
                    )

                    # Filter by Category
                    if category_filter == "Technical":
                        cat_kpis = [k for k in all_kpis if get_kpi_type(k) == "Technical"]
                    elif category_filter == "Business":
                        cat_kpis = [k for k in all_kpis if get_kpi_type(k) == "Business"]
                    else:
                        cat_kpis = all_kpis

                    if cat_kpis:
                        total_kpis = len(cat_kpis)
                        fulfilled_kpis = sum(1 for k in cat_kpis if k.get("status") == "Fulfilled")
                        measured_kpis = sum(1 for k in cat_kpis if k.get("status") == "To be measured")
                        missing_kpis = sum(1 for k in cat_kpis if k.get("status") == "Missing")

                        # We customize the metric labels based on the chosen category
                        cat_suffix = f" {category_filter}" if category_filter != "All" else ""
                        col_tk1, col_tk2, col_tk3 = st.columns(3)
                        col_tk1.metric(f"🟢 Fulfilled{cat_suffix} KPIs", fulfilled_kpis)
                        col_tk2.metric("🟡 To be measured", measured_kpis)
                        col_tk3.metric("🔴 Missing", missing_kpis)

                        st.write("")
                        st.write(f"**Filter {category_filter} KPIs by Status:**")
                        status_filter = st.radio(
                            "Show status:",
                            ["All", "Fulfilled", "To be measured", "Missing"],
                            key="tech_kpi_status_filter",
                            horizontal=True
                        )

                        # Apply status filter
                        filtered_kpis = cat_kpis
                        if status_filter != "All":
                            filtered_kpis = [k for k in cat_kpis if k.get("status") == status_filter]

                        st.write(f"Showing {len(filtered_kpis)} of {total_kpis} {category_filter} KPIs:")
                        
                        for k in filtered_kpis:
                            kpi_type = get_kpi_type(k)
                            status_html = render_status_badge(k.get("status", "Missing"))
                            
                            # Gather metadata dynamically
                            meta_parts = [f"Category: <b>{k.get('category', 'General')}</b>", f"Type: <b>{kpi_type}</b>"]
                            
                            if kpi_type == "Technical" and k.get('matched_constraint'):
                                meta_parts.append(f"Matched Alloy Predicate: <code>{k.get('matched_constraint')}</code>")
                            
                            if kpi_type == "Business":
                                source_info = f"Source: <i>{k.get('source', 'unknown')} ({k.get('source_location', 'N/A')})</i>"
                                meta_parts.append(source_info)
                                
                            meta_str = " | ".join(meta_parts)
                            
                            with st.container():
                                st.markdown(
                                    f"""
                                    <div class="kpi-card">
                                        <div class="kpi-title">{status_html} {k.get('name', 'Unnamed KPI')}</div>
                                        <div class="kpi-meta">{meta_str}</div>
                                        <div class="kpi-detail">📝 <b>Description:</b> {k.get('description', 'No description')}</div>
                                        <div class="kpi-detail">⏱️ <b>Measurement:</b> {k.get('measurement_strategy', 'N/A')}</div>
                                        {f'<div class="kpi-detail">⛓️ <b>Formal Constraint:</b> <code>{k.get("formal_constraint")}</code></div>' if k.get("formal_constraint") else ''}
                                    </div>
                                    """,
                                    unsafe_allow_html=True
                                )
                    else:
                        st.info(f"No {category_filter.lower()} KPIs extracted for this run.")
                else:
                    st.info("No KPIs extracted for this run.")

            st.markdown("---")
            st.subheader("📜 Run History")
            st.dataframe(runs, width='stretch')

    finally:
        connection.close()


def main() -> None:
    render_app()


if __name__ == "__main__":
    main()

"""speceval.kpi_dashboard — Streamlit dashboard for KPI review and generation control."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

import streamlit as st

from speceval.kpi_extractor import extract_all_kpis, save_kpis_json, classify_kpi
from speceval.speckit_generator import generate_speckit, GeneratorConfig
from speceval.providers.anthropic import AnthropicProvider


def _project_root() -> Path:
    """The speceval package root (src/speceval/)."""
    return Path(__file__).resolve().parent.parent


def _default_gen_cache_dir() -> Path:
    p = _project_root() / "cache" / "speckit_gen"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _default_specs_dir() -> Path:
    return _project_root().parent.parent / "specs"


def status_to_color(status: str) -> str:
    """Map KPI status to Streamlit color name."""
    return {
        "Fulfilled": "green",
        "To be measured": "orange",
        "Missing": "red",
    }.get(status, "gray")


def status_to_emoji(status: str) -> str:
    """Map KPI status to emoji."""
    return {
        "Fulfilled": "✓",
        "To be measured": "○",
        "Missing": "✗",
    }.get(status, "?")


def load_kpis_from_file(kpi_json_path: Path) -> dict:
    """Load KPI collection from JSON file."""
    if not kpi_json_path.exists():
        return None
    return json.loads(kpi_json_path.read_text(encoding="utf-8"))


def run_dashboard(
    feature_id: str,
    feature_dir: Path,
    kpi_json_path: Path,
    original_prompt: str = "",
    echo_fn=None,
) -> dict:
    """Run the KPI review dashboard.
    
    Returns:
        dict with keys:
        - 'action': 'continue' or 'regenerate'
        - 'new_prompt': (if regenerate) the new user prompt
    """
    st.set_page_config(
        page_title="KPI Review Dashboard",
        page_icon="📊",
        layout="wide",
        initial_sidebar_state="collapsed",
    )

    # Load KPI data
    kpi_data = load_kpis_from_file(kpi_json_path)
    if kpi_data is None:
        st.error(f"KPI file not found: {kpi_json_path}")
        st.stop()

    kpis = kpi_data.get("kpis", [])
    metadata = kpi_data.get("metadata", {})
    feature_name = kpi_data.get("feature_name", feature_id)

    # Header
    st.title("📊 KPI Review Dashboard")
    st.markdown(f"**Feature:** {feature_name}")
    st.markdown(f"**Feature ID:** `{feature_id}`")
    st.markdown("---")

    # Calculate counts dynamically
    technical_kpis = []
    business_kpis = []
    for k in kpis:
        k_type = k.get("kpi_type")
        if k_type == "Technical":
            technical_kpis.append(k)
        else:
            business_kpis.append(k)

    # Summary metrics
    col1, col2, col3 = st.columns(3)
    with col1:
        st.metric("Total KPIs", len(kpis))
    with col2:
        st.metric("🔧 Technical KPIs", len(technical_kpis))
    with col3:
        st.metric("💼 Business KPIs", len(business_kpis))

    col1, col2, col3 = st.columns(3)
    with col1:
        fulfilled = sum(1 for k in kpis if k.get("status") == "Fulfilled")
        st.metric("✓ Fulfilled", fulfilled, delta_color="off")
    with col2:
        to_measure = sum(1 for k in kpis if k.get("status") == "To be measured")
        st.metric("○ To be measured", to_measure, delta_color="off")
    with col3:
        missing = sum(1 for k in kpis if k.get("status") == "Missing")
        st.metric("✗ Missing", missing, delta_color="off")

    st.markdown("---")

    # KPI Table grouped by status
    st.subheader("KPI Details")

    col_filter_1, col_filter_2 = st.columns([1, 2])
    with col_filter_1:
        type_filter = st.selectbox(
            "Filter by KPI Type",
            options=["All Types", "Technical KPIs", "Business KPIs"],
            index=0
        )

    # Filter the kpis to display
    display_kpis = kpis
    if type_filter == "Technical KPIs":
        display_kpis = technical_kpis
    elif type_filter == "Business KPIs":
        display_kpis = business_kpis

    status_order = ["Fulfilled", "To be measured", "Missing"]
    for status in status_order:
        status_kpis = [k for k in display_kpis if k.get("status") == status]
        if not status_kpis:
            continue

        # Collapsible section for each status
        with st.expander(
            f"{status_to_emoji(status)} {status} ({len(status_kpis)})",
            expanded=(status == "Fulfilled"),
        ):
            for kpi in status_kpis:
                col1, col2 = st.columns([3, 1])
                with col1:
                    st.write(f"**{kpi.get('name', 'N/A')}**")
                    kpi_type = kpi.get("kpi_type", "Business")
                    type_color = "blue" if kpi_type == "Technical" else "green"
                    st.caption(f"Category: {kpi.get('category', 'N/A')} | Type: :{type_color}[{kpi_type}]")
                    if kpi.get("description"):
                        st.caption(
                            f"Description: {kpi.get('description')[:100]}..."
                        )
                    if kpi.get("matched_constraint"):
                        st.caption(
                            f"Alloy Match: `{kpi.get('matched_constraint')}`"
                        )
                    if kpi.get("measurement_strategy"):
                        st.caption(
                            f"Measurement: {kpi.get('measurement_strategy')[:80]}"
                        )
                with col2:
                    color = status_to_color(status)
                    st.write(f":{color}[{status}]")
                st.divider()

    st.markdown("---")

    # Action buttons
    st.subheader("Next Steps")
    col1, col2, col3 = st.columns(3)

    with col1:
        if st.button(
            "🔄 Regenerate with Modified Prompt",
            use_container_width=True,
            key="regenerate_btn",
        ):
            st.session_state.show_regenerate_modal = True

    with col2:
        if st.button(
            "✓ Continue / Close",
            use_container_width=True,
            key="continue_btn",
        ):
            st.session_state.action = "continue"
            st.info("✓ Closing dashboard. Generation phase complete!")
            st.stop()

    with col3:
        if st.button(
            "📋 Export KPIs as JSON",
            use_container_width=True,
            key="export_btn",
        ):
            st.download_button(
                label="Download kpis.json",
                data=json.dumps(kpi_data, indent=2),
                file_name=f"{feature_id}_kpis.json",
                mime="application/json",
            )

    # Regenerate modal
    if st.session_state.get("show_regenerate_modal"):
        st.markdown("---")
        st.subheader("🔄 Regenerate SpecKit with Modified Prompt")
        st.info(
            "You can modify your prompt to improve KPI extraction. "
            "This will re-run the SpecKit generation phase."
        )

        modified_prompt = st.text_area(
            "Enter your modified feature description:",
            value=original_prompt,
            height=200,
            key="prompt_input",
        )

        col1, col2 = st.columns(2)
        with col1:
            if st.button(
                "🚀 Regenerate",
                use_container_width=True,
                key="confirm_regenerate",
            ):
                if modified_prompt.strip():
                    # Write the modified prompt to a file for the CLI to pick up
                    feature_dir_path = Path(feature_dir)
                    (feature_dir_path / ".modified_prompt.txt").write_text(
                        modified_prompt, encoding="utf-8"
                    )
                    (feature_dir_path / ".regenerate_request").touch()
                    st.success("✓ Regeneration requested. Restarting...")
                    st.stop()
                else:
                    st.error("Please enter a prompt.")

        with col2:
            if st.button(
                "Cancel",
                use_container_width=True,
                key="cancel_regenerate",
            ):
                st.session_state.show_regenerate_modal = False
                st.rerun()


def run_kpi_dashboard(
    feature_id: str,
    feature_dir: Path,
    kpi_json_path: Path,
    original_prompt: str = "",
) -> None:
    """Entry point for KPI dashboard review.
    
    Handles regeneration via file-based communication with CLI.
    """
    # Initialize session state
    if "action" not in st.session_state:
        st.session_state.action = None
    if "show_regenerate_modal" not in st.session_state:
        st.session_state.show_regenerate_modal = False

    # Show the dashboard
    run_dashboard(
        feature_id=feature_id,
        feature_dir=feature_dir,
        kpi_json_path=kpi_json_path,
        original_prompt=original_prompt,
    )


def regenerate_with_dashboard(
    initial_prompt: str,
    feature_id: str,
    specs_dir: Path,
    cache_dir: Path,
    provider: AnthropicProvider,
    alloy_code: str = "",
    echo_fn=None,
) -> tuple[str, dict, Path]:
    """Regenerate SpecKit with dashboard review loop.
    
    Runs generation, shows dashboard for KPI review, and allows regeneration
    until user is satisfied or presses continue.
    
    Returns:
        (final_prompt, result, kpi_json_path)
    """
    if echo_fn is None:
        def echo_fn(_msg):
            pass

    current_prompt = initial_prompt
    feature_dir = None
    result = None
    kpi_json_path = None

    while True:
        echo_fn(f"[gen]     generating SpecKit for {feature_id}...")

        # Generate SpecKit artefacts
        result = generate_speckit(
            description=current_prompt,
            config=GeneratorConfig(
                feature_id=feature_id,
                project_type="web-api",
                target_fr_count=10,
            ),
            provider=provider,
            output_base=specs_dir,
            cache_dir=cache_dir,
            use_cache=False,  # Don't use cache during interactive mode
        )

        feature_dir = result.feature_dir

        # Extract KPIs with Alloy matching
        echo_fn("[kpi]     extracting KPIs...")
        kpi_collection = extract_all_kpis(
            feature_id=result.feature_id,
            spec_md=result.spec_md,
            user_prompt=current_prompt,
            feature_name=result.feature_id.replace("-", " ").title(),
            alloy_code=alloy_code or "",
        )

        # Save KPIs
        kpi_json_path = feature_dir / "kpis.json"
        save_kpis_json(kpi_collection, kpi_json_path)

        echo_fn(
            f"[kpi]     extracted {len(kpi_collection.merged_kpis)} KPIs → "
            f"{kpi_json_path}"
        )

        # Show dashboard
        echo_fn("[dashboard] launching KPI review dashboard...")
        action_result = run_kpi_dashboard(
            feature_id=result.feature_id,
            feature_dir=feature_dir,
            kpi_json_path=kpi_json_path,
            original_prompt=current_prompt,
        )

        if action_result is None:
            # User closed without clicking a button
            return current_prompt, result, kpi_json_path

        if action_result["action"] == "continue":
            # User is satisfied
            echo_fn("[dashboard] user confirmed. Proceeding.")
            return current_prompt, result, kpi_json_path

        elif action_result["action"] == "regenerate":
            # User wants to regenerate with modified prompt
            current_prompt = action_result["new_prompt"]
            echo_fn(
                f"[dashboard] user requested regeneration with modified prompt"
            )
            # Loop back to regenerate with new prompt


if __name__ == "__main__":
    # Simple test mode
    import sys

    if len(sys.argv) < 2:
        print("Usage: streamlit run kpi_dashboard.py -- <kpi_json_path>")
        sys.exit(1)

    kpi_json_path = Path(sys.argv[1])
    feature_id = kpi_json_path.parent.name

    run_kpi_dashboard(
        feature_id=feature_id,
        feature_dir=kpi_json_path.parent,
        kpi_json_path=kpi_json_path,
        original_prompt="",
    )

"""Standalone Streamlit app for KPI dashboard review."""

import os
from pathlib import Path
import streamlit as st
import sys

# Get config from environment variables set by CLI
feature_dir = os.getenv("SPECEVAL_FEATURE_DIR")
feature_id = os.getenv("SPECEVAL_FEATURE_ID")
kpi_json_path = os.getenv("SPECEVAL_KPI_JSON")
original_prompt = os.getenv("SPECEVAL_ORIGINAL_PROMPT", "")

if not feature_dir or not kpi_json_path:
    st.error(
        "Dashboard configuration not found.\n\n"
        "Please launch via CLI: `speceval dashboard <feature_dir>`"
    )
    st.stop()

feature_dir = Path(feature_dir)
kpi_json_path = Path(kpi_json_path)
feature_id = feature_id or feature_dir.name

# Add speceval to path
speceval_root = Path(__file__).parent.parent
if str(speceval_root) not in sys.path:
    sys.path.insert(0, str(speceval_root))

from speceval.kpi_dashboard import run_kpi_dashboard

run_kpi_dashboard(
    feature_id=feature_id,
    feature_dir=feature_dir,
    kpi_json_path=kpi_json_path,
    original_prompt=original_prompt,
)

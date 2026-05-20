"""
db/scripts/seed.py
------------------
Creates all three Azure AI Search indexes and bulk-uploads the waf-index seed data.
Run once on first deploy, or after a full index teardown.

Usage:
    python db/scripts/seed.py

Required env vars:
    AZURE_SEARCH_ENDPOINT   e.g. https://your-resource.search.windows.net
    AZURE_SEARCH_ADMIN_KEY  Admin key from Azure portal
"""

import os
import json
import time
from pathlib import Path

import requests

# Config
ENDPOINT  = os.environ["AZURE_SEARCH_ENDPOINT"].rstrip("/")
ADMIN_KEY = os.environ["AZURE_SEARCH_ADMIN_KEY"]
API_VER   = "2024-05-01-preview"

HEADERS = {
    "Content-Type": "application/json",
    "api-key": ADMIN_KEY,
}

BASE_DIR    = Path(__file__).resolve().parent.parent
SCHEMA_DIR  = BASE_DIR / "schema"
SEED_FILE   = BASE_DIR / "waf_index_seed.json"


def create_index(schema_file: Path) -> None:
    schema = json.loads(schema_file.read_text())
    name   = schema["name"]
    url    = f"{ENDPOINT}/indexes/{name}?api-version={API_VER}"

    # Delete if exists, then recreate
    del_resp = requests.delete(url, headers=HEADERS)
    if del_resp.status_code not in (200, 204, 404):
        print(f"  Warning: DELETE {name} returned {del_resp.status_code}")

    resp = requests.put(url, headers=HEADERS, json=schema)
    if resp.status_code in (200, 201):
        print(f"  [ok] {name} created")
    else:
        print(f"  [error] {name}: {resp.status_code} — {resp.text[:200]}")
        raise SystemExit(1)


def upload_seed_documents() -> None:
    seed = json.loads(SEED_FILE.read_text())
    docs = seed["value"]

    # Wrap in Azure Search batch upload format
    batch = {
        "value": [
            {"@search.action": "mergeOrUpload", **doc}
            for doc in docs
        ]
    }

    url = f"{ENDPOINT}/indexes/waf-index/docs/index?api-version={API_VER}"
    resp = requests.post(url, headers=HEADERS, json=batch)

    if resp.status_code in (200, 201, 207):
        result = resp.json()
        succeeded = sum(1 for r in result.get("value", []) if r.get("status"))
        failed    = len(result.get("value", [])) - succeeded
        print(f"  [ok] {succeeded} records uploaded, {failed} failed")
        if failed:
            for r in result.get("value", []):
                if not r.get("status"):
                    print(f"       Failed: {r.get('key')} — {r.get('errorMessage')}")
    else:
        print(f"  [error] Upload failed: {resp.status_code} — {resp.text[:400]}")
        raise SystemExit(1)


def main() -> None:
    print("\n=== KPI-Spec: Azure AI Search index setup ===\n")

    print("1. Creating indexes...")
    for schema_file in sorted(SCHEMA_DIR.glob("*.json")):
        print(f"   {schema_file.name}")
        create_index(schema_file)

    print("\n2. Uploading waf-index seed data (without embeddings)...")
    print("   NOTE: Run embed.py afterwards to generate and upload embeddings.")
    upload_seed_documents()

    print("\n=== Done. Run embed.py to generate embeddings for waf-index. ===\n")


if __name__ == "__main__":
    main()

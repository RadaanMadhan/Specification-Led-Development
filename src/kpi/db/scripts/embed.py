"""
db/scripts/embed.py
-------------------
Generates embeddings for all waf-index records using Azure OpenAI
and updates the records in Azure AI Search.

Run after seed.py. Safe to re-run — uses mergeOrUpload.

Usage:
    python db/scripts/embed.py

Required env vars:
    AZURE_SEARCH_ENDPOINT       e.g. https://your-resource.search.windows.net
    AZURE_SEARCH_ADMIN_KEY      Admin key from Azure portal
    AZURE_OPENAI_ENDPOINT       e.g. https://your-resource.openai.azure.com
    AZURE_OPENAI_API_KEY        Azure OpenAI key
    AZURE_OPENAI_EMBED_DEPLOY   Deployment name for text-embedding-3-small
"""

import os
import json
import time
from pathlib import Path

import requests

# Config
SEARCH_ENDPOINT  = os.environ["AZURE_SEARCH_ENDPOINT"].rstrip("/")
SEARCH_KEY       = os.environ["AZURE_SEARCH_ADMIN_KEY"]
OPENAI_ENDPOINT  = os.environ["AZURE_OPENAI_ENDPOINT"].rstrip("/")
OPENAI_KEY       = os.environ["AZURE_OPENAI_API_KEY"]
EMBED_DEPLOYMENT = os.environ.get("AZURE_OPENAI_EMBED_DEPLOY", "text-embedding-3-small")
EMBED_DIMS       = 1536
OPENAI_API_VER   = "2024-02-01"
SEARCH_API_VER   = "2024-05-01-preview"

SEARCH_HEADERS = {"Content-Type": "application/json", "api-key": SEARCH_KEY}
OPENAI_HEADERS = {"Content-Type": "application/json", "api-key": OPENAI_KEY}

BASE_DIR  = Path(__file__).resolve().parent.parent
SEED_FILE = BASE_DIR / "waf_index_seed.json"


def get_embedding(text: str) -> list[float]:
    """Call Azure OpenAI to embed a text string."""
    url = (
        f"{OPENAI_ENDPOINT}/openai/deployments/{EMBED_DEPLOYMENT}"
        f"/embeddings?api-version={OPENAI_API_VER}"
    )
    resp = requests.post(
        url,
        headers=OPENAI_HEADERS,
        json={"input": text, "dimensions": EMBED_DIMS},
    )
    resp.raise_for_status()
    return resp.json()["data"][0]["embedding"]


def build_embed_text(record: dict) -> str:
    """
    Concatenate the fields we want to embed for waf-index.
    recommendation + risk_summary gives the LLM the best surface
    to match spec requirements against WAF principles.
    """
    parts = [
        record.get("recommendation", ""),
        record.get("risk_summary", ""),
    ]
    return " ".join(p for p in parts if p).strip()


def upload_with_embeddings(records_with_embeddings: list[dict]) -> None:
    batch = {
        "value": [
            {"@search.action": "mergeOrUpload", **rec}
            for rec in records_with_embeddings
        ]
    }
    url = f"{SEARCH_ENDPOINT}/indexes/waf-index/docs/index?api-version={SEARCH_API_VER}"
    resp = requests.post(url, headers=SEARCH_HEADERS, json=batch)

    if resp.status_code in (200, 201, 207):
        result = resp.json()
        ok   = sum(1 for r in result.get("value", []) if r.get("status"))
        fail = len(result.get("value", [])) - ok
        print(f"  [ok] {ok} records updated, {fail} failed")
    else:
        print(f"  [error] {resp.status_code} — {resp.text[:400]}")
        raise SystemExit(1)


def main() -> None:
    print("\n=== KPI-Spec: Generating waf-index embeddings ===\n")

    seed    = json.loads(SEED_FILE.read_text())
    records = seed["value"]
    total   = len(records)

    enriched = []
    for i, rec in enumerate(records, 1):
        waf_id    = rec["id"]
        embed_txt = build_embed_text(rec)
        print(f"  [{i:02d}/{total}] {waf_id} — embedding {len(embed_txt)} chars... ", end="", flush=True)

        try:
            vec = get_embedding(embed_txt)
            enriched.append({**rec, "embedding": vec})
            print("done")
        except Exception as exc:
            print(f"FAILED: {exc}")
            raise SystemExit(1)

        # Rate-limit courtesy pause — text-embedding-3-small is generous
        # but stay safe with concurrent batches.
        if i % 10 == 0:
            time.sleep(0.5)

    print(f"\n  All {total} embeddings generated. Uploading...")
    upload_with_embeddings(enriched)

    print("\n=== waf-index embeddings complete. ===\n")


if __name__ == "__main__":
    main()

"""
db/scripts/test_local.py
------------------------
Tests without any Azure credentials.

1. Validates seed file structure
2. Validates all three schema files
3. Simulates what seed.py would send to Azure (dry run)
4. Runs a mock semantic search using cosine similarity in pure Python
   so you can see how the vector search will actually behave

Usage:
    python db/scripts/test_local.py

No env vars needed. No Azure account needed.
"""

import json
import math
import os
from pathlib import Path

BASE_DIR   = Path(__file__).resolve().parent.parent
SEED_FILE  = BASE_DIR / "waf_index_seed.json"
SCHEMA_DIR = BASE_DIR / "schema"

# ── Colours for terminal output ────────────────────────────────────────────
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
BLUE   = "\033[94m"
PURPLE = "\033[95m"
RESET  = "\033[0m"
BOLD   = "\033[1m"

def ok(msg):   print(f"  {GREEN}✓{RESET}  {msg}")
def fail(msg): print(f"  {RED}✗{RESET}  {msg}")
def info(msg): print(f"  {BLUE}→{RESET}  {msg}")
def warn(msg): print(f"  {YELLOW}!{RESET}  {msg}")
def header(msg): print(f"\n{BOLD}{PURPLE}{msg}{RESET}")
def subheader(msg): print(f"\n{BOLD}{msg}{RESET}")


# ══════════════════════════════════════════════════════════════════════════════
# TEST 1 — Seed file validation
# ══════════════════════════════════════════════════════════════════════════════
def test_seed_file():
    header("TEST 1 — Seed file (waf_index_seed.json)")

    if not SEED_FILE.exists():
        fail(f"File not found: {SEED_FILE}")
        return []

    with open(SEED_FILE) as f:
        seed = json.load(f)

    records = seed.get("value", [])
    ok(f"JSON parses cleanly — {len(records)} records found")

    # Count by pillar
    by_pillar = {}
    for r in records:
        p = r.get("pillar_id", "UNKNOWN")
        by_pillar.setdefault(p, []).append(r["id"])

    subheader("  Records per pillar:")
    expected = {"reliability": 10, "security": 12, "cost": 14, "operations": 11, "performance": 12}
    for pillar, exp_count in expected.items():
        actual = len(by_pillar.get(pillar, []))
        if actual == exp_count:
            ok(f"{pillar:<22} {actual} records  ({by_pillar[pillar][0]} → {by_pillar[pillar][-1]})")
        else:
            fail(f"{pillar:<22} expected {exp_count}, got {actual}")

    # Required fields
    required = ["id","pillar_id","recommendation","metric_patterns",
                "typical_thresholds","risk_summary","tradeoff_pillar_ids","source_url"]
    subheader("  Required fields:")
    all_ok = True
    for r in records:
        for field in required:
            if field not in r:
                fail(f"{r['id']}: missing '{field}'")
                all_ok = False
    if all_ok:
        ok("All required fields present on all 59 records")

    # metric_patterns is always a non-empty list
    bad = [r["id"] for r in records if not isinstance(r.get("metric_patterns"), list) or len(r["metric_patterns"]) == 0]
    ok("metric_patterns are non-empty lists") if not bad else fail(f"Bad metric_patterns: {bad}")

    # tradeoff_pillar_ids only contains valid pillar names
    valid_pillars = {"reliability","security","cost","operations","performance"}
    bad_t = [f"{r['id']}: '{t}'" for r in records for t in r.get("tradeoff_pillar_ids",[]) if t not in valid_pillars]
    ok("tradeoff_pillar_ids contain only valid pillar names") if not bad_t else [fail(b) for b in bad_t]

    # No embeddings pre-baked in
    has_emb = [r["id"] for r in records if "embedding" in r]
    ok("No embeddings in seed file (correct — embed.py generates these)") if not has_emb else fail(f"Embeddings found: {has_emb[:3]}")

    return records


# ══════════════════════════════════════════════════════════════════════════════
# TEST 2 — Schema file validation
# ══════════════════════════════════════════════════════════════════════════════
def test_schemas():
    header("TEST 2 — Schema files (db/schema/)")

    checks = {
        "waf_index.json":  {"field_count": 9,  "needs_vector": True,  "needs_semantic": True,  "key_field": "id"},
        "gqm_index.json":  {"field_count": 11, "needs_vector": True,  "needs_semantic": True,  "key_field": "id"},
        "kpi_index.json":  {"field_count": 12, "needs_vector": False, "needs_semantic": False, "key_field": "id"},
    }

    for fname, rules in checks.items():
        path = SCHEMA_DIR / fname
        if not path.exists():
            fail(f"{fname}: FILE NOT FOUND at {path}")
            continue

        s = json.load(open(path))
        fields = s.get("fields", [])

        subheader(f"  {fname}")
        ok(f"JSON valid") 
        ok(f"{len(fields)} fields") if len(fields) == rules["field_count"] else fail(f"{len(fields)} fields (expected {rules['field_count']})")

        key_fields = [f["name"] for f in fields if f.get("key")]
        ok(f"Key field: '{key_fields[0]}'") if key_fields else fail("No key field found")

        has_vec = any(f.get("type") == "Collection(Edm.Single)" for f in fields)
        if rules["needs_vector"]:
            ok("Vector field present (embedding)") if has_vec else fail("Missing vector field")
        else:
            ok("No vector field (correct — kpi-index uses FK lookup only)") if not has_vec else warn("Unexpected vector field")

        has_sem = "semantic" in s
        if rules["needs_semantic"]:
            ok("Semantic config present") if has_sem else fail("Missing semantic config")
        else:
            ok("No semantic config (correct — kpi-index doesn't need semantic search)") if not has_sem else warn("Unexpected semantic config")

        has_hnsw = "vectorSearch" in s
        if rules["needs_vector"]:
            ok("HNSW vector search config present") if has_hnsw else fail("Missing vectorSearch config")


# ══════════════════════════════════════════════════════════════════════════════
# TEST 3 — Dry run: simulate what seed.py sends to Azure
# ══════════════════════════════════════════════════════════════════════════════
def test_dry_run(records):
    header("TEST 3 — Dry run (simulating seed.py payload)")

    # Build the batch payload exactly as seed.py would
    batch = {
        "value": [
            {"@search.action": "mergeOrUpload", **rec}
            for rec in records
        ]
    }

    total = len(batch["value"])
    ok(f"Batch payload built: {total} documents")

    # Check each doc has the action field
    all_have_action = all("@search.action" in doc for doc in batch["value"])
    ok("All docs have @search.action field") if all_have_action else fail("Missing @search.action on some docs")

    # Estimate payload size
    payload_json = json.dumps(batch)
    size_kb = len(payload_json.encode()) / 1024
    ok(f"Payload size: {size_kb:.1f} KB (Azure Search limit is 16MB per batch — we're fine)")

    # Show what one document looks like
    subheader("  Sample document (RE:04) — exactly what gets sent to Azure:")
    sample = next(d for d in batch["value"] if d["id"] == "RE:04")
    for key, val in sample.items():
        if key == "@search.action":
            print(f"    {BLUE}{'@search.action':<28}{RESET} {val}")
        elif key == "metric_patterns":
            print(f"    {'metric_patterns':<28} {val}")
        elif isinstance(val, str) and len(val) > 60:
            print(f"    {key:<28} {val[:60]}...")
        else:
            print(f"    {key:<28} {val}")


# ══════════════════════════════════════════════════════════════════════════════
# TEST 4 — Mock semantic search (cosine similarity, no Azure needed)
# ══════════════════════════════════════════════════════════════════════════════

def simple_tfidf_vector(text, vocab):
    """
    Dead-simple bag-of-words vector — not real embeddings but demonstrates
    the cosine similarity search mechanic perfectly.
    """
    words = text.lower().split()
    vec = [words.count(w) for w in vocab]
    return vec

def cosine_similarity(a, b):
    dot   = sum(x*y for x, y in zip(a, b))
    mag_a = math.sqrt(sum(x*x for x in a))
    mag_b = math.sqrt(sum(x*x for x in b))
    if mag_a == 0 or mag_b == 0:
        return 0.0
    return dot / (mag_a * mag_b)

def test_mock_search(records):
    header("TEST 4 — Mock semantic search (cosine similarity, no Azure needed)")

    info("This simulates what the LLM does when it receives a spec requirement.")
    info("Real embeddings use 1536 dimensions; this uses word frequency vectors.")
    info("The mechanic is identical — cosine similarity to find closest matches.\n")

    # Build a shared vocabulary from all record text
    all_text = " ".join(
        r.get("recommendation","") + " " + r.get("risk_summary","")
        for r in records
    ).lower()
    # Keep only reasonably frequent words (skip stopwords)
    stopwords = {"the","a","and","to","of","in","is","are","for","from","that",
                 "this","with","or","an","not","be","by","as","all","on","its",
                 "at","it","if","have","has","can","will","may","must","your",
                 "which","when","you","do","into","also","any","each","more","only"}
    word_freq = {}
    for w in all_text.split():
        w = w.strip(".,;:()[]'\"")
        if w not in stopwords and len(w) > 3:
            word_freq[w] = word_freq.get(w, 0) + 1
    # Use words that appear at least twice (gives a manageable vocabulary)
    vocab = [w for w, c in word_freq.items() if c >= 2]

    # Vectorise all records
    vectorised = []
    for r in records:
        text = r.get("recommendation","") + " " + r.get("risk_summary","")
        vec  = simple_tfidf_vector(text, vocab)
        vectorised.append((r, vec))

    # ── Run three test queries ─────────────────────────────────────────────
    queries = [
        "The system must recover quickly from failures with minimal data loss",
        "All API endpoints must require authentication and access should be least privilege",
        "Response time must be under 200ms at the 95th percentile under peak load",
    ]

    for query in queries:
        subheader(f"  Query: \"{query}\"")
        query_vec = simple_tfidf_vector(query, vocab)

        results = []
        for record, vec in vectorised:
            score = cosine_similarity(query_vec, vec)
            results.append((score, record))

        results.sort(key=lambda x: x[0], reverse=True)
        top3 = results[:3]

        for i, (score, r) in enumerate(top3, 1):
            bar = "█" * int(score * 20)
            print(f"    {i}. {GREEN}{r['id']}{RESET}  {r['pillar_id']:<14}  score: {score:.3f}  {BLUE}{bar}{RESET}")
            print(f"       {r['recommendation'][:80]}...")
        print()

    info("In production, the LLM sends the spec requirement to Azure OpenAI →")
    info("gets back 1536 floats → Azure Search does HNSW cosine search →")
    info("returns top 3–5 WAF principles → LLM derives the GQM chain.")


# ══════════════════════════════════════════════════════════════════════════════
# TEST 5 — Simulate a complete GQM derivation (no LLM, just the structure)
# ══════════════════════════════════════════════════════════════════════════════
def test_gqm_simulation():
    header("TEST 5 — Simulate a GQM chain derivation")
    info("Shows the exact JSON that /kpi-derive would write to gqm-index")
    info("and kpi-index for a real spec requirement.\n")

    import uuid

    spec_requirement = "The API must recover from partial failures within 30 minutes and lose no more than 5 minutes of data."

    # Simulate what the LLM would derive after reading RE:04 and RE:09
    gqm_record = {
        "id": str(uuid.uuid4()),
        "spec_id": "spec-demo-001",
        "spec_version": "1.0.0",
        "source": "waf_derived",
        "waf_code_refs": ["RE:04", "RE:09"],
        "pillar_id": "reliability",
        "goal": "Ensure the API recovers from partial failure within defined time bounds without data loss",
        "question": "What is the actual RTO during failure scenarios? How much data is lost during recovery?",
        "metric_name": "Recovery time objective (RTO) and Recovery point objective (RPO)",
        "metric_unit": "minutes",
    }

    kpi_rto = {
        "id": str(uuid.uuid4()),
        "gqm_id": gqm_record["id"],
        "pillar_id": "reliability",
        "environment": "production",
        "threshold_value": "<= 30 minutes",
        "threshold_numeric": 30.0,
        "threshold_direction": "lte",
        "measurement_method": "Azure Monitor + manual DR drill",
        "status": "pending",
        "measured_value": None,
        "validated_at": None,
    }

    kpi_rpo = {
        "id": str(uuid.uuid4()),
        "gqm_id": gqm_record["id"],
        "pillar_id": "reliability",
        "environment": "production",
        "threshold_value": "<= 5 minutes",
        "threshold_numeric": 5.0,
        "threshold_direction": "lte",
        "measurement_method": "Azure Backup recovery point logs",
        "status": "pending",
        "measured_value": None,
        "validated_at": None,
    }

    subheader(f"  Input spec requirement:")
    print(f"    \"{spec_requirement}\"\n")

    subheader("  → gqm-index record (1 chain derived):")
    for k, v in gqm_record.items():
        print(f"    {k:<22} {v}")

    subheader("\n  → kpi-index records (2 thresholds — RTO and RPO):")
    for kpi in [kpi_rto, kpi_rpo]:
        print(f"\n    [{kpi['threshold_value']}]")
        for k, v in kpi.items():
            if k not in ("id", "gqm_id"):
                print(f"    {k:<22} {v}")

    subheader("\n  → After /validate-kpi runs (simulated pass):")
    print(f"    measured_value (RTO):  22.0 minutes")
    print(f"    status (RTO):          {GREEN}pass{RESET}  (22.0 <= 30.0 ✓)")
    print(f"    measured_value (RPO):  3.5 minutes")
    print(f"    status (RPO):          {GREEN}pass{RESET}  (3.5 <= 5.0 ✓)")


# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    print(f"\n{BOLD}{'='*60}")
    print("  KPI-Spec DB — local test suite")
    print(f"{'='*60}{RESET}")
    print("  No Azure credentials needed for any of these tests.\n")

    records = test_seed_file()
    if records:
        test_schemas()
        test_dry_run(records)
        test_mock_search(records)
        test_gqm_simulation()

    print(f"\n{BOLD}{GREEN}{'='*60}")
    print("  All local tests complete.")
    print(f"{'='*60}{RESET}\n")
    print("  Next steps when you have Azure credentials:")
    print("  1.  Set env vars (see README.md)")
    print("  2.  python db/scripts/seed.py   ← creates indexes + uploads records")
    print("  3.  python db/scripts/embed.py  ← generates real embeddings")
    print("  4.  Test search in Azure portal → your Search resource → Search Explorer\n")
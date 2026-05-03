"""
kpi_agent.py
------------
Local KPI derivation agent. No Azure credentials needed.

Takes a natural language requirement, finds the most relevant WAF
principles from the local seed file using cosine similarity, then
calls the OpenAI API to derive a full GQM chain and KPI targets.

Outputs to gqm_output.json and kpi_output.json — exact same schema
as gqm-index and kpi-index. Swap 4 lines when Azure is ready.

Usage:
    python kpi_agent.py

Set your OpenAI API key:
    Mac/Linux:  export OPENAI_API_KEY="sk-..."
    Windows:    $env:OPENAI_API_KEY="sk-..."

Get a key at: platform.openai.com
"""

import json
import math
import os
import uuid
from datetime import datetime
from pathlib import Path
import requests

# ── Config ─────────────────────────────────────────────────────────────────
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENAI_MODEL   = "gpt-4o-mini"   # cheap and fast — swap to gpt-4o for better quality
SEED_FILE      = Path(__file__).parent / "db" / "waf_index_seed.json"
GQM_OUTPUT        = Path(__file__).parent / "gqm_output.json"
KPI_OUTPUT        = Path(__file__).parent / "kpi_output.json"
TOP_K             = 3   # how many WAF principles to retrieve per requirement

# ── Colours ─────────────────────────────────────────────────────────────────
G = "\033[92m"; R = "\033[91m"; B = "\033[94m"; Y = "\033[93m"
P = "\033[95m"; RESET = "\033[0m"; BOLD = "\033[1m"

def ok(m):   print(f"  {G}✓{RESET}  {m}")
def err(m):  print(f"  {R}✗{RESET}  {m}")
def info(m): print(f"  {B}→{RESET}  {m}")
def warn(m): print(f"  {Y}!{RESET}  {m}")
def step(n, m): print(f"\n{BOLD}{P}[{n}]{RESET} {BOLD}{m}{RESET}")


# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Load WAF seed data
# ══════════════════════════════════════════════════════════════════════════════
def load_waf_records():
    if not SEED_FILE.exists():
        err(f"Seed file not found: {SEED_FILE}")
        raise SystemExit(1)
    records = json.loads(SEED_FILE.read_text())["value"]
    ok(f"Loaded {len(records)} WAF records from seed file")
    return records


# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Local semantic search (cosine similarity over word vectors)
#
# NOTE: This is a stand-in for Azure AI Search + real embeddings.
# Real embeddings understand meaning — "recover from failure" matches RE:04
# even without shared vocabulary. Word vectors only match shared words.
# When Azure is ready, replace this function with an Azure Search API call.
# The rest of the agent stays identical.
# ══════════════════════════════════════════════════════════════════════════════
STOPWORDS = {
    "the","a","and","to","of","in","is","are","for","from","that","this",
    "with","or","an","not","be","by","as","all","on","its","at","it","if",
    "have","has","can","will","may","must","your","which","when","you","do",
    "into","also","any","each","more","only","should","their","these","those",
    "such","use","used","using","ensure","make","need","needs","required"
}

def build_vocab(records):
    all_text = " ".join(
        r.get("recommendation","") + " " + r.get("risk_summary","")
        for r in records
    ).lower()
    freq = {}
    for w in all_text.split():
        w = w.strip(".,;:()[]'\"!?")
        if w not in STOPWORDS and len(w) > 3:
            freq[w] = freq.get(w, 0) + 1
    return [w for w, c in freq.items() if c >= 2]

def vectorise(text, vocab):
    words = text.lower().split()
    words = [w.strip(".,;:()[]'\"!?") for w in words]
    return [words.count(w) for w in vocab]

def cosine(a, b):
    dot   = sum(x*y for x,y in zip(a,b))
    mag_a = math.sqrt(sum(x*x for x in a))
    mag_b = math.sqrt(sum(x*x for x in b))
    if mag_a == 0 or mag_b == 0: return 0.0
    return dot / (mag_a * mag_b)

def search_waf(requirement, records, vocab, top_k=TOP_K):
    """
    Local stand-in for Azure AI Search vector query.

    Azure version (4 lines to swap in):
        response = requests.post(
            f"{AZURE_SEARCH_ENDPOINT}/indexes/waf-index/docs/search?api-version=2024-05-01-preview",
            headers={"api-key": AZURE_SEARCH_ADMIN_KEY, "Content-Type": "application/json"},
            json={"vectorQueries": [{"vector": embed(requirement), "fields": "embedding", "k": top_k}]}
        )
        return response.json()["value"]
    """
    query_vec = vectorise(requirement, vocab)
    scored = []
    for r in records:
        text = r.get("recommendation","") + " " + r.get("risk_summary","")
        score = cosine(query_vec, vectorise(text, vocab))
        scored.append((score, r))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [(score, r) for score, r in scored[:top_k]]


# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Call OpenAI API to derive GQM chain + KPI targets
# ══════════════════════════════════════════════════════════════════════════════
def call_openai(prompt):
    if not OPENAI_API_KEY:
        err("OPENAI_API_KEY not set.")
        err("Mac/Linux: export OPENAI_API_KEY='sk-...'")
        err("Windows:   $env:OPENAI_API_KEY='sk-...'")
        err("Get a key at: platform.openai.com")
        raise SystemExit(1)

    response = requests.post(
        "https://api.openai.com/v1/chat/completions",
        headers={
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type":  "application/json",
        },
        json={
            "model":    OPENAI_MODEL,
            "messages": [{"role": "user", "content": prompt}],
        }
    )

    if response.status_code != 200:
        err(f"OpenAI API error: {response.status_code} — {response.text[:200]}")
        raise SystemExit(1)

    return response.json()["choices"][0]["message"]["content"]


def derive_gqm_and_kpi(requirement, waf_matches, spec_id):
    """
    Builds the prompt from the requirement + top WAF matches,
    calls Claude to generate a GQM chain and KPI targets,
    and parses the JSON response into records ready for storage.
    """

    # Format WAF context for the prompt
    waf_context = "\n\n".join([
        f"WAF Principle {r['id']} ({r['pillar_id']}):\n"
        f"Recommendation: {r['recommendation']}\n"
        f"Typical metrics: {', '.join(r.get('metric_patterns', []))}\n"
        f"Typical thresholds: {r.get('typical_thresholds', '')}\n"
        f"Risk if ignored: {r.get('risk_summary', '')}"
        for _, r in waf_matches
    ])

    waf_codes = [r["id"] for _, r in waf_matches]
    pillar    = waf_matches[0][1]["pillar_id"] if waf_matches else "reliability"

    prompt = f"""You are a software quality engineer deriving measurable KPIs from a specification requirement.

SPECIFICATION REQUIREMENT:
"{requirement}"

RELEVANT WAF PRINCIPLES (retrieved by semantic search):
{waf_context}

Your task: derive ONE GQM chain and 1-3 KPI targets from this requirement, grounded in the WAF principles above.

Respond ONLY with a single JSON object in this exact format — no preamble, no markdown, no explanation:

{{
  "goal": "A single sentence describing the high-level intent of this requirement",
  "question": "What would you need to measure to know if this goal is met?",
  "metric_name": "Short name for the primary metric (e.g. 'p95 API response time')",
  "metric_unit": "One of: percentage, milliseconds, hours, minutes, count, currency",
  "kpis": [
    {{
      "threshold_value": "Human readable threshold e.g. '<= 200ms'",
      "threshold_numeric": 200.0,
      "threshold_direction": "lte",
      "measurement_method": "How this would be measured e.g. 'Azure Monitor', 'load test', 'manual drill'"
    }}
  ]
}}

Rules:
- threshold_direction must be exactly "gte" (higher is better, e.g. uptime) or "lte" (lower is better, e.g. latency, error rate)
- threshold_numeric must be a plain number matching the threshold_value
- Keep goal and question to one sentence each
- Return ONLY the JSON object, nothing else"""

    info("Calling OpenAI API...")
    raw = call_openai(prompt)

    # Strip any accidental markdown fences
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.split("```")[1]
        if raw.startswith("json"):
            raw = raw[4:]
    raw = raw.strip()

    try:
        derived = json.loads(raw)
    except json.JSONDecodeError as e:
        err(f"Failed to parse Claude response as JSON: {e}")
        print(f"  Raw response:\n{raw[:400]}")
        raise SystemExit(1)

    # Build gqm-index record
    gqm_id = str(uuid.uuid4())
    gqm_record = {
        "id":            gqm_id,
        "spec_id":       spec_id,
        "spec_version":  "1.0.0",
        "source":        "waf_derived",
        "waf_code_refs": waf_codes,
        "pillar_id":     pillar,
        "goal":          derived["goal"],
        "question":      derived["question"],
        "metric_name":   derived["metric_name"],
        "metric_unit":   derived["metric_unit"],
    }

    # Build kpi-index records (one per threshold)
    kpi_records = []
    for kpi in derived.get("kpis", []):
        kpi_records.append({
            "id":                  str(uuid.uuid4()),
            "gqm_id":              gqm_id,
            "pillar_id":           pillar,
            "environment":         "production",
            "threshold_value":     kpi["threshold_value"],
            "threshold_numeric":   kpi["threshold_numeric"],
            "threshold_direction": kpi["threshold_direction"],
            "measurement_method":  kpi["measurement_method"],
            "status":              "pending",
            "measured_value":      None,
            "validated_at":        None,
            "notes":               f"Derived from: {requirement[:100]}",
        })

    return gqm_record, kpi_records


# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Save outputs
# ══════════════════════════════════════════════════════════════════════════════
def load_existing(path):
    if path.exists():
        return json.loads(path.read_text())
    return []

def save_outputs(gqm_record, kpi_records):
    """
    Writes to local JSON files that mirror gqm-index and kpi-index exactly.
    When Azure is ready, replace this with Azure Search bulk upload calls.
    """
    gqm_all = load_existing(GQM_OUTPUT)
    gqm_all.append(gqm_record)
    GQM_OUTPUT.write_text(json.dumps(gqm_all, indent=2))

    kpi_all = load_existing(KPI_OUTPUT)
    kpi_all.extend(kpi_records)
    KPI_OUTPUT.write_text(json.dumps(kpi_all, indent=2))

    ok(f"GQM chain saved → {GQM_OUTPUT.name}")
    ok(f"{len(kpi_records)} KPI target(s) saved → {KPI_OUTPUT.name}")


# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
def run(requirement, spec_id="spec-local-001"):
    print(f"\n{BOLD}{'='*60}")
    print("  KPI derivation agent — local mode")
    print(f"{'='*60}{RESET}\n")

    # 1 — Load WAF data
    step(1, "Loading WAF reference data")
    records = load_waf_records()
    vocab   = build_vocab(records)
    info(f"Vocabulary built: {len(vocab)} terms")

    # 2 — Search for relevant WAF principles
    step(2, "Searching for relevant WAF principles")
    info(f"Requirement: \"{requirement}\"")
    matches = search_waf(requirement, records, vocab)
    print()
    for i, (score, r) in enumerate(matches, 1):
        bar = "█" * int(score * 20)
        print(f"  {i}. {G}{r['id']}{RESET}  {r['pillar_id']:<14}  score: {score:.3f}  {B}{bar}{RESET}")
        print(f"     {r['recommendation'][:80]}...")

    warn("Note: using word-vector similarity. Real embeddings will improve match quality.")

    # 3 — Derive GQM + KPI via OpenAI
    step(3, "Deriving GQM chain and KPI targets via OpenAI")
    gqm_record, kpi_records = derive_gqm_and_kpi(requirement, matches, spec_id)

    # 4 — Print results
    step(4, "Results")
    print(f"\n  {BOLD}GQM chain:{RESET}")
    print(f"  {'Goal':<12} {gqm_record['goal']}")
    print(f"  {'Question':<12} {gqm_record['question']}")
    print(f"  {'Metric':<12} {gqm_record['metric_name']} ({gqm_record['metric_unit']})")
    print(f"  {'WAF refs':<12} {gqm_record['waf_code_refs']}")
    print(f"  {'Pillar':<12} {gqm_record['pillar_id']}")

    print(f"\n  {BOLD}KPI targets:{RESET}")
    for kpi in kpi_records:
        direction_label = "higher is better" if kpi["threshold_direction"] == "gte" else "lower is better"
        print(f"  • {kpi['threshold_value']:<20} ({direction_label})")
        print(f"    measured by: {kpi['measurement_method']}")
        print(f"    status: {kpi['status']}")

    # 5 — Save
    step(5, "Saving outputs")
    save_outputs(gqm_record, kpi_records)

    print(f"\n{BOLD}{G}{'='*60}")
    print("  Done.")
    print(f"{'='*60}{RESET}\n")

    return gqm_record, kpi_records


# ── Entry point ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    # ── Test requirements — edit these to try different inputs ──────────────
    requirements = [
        "The API must respond within 200ms at the 95th percentile under normal load",
        "All endpoints must require authentication and use least-privilege access",
        "The system must recover from partial failures within 30 minutes with no more than 5 minutes of data loss",
    ]

    spec_id = f"spec-local-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

    for req in requirements:
        run(req, spec_id)
        print("\n" + "─"*60 + "\n")
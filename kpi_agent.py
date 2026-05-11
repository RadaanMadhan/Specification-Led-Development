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

# ══════════════════════════════════════════════════════════════════════════════
# SPEC PARSER — reads a SpecKit spec.md and extracts requirements
# ══════════════════════════════════════════════════════════════════════════════
import re

def parse_spec(spec_path: Path) -> dict:
    """
    Reads a SpecKit spec.md and extracts:
      - feature_name  : from the H1 heading
      - frs           : list of (id, text) from FR-NNN lines
      - stories       : list of user story titles
      - scenarios     : list of Given/When/Then strings
      - success_criteria: list of SC-NNN lines

    Returns a dict with all of the above plus the raw markdown.
    """
    if not spec_path.exists():
        err(f"Spec file not found: {spec_path}")
        raise SystemExit(1)

    raw = spec_path.read_text(encoding="utf-8")

    # Feature name — first H1
    name_match = re.search(r'^#\s+(.+)$', raw, re.MULTILINE)
    feature_name = name_match.group(1).strip() if name_match else "Unknown Feature"

    # FRs — lines like: - **FR-001**: System MUST ...
    frs = []
    for m in re.finditer(r'\*\*(FR-\d+)\*\*:\s*(.+)', raw):
        frs.append({"id": m.group(1), "text": m.group(2).strip()})

    # User story titles — ### User Story N - ...
    stories = re.findall(r'###\s+User Story.+?-\s+(.+?)(?:\s*\(|$)', raw, re.MULTILINE)

    # Acceptance scenarios — Given ... When ... Then ...
    scenarios = []
    for m in re.finditer(
        r'\*\*Given\*\*\s+(.+?),\s*\*\*When\*\*\s+(.+?),\s*\*\*Then\*\*\s+(.+?)(?:\.|$)',
        raw, re.IGNORECASE | re.DOTALL
    ):
        scenarios.append({
            "given": m.group(1).strip(),
            "when":  m.group(2).strip(),
            "then":  m.group(3).strip(),
        })

    # Success criteria — SC-NNN lines
    success_criteria = []
    for m in re.finditer(r'\*\*(SC-\d+)\*\*:\s*(.+)', raw):
        success_criteria.append({"id": m.group(1), "text": m.group(2).strip()})

    return {
        "feature_name":     feature_name,
        "frs":              frs,
        "stories":          stories,
        "scenarios":        scenarios,
        "success_criteria": success_criteria,
        "raw":              raw,
    }


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
# STEP 2 — Semantic search using real OpenAI embeddings
#
# Uses text-embedding-3-small (same model as Azure OpenAI) via OpenAI directly.
# WAF records are embedded once and cached in waf_embeddings_cache.json so
# you only pay for 59 embedding calls on the first run — after that it's free.
# When Azure AI Search is ready, replace search_waf() with an Azure Search call.
# ══════════════════════════════════════════════════════════════════════════════
EMBED_MODEL  = "text-embedding-3-small"
EMBED_CACHE  = Path(__file__).parent / "waf_embeddings_cache.json"

def cosine(a, b):
    dot   = sum(x*y for x,y in zip(a,b))
    mag_a = math.sqrt(sum(x*x for x in a))
    mag_b = math.sqrt(sum(x*x for x in b))
    if mag_a == 0 or mag_b == 0: return 0.0
    return dot / (mag_a * mag_b)

def get_embedding(text: str) -> list:
    """Call OpenAI to embed a single string. Returns 1536 floats."""
    response = requests.post(
        "https://api.openai.com/v1/embeddings",
        headers={
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type":  "application/json",
        },
        json={"model": EMBED_MODEL, "input": text}
    )
    if response.status_code != 200:
        err(f"Embedding API error: {response.status_code} — {response.text[:200]}")
        raise SystemExit(1)
    return response.json()["data"][0]["embedding"]

def load_waf_embeddings(records) -> dict:
    """
    Load cached WAF embeddings from disk, or generate and cache them.
    Only calls OpenAI once for all 59 records — subsequent runs use the cache.
    Cache key is the WAF record id (e.g. RE:04).
    """
    # Load existing cache
    cache = {}
    if EMBED_CACHE.exists():
        cache = json.loads(EMBED_CACHE.read_text())

    # Find any records not yet cached
    missing = [r for r in records if r["id"] not in cache]

    if missing:
        info(f"Generating embeddings for {len(missing)} WAF records (cached: {len(cache)})...")
        for r in missing:
            text = r["recommendation"] + " " + r["risk_summary"]
            cache[r["id"]] = get_embedding(text)
            ok(f"Embedded {r['id']}")
        # Save updated cache
        EMBED_CACHE.write_text(json.dumps(cache, indent=2))
        ok(f"Embeddings cached → {EMBED_CACHE.name}")
    else:
        ok(f"Using cached embeddings for all {len(records)} WAF records")

    return cache

def search_waf(requirement, records, waf_embeddings, top_k=TOP_K):
    """
    Semantic search using real OpenAI embeddings + cosine similarity.
    Embeds the requirement, then ranks all WAF records by cosine distance.

    Azure version (swap this entire function):
        response = requests.post(
            f"{AZURE_SEARCH_ENDPOINT}/indexes/waf-index/docs/search?api-version=2024-05-01-preview",
            headers={"api-key": AZURE_SEARCH_ADMIN_KEY, "Content-Type": "application/json"},
            json={"vectorQueries": [{"vector": get_embedding(requirement), "fields": "embedding", "k": top_k}]}
        )
        return [(r["@search.score"], r) for r in response.json()["value"]]
    """
    query_vec = get_embedding(requirement)
    scored = []
    for r in records:
        score = cosine(query_vec, waf_embeddings[r["id"]])
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
    seen = set()  # dedup key: (threshold_numeric, threshold_direction)
    for kpi in derived.get("kpis", []):
        dedup_key = (kpi["threshold_numeric"], kpi["threshold_direction"])
        if dedup_key in seen:
            warn(f"Duplicate KPI skipped: {kpi['threshold_value']} ({kpi['threshold_direction']})")
            continue
        seen.add(dedup_key)
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

    # 1 — Load WAF data + embeddings
    step(1, "Loading WAF reference data")
    records = load_waf_records()
    waf_embeddings = load_waf_embeddings(records)

    # 2 — Search for relevant WAF principles
    step(2, "Searching for relevant WAF principles")
    info(f"Requirement: \"{requirement}\"")
    matches = search_waf(requirement, records, waf_embeddings)
    print()
    for i, (score, r) in enumerate(matches, 1):
        bar = "█" * int(score * 20)
        print(f"  {i}. {G}{r['id']}{RESET}  {r['pillar_id']:<14}  score: {score:.3f}  {B}{bar}{RESET}")
        print(f"     {r['recommendation'][:80]}...")

    info(f"Using real OpenAI embeddings (text-embedding-3-small)")

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
    import sys

    # Accept spec file as argument, default to spec.md in same directory
    spec_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "spec.md"

    print(f"\n{BOLD}{'='*60}")
    print("  KPI-Spec — reading from spec.md")
    print(f"{'='*60}{RESET}")

    # Parse the spec
    spec = parse_spec(spec_path)
    spec_id = f"spec-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

    print(f"\n  Feature : {spec['feature_name']}")
    print(f"  FRs     : {len(spec['frs'])} requirements found")
    print(f"  Stories : {len(spec['stories'])} user stories found")
    print(f"  Scenarios: {len(spec['scenarios'])} acceptance scenarios found")

    if not spec['frs']:
        err("No FR-NNN lines found in spec. Check the spec format.")
        raise SystemExit(1)

    # Show what was parsed
    print(f"\n  {BOLD}Requirements extracted:{RESET}")
    for fr in spec['frs']:
        print(f"  {B}{fr['id']}{RESET}  {fr['text']}")

    print("\n" + "─"*60)

    # Run the agent on every FR
    all_gqm = []
    all_kpi = []
    for fr in spec['frs']:
        requirement = f"{fr['id']}: {fr['text']}"
        gqm_record, kpi_records = run(requirement, spec_id)
        all_gqm.append(gqm_record)
        all_kpi.extend(kpi_records)
        print("\n" + "─"*60 + "\n")

    # Final summary
    print(f"\n{BOLD}{G}{'='*60}")
    print(f"  Spec processed: {spec['feature_name']}")
    print(f"  Requirements:   {len(spec['frs'])} FRs")
    print(f"  GQM chains:     {len(all_gqm)} generated")
    print(f"  KPI targets:    {len(all_kpi)} generated")
    print(f"  Outputs:        gqm_output.json  +  kpi_output.json")
    print(f"{'='*60}{RESET}\n")
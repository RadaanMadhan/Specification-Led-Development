#!/usr/bin/env bash
#
# debug_opus_thinking.command — diagnose why Opus 4.7 hangs in E0b.
#
# Kills any hung verify-design process from the prior run, then sends a
# short prompt to Opus 4.7 / Opus 4.6 under several request-body shapes
# to find one that returns in under 90 s. The output that "succeeds" is
# the one we'll lock TIER_CONFIG to.
#
# Each probe uses max_tokens=4096 and a 90-second per-request timeout so
# we get fast feedback on whether the shape works AT ALL — not whether
# it produces an acceptable lift.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

LOG_DIR="$ROOT/runs/_e0b_sanity_check"
mkdir -p "$LOG_DIR"
DEBUG_LOG="$LOG_DIR/debug_opus_thinking.log"
DONE_MARKER="$LOG_DIR/DEBUG_DONE"
rm -f "$DONE_MARKER"

# Kill any hung python process running the verify-design CLI from the
# prior sanity-check attempt.
echo "================================================================"
echo "  Debug: killing any hung speceval.cli verify-design processes..."
echo "================================================================"
pkill -f "speceval.cli verify-design" 2>/dev/null && echo "  killed" || echo "  none found"
echo

if [ -f "$HOME/.zshrc" ]; then
  # shellcheck source=/dev/null
  source "$HOME/.zshrc" 2>/dev/null || true
fi
if command -v conda >/dev/null 2>&1; then
  eval "$(conda shell.bash hook 2>/dev/null)" || true
  conda activate base 2>/dev/null || true
fi

PYBIN=""
for CANDIDATE in \
    "$(command -v python3 2>/dev/null || true)" \
    "$HOME/anaconda3/bin/python3" \
    "$HOME/miniconda3/bin/python3" \
    "/opt/anaconda3/bin/python3" \
    "/usr/local/bin/python3" \
    "/usr/bin/python3"; do
  if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then
    PYBIN="$CANDIDATE"
    break
  fi
done
echo "python: $PYBIN"
echo "log   : $DEBUG_LOG"
echo

"$PYBIN" - <<'PY' 2>&1 | tee "$DEBUG_LOG"
"""Probe Opus thinking-config variants. Each probe is a single short
Messages-API call with a 90-second timeout. We report status code,
elapsed seconds, response keys, and the first 200 chars of the text.

Variants tried (in order):
  V1  opus-4-7  adaptive,                       output_config.effort=max
  V2  opus-4-7  adaptive (display=omitted),     output_config.effort=max  <-- current TIER_CONFIG
  V3  opus-4-7  adaptive,                       NO output_config
  V4  opus-4-7  adaptive (display=omitted),     NO output_config
  V5  opus-4-7  enabled,  budget_tokens=8192,   NO output_config (= old "manual mode")
  V6  opus-4-7  (no thinking field at all)
  V7  opus-4-6  adaptive,                       output_config.effort=max
  V8  opus-4-6  (no thinking field at all)      <-- known-good baseline

The first variant returning a 200 in under 90 s is a viable
configuration for M-best. We report all of them so we can choose.
"""
import json, os, time, sys
from pathlib import Path

# Load .env
for env_path in (Path.cwd() / ".env",):
    if env_path.exists():
        for raw in env_path.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            k = k.strip()
            v = v.strip().strip('"').strip("'")
            if k and k not in os.environ:
                os.environ[k] = v
api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
if not api_key:
    print("FATAL: ANTHROPIC_API_KEY not set"); sys.exit(1)
print(f"  api key prefix: {api_key[:18]}...  (len={len(api_key)})")

import requests
ENDPOINT = "https://api.anthropic.com/v1/messages"
HEADERS = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
}
SHORT_USER = "Say the single word OK and nothing else."
SYSTEM     = "You answer with one word."

def probe(label, body, timeout=90):
    print(f"\n=== {label} ===")
    print(f"  body keys: {sorted(body)}")
    if 'thinking' in body:
        print(f"  thinking : {body['thinking']}")
    if 'output_config' in body:
        print(f"  output_config: {body['output_config']}")
    t0 = time.perf_counter()
    try:
        r = requests.post(ENDPOINT, headers=HEADERS, json=body, timeout=timeout)
    except requests.RequestException as e:
        print(f"  EXCEPTION after {time.perf_counter()-t0:.1f}s: {e}")
        return False
    elapsed = time.perf_counter() - t0
    print(f"  status={r.status_code}  elapsed={elapsed:.1f}s")
    body_txt = r.text[:400]
    if r.status_code == 200:
        try:
            j = r.json()
            print(f"  resp keys: {sorted(j)}")
            usage = j.get("usage") or {}
            print(f"  usage: {usage}")
            blocks = j.get("content") or []
            print(f"  content block types: {[b.get('type') for b in blocks]}")
            texts = "".join(b.get('text','') for b in blocks if b.get('type')=='text')
            print(f"  text (first 200): {texts[:200]!r}")
            return True
        except Exception as e:
            print(f"  json parse error: {e}; raw: {body_txt}")
            return False
    else:
        print(f"  body: {body_txt}")
        return False

OPUS_47 = "claude-opus-4-7"
OPUS_46 = "claude-opus-4-6"

variants = [
    ("V1 opus-4-7  adaptive            + output_config.effort=max", {
        "model": OPUS_47, "max_tokens": 4096,
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": "max"},
        "system": SYSTEM,
        "messages": [{"role": "user", "content": SHORT_USER}],
    }),
    ("V2 opus-4-7  adaptive omitted    + output_config.effort=max  (CURRENT TIER_CONFIG)", {
        "model": OPUS_47, "max_tokens": 4096,
        "thinking": {"type": "adaptive", "display": "omitted"},
        "output_config": {"effort": "max"},
        "system": SYSTEM,
        "messages": [{"role": "user", "content": SHORT_USER}],
    }),
    ("V3 opus-4-7  adaptive            (no output_config)", {
        "model": OPUS_47, "max_tokens": 4096,
        "thinking": {"type": "adaptive"},
        "system": SYSTEM,
        "messages": [{"role": "user", "content": SHORT_USER}],
    }),
    ("V4 opus-4-7  adaptive omitted    (no output_config)", {
        "model": OPUS_47, "max_tokens": 4096,
        "thinking": {"type": "adaptive", "display": "omitted"},
        "system": SYSTEM,
        "messages": [{"role": "user", "content": SHORT_USER}],
    }),
    ("V5 opus-4-7  enabled budget=8192 (no output_config)", {
        "model": OPUS_47, "max_tokens": 16384,
        "thinking": {"type": "enabled", "budget_tokens": 8192},
        "system": SYSTEM,
        "messages": [{"role": "user", "content": SHORT_USER}],
    }),
    ("V6 opus-4-7  NO thinking field", {
        "model": OPUS_47, "max_tokens": 4096,
        "system": SYSTEM,
        "messages": [{"role": "user", "content": SHORT_USER}],
    }),
    ("V7 opus-4-6  adaptive omitted    + output_config.effort=max", {
        "model": OPUS_46, "max_tokens": 4096,
        "thinking": {"type": "adaptive", "display": "omitted"},
        "output_config": {"effort": "max"},
        "system": SYSTEM,
        "messages": [{"role": "user", "content": SHORT_USER}],
    }),
    ("V8 opus-4-6  NO thinking field  (known-good baseline)", {
        "model": OPUS_46, "max_tokens": 4096,
        "system": SYSTEM,
        "messages": [{"role": "user", "content": SHORT_USER}],
    }),
]

results = []
for label, body in variants:
    ok = probe(label, body, timeout=90)
    results.append((label, ok))

print("\n================================================================")
print("  SUMMARY")
print("================================================================")
for label, ok in results:
    print(f"  [{'PASS' if ok else 'FAIL'}]  {label}")
PY

echo
echo "================================================================"
echo "  Debug complete. See $DEBUG_LOG"
echo "================================================================"
echo "done" > "$DONE_MARKER"
echo
echo "Done. You can close this window."

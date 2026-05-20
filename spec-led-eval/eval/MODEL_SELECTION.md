# spec-led-eval — Model Selection (Phase E0a output)

**Status**: committed (preflight; no code changes in this phase)
**Author**: Leon Hausmann, Microsoft Project 9
**Date**: 2026-05-17
**Sources**: Anthropic API docs (`platform.claude.com/docs/en/about-claude/models/overview`,
`.../build-with-claude/extended-thinking`, `.../build-with-claude/adaptive-thinking`,
`.../about-claude/pricing`), all read on 2026-05-17.

This document fixes the three model tiers used by the AQS evaluation
described in `EVALUATION_PLAN.md`. Once the tier table and request bodies
below are committed, Phase E0b (instrumentation) can extend
`speceval/providers/anthropic.py` to send these request shapes without
further research.

The research deliberately covers all three tiers up front, even though
Stage 2 may never run, because Anthropic's lineup shifts and re-research
risks the M-mid/M-small choices drifting after Stage 1 finishes.

---

## 1. Headline result

Reality differs from the original plan assumption in two important ways:

1. **Opus 4.7 (M-best) does *not* accept `thinking: {type: "enabled"}`** —
   manual extended thinking with a fixed `budget_tokens` returns a 400
   error on Opus 4.7. Opus 4.7's *only* supported thinking mode is
   **adaptive thinking** (`thinking: {type: "adaptive"}`), controlled
   indirectly through the new `effort` parameter rather than through a
   numeric token budget.
2. **Haiku 4.5 (M-small) *does* support extended thinking**, contrary to
   the cautious "may not support thinking — document the asymmetry"
   phrasing in the original plan. Haiku 4.5 supports manual extended
   thinking with `budget_tokens` but does **not** support adaptive
   thinking. So the three tiers split cleanly into:

   - M-best (Opus 4.7): adaptive thinking, no numeric budget
   - M-mid (Sonnet 4.6): adaptive thinking, no numeric budget
   - M-small (Haiku 4.5): manual extended thinking with `budget_tokens`

This asymmetry — adaptive on Opus/Sonnet, manual on Haiku — is real and
should be documented in the methodology section of the write-up. It is
*not* a flaw in the comparison: each model is run in its strongest
configuration ("best shot per model"), which is the methodology Stage 2
hypotheses H5–H7 commit to.

A second, smaller deviation: the original plan placeholder used
`claude-opus-4-7` as a hypothetical. It turns out Opus 4.7 was released
on 2026-04-16 and is in fact the current Opus, so the M-best model
string is now confirmed as `claude-opus-4-7` (not `claude-opus-4-6`).

---

## 2. Tier table

| Tier | API model string | Context window | Max output (sync API) | Thinking support | Thinking config (this eval) | Input price ($/MTok) | Output price ($/MTok) |
|---|---|---|---|---|---|---|---|
| **M-best** | `claude-opus-4-7` | 1,000,000 | 128,000 | Adaptive only (manual rejected with 400) | `{"type": "adaptive", "display": "omitted"}` + `output_config: {"effort": "max"}` | $5.00 | $25.00 |
| **M-mid** | `claude-sonnet-4-6` | 1,000,000 | 64,000 | Adaptive (recommended) or manual (deprecated) | `{"type": "adaptive", "display": "omitted"}` + `output_config: {"effort": "max"}` | $3.00 | $15.00 |
| **M-small** | `claude-haiku-4-5` | 200,000 | 64,000 | Manual only (adaptive not supported) | `{"type": "enabled", "budget_tokens": 16384}` | $1.00 | $5.00 |

Notes on the table:

- **Pricing.** Thinking tokens are billed as output tokens at the
  standard output rate. There is no separate "thinking-token price"
  line. Cache writes / hits and batch-API discounts are documented on
  the pricing page but are not used in this evaluation (`--no-cache`
  is in force per the EVALUATION_PLAN.md).
- **Opus 4.7 tokenizer.** Opus 4.7 ships a new tokenizer that may use
  up to ~1.35× more tokens than previous models for the same text.
  Per-run cost estimates carried over from Opus 4.6 are therefore lower
  bounds; expect the Stage 1 sweep to cost in the $18–25 range rather
  than the original $18 estimate.
- **Haiku model ID alias.** The dated ID `claude-haiku-4-5-20251001`
  and the alias `claude-haiku-4-5` both work; this evaluation uses the
  alias for readability. Both are pinned snapshots in Anthropic's
  versioning scheme.
- **Effort levels.** Anthropic exposes five effort levels: `max`,
  `xhigh`, `high` (default), `medium`, `low`. `max` is described as
  "no constraints on thinking depth" and is available on Opus 4.7,
  Opus 4.6, and Sonnet 4.6. `xhigh` is Opus 4.7-only. We pick
  **`max`** for both Opus 4.7 and Sonnet 4.6 because (a) it is
  available on both, keeping the methodology symmetric, and (b) it
  represents the strongest setting available across both models.
  Using `xhigh` on Opus 4.7 would give it an Opus-only capability that
  Sonnet 4.6 cannot match, muddying the cross-model comparison.
- **`display: "omitted"`.** We never surface thinking text to the user
  in this evaluation; only the final answer (the alloy + manifest
  fenced blocks) is parsed. Setting `display: "omitted"` reduces
  time-to-first-text-token without changing what the model thinks or
  what it costs (thinking tokens are billed identically either way).
  On Opus 4.7 this is also the default; setting it explicitly makes
  the request shape identical across M-best and M-mid for cleaner
  code paths.
- **Haiku `budget_tokens: 16384`.** This is a deliberate "best shot"
  choice — well above the 1,024-token documented minimum, comfortably
  below the 32k zone where Anthropic recommends switching to the
  batch API to avoid HTTP timeouts, and leaves 16k of `max_tokens`
  headroom for the lifter's ~16k visible output. See §5 for the
  sanity-check protocol that validates this is enough.

---

## 3. Request-body templates

Each tier's request body, ready for direct construction by
`providers/anthropic.py` in Phase E0b. The `system` and `messages`
fields are the lifter's existing `DESIGN_LIFT_SYSTEM_PROMPT` and
`build_design_lift_prompt(...)` outputs — they are unchanged across
tiers. Only the `model`, `max_tokens`, `thinking`, and `output_config`
fields differ.

### 3.1 M-best — Opus 4.7

```json
{
  "model": "claude-opus-4-7",
  "max_tokens": 32000,
  "thinking": {
    "type": "adaptive",
    "display": "omitted"
  },
  "output_config": {
    "effort": "max"
  },
  "system": "<DESIGN_LIFT_SYSTEM_PROMPT>",
  "messages": [
    {"role": "user", "content": "<build_design_lift_prompt(feature_dir)>"}
  ]
}
```

Headers (unchanged from current lifter):

```
x-api-key: $ANTHROPIC_API_KEY
anthropic-version: 2023-06-01
content-type: application/json
```

### 3.2 M-mid — Sonnet 4.6

```json
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 32000,
  "thinking": {
    "type": "adaptive",
    "display": "omitted"
  },
  "output_config": {
    "effort": "max"
  },
  "system": "<DESIGN_LIFT_SYSTEM_PROMPT>",
  "messages": [
    {"role": "user", "content": "<build_design_lift_prompt(feature_dir)>"}
  ]
}
```

Identical to M-best except for the model string. Same headers.

### 3.3 M-small — Haiku 4.5

```json
{
  "model": "claude-haiku-4-5",
  "max_tokens": 32000,
  "thinking": {
    "type": "enabled",
    "budget_tokens": 16384
  },
  "system": "<DESIGN_LIFT_SYSTEM_PROMPT>",
  "messages": [
    {"role": "user", "content": "<build_design_lift_prompt(feature_dir)>"}
  ]
}
```

Note the absence of `output_config` — `effort` belongs to adaptive
thinking and is invalid for manual mode. Same headers.

---

## 4. Implementation implications for `providers/anthropic.py`

The current `AnthropicProvider.complete(...)` builds a fixed request
body of shape `{model, max_tokens, system, messages}` and posts it to
`https://api.anthropic.com/v1/messages`. Phase E0b should change as
follows.

### 4.1 Parameterisation

Add a per-tier configuration the provider can apply based on a model
tag passed in. A single function parameterised by tag is sufficient —
no need for three separate builders — because the only differences
across tiers are the model string and the thinking/output-config
fragment.

```python
TIER_CONFIG = {
    "M-best":  {"model": "claude-opus-4-7",   "thinking": {"type": "adaptive", "display": "omitted"}, "output_config": {"effort": "max"}},
    "M-mid":   {"model": "claude-sonnet-4-6", "thinking": {"type": "adaptive", "display": "omitted"}, "output_config": {"effort": "max"}},
    "M-small": {"model": "claude-haiku-4-5",  "thinking": {"type": "enabled", "budget_tokens": 16384}},
}
```

Then `complete(...)` merges the tier config into the request body,
omitting `output_config` when the tier doesn't have one.

### 4.2 `max_tokens` bump

The current lifter sends `max_tokens: 16000`, which is marginal even
without thinking and is too small once thinking is enabled (thinking
tokens count against this cap on the adaptive tiers; `budget_tokens`
must be strictly less than `max_tokens` on the manual tier). Raise the
default to **32000** for all tiers. This:

- Fits the ~16k visible output of the manifest+.als with comfortable
  buffer.
- Leaves ~16k for thinking on the adaptive tiers (effort=max).
- Is well under Haiku 4.5's 64k cap.
- Stays under the 21,333 threshold that triggers Anthropic SDK
  client-side streaming validation — *not* directly relevant because
  we use raw `requests`, but reflects the same underlying
  HTTP-timeout reality. See §4.4 below.

### 4.3 Timeout bump

`timeout_seconds = 120` is too short once thinking is enabled at
effort=max. A single Opus 4.7 adaptive-thinking call on a rich Speckit
folder can easily run 60–180 seconds; pathological cases can exceed
that. **Raise the per-request timeout to 600 seconds (10 minutes)** for
all tiers. This is generous and matches Anthropic's own batch-API
recommendation for thinking budgets above 32k.

`max_retries` can stay at 2.

### 4.4 Streaming

We are *not* required to switch to streaming. The Anthropic-SDK
"`max_tokens > 21,333` requires streaming" is a client-side validation
in the SDK, not an API restriction. The raw `requests`-based provider
in `speceval/providers/anthropic.py` is not subject to it. As long as
the 600s timeout in §4.3 is in place, synchronous POST + JSON response
is fine. If we later see HTTP timeouts in practice during the Stage 1
sweep, we can revisit; for now, keep the simple synchronous path.

### 4.5 Cost-log fields

The `cost_log.json` schema (§4 of EVALUATION_PLAN.md) already includes
the new fields:

- `model` — the tier tag (`M-best`, `M-mid`, `M-small`)
- `thinking_enabled` — `true` for all three tiers in this eval
- `thinking_budget_tokens` — `null` for the adaptive tiers,
  `16384` for M-small
- `thinking_tokens` — read from `response.usage.cache_creation_input_tokens`
  …wait, that's the wrong field. The Messages API returns thinking
  tokens inside `response.usage.output_tokens` (they are billed as
  output) and *separately* in a `cache_creation_input_tokens` /
  `cache_read_input_tokens` pair which are unrelated. Anthropic does
  not currently expose a `thinking_tokens` line item in `usage`
  separately from `output_tokens`. In practice the cost-log should
  record `output_tokens` (the billed total including thinking) and
  optionally a "summary thinking tokens visible in response" count
  computed by counting characters inside returned `thinking`
  blocks — but with `display: "omitted"`, that count is zero. So:
  - **Record `output_tokens` directly**; thinking is folded into it.
  - **Set `thinking_tokens: null`** in cost_log.json for adaptive
    tiers (we have no separate signal).
  - For M-small (manual mode), if Anthropic exposes a
    `thinking_token_count` field in future API responses, capture
    it; otherwise also `null` and treat the configured
    `budget_tokens` as an upper bound.

  This is a small revision to §4 of EVALUATION_PLAN.md. The plan
  says `thinking_tokens` is in `cost_log.json`; in practice that
  field will be `null` on all tiers in our case and is harmless to
  carry, so no plan change is needed — just don't claim it's the
  "actual thinking tokens" because the API doesn't expose that
  separately from `output_tokens`.

### 4.6 Error handling

The plan's D.4 question "Do we need to handle thinking-budget exceeded
vs token-budget exceeded differently?" — the answer is **no, not as
distinct error paths**. Both surface as `stop_reason: "max_tokens"` in
a 200 response, not as 4xx errors. The lifter should:

- Treat `stop_reason: "max_tokens"` as a structural failure (the
  fenced-block parser will fail downstream), log it in the run
  artefacts, and let the scorer's D1 dimension score 0.0.
- Existing 429 / 5xx retry logic stays unchanged.
- A new 400 error path is **needed** specifically for the case where
  someone wires up the wrong thinking mode for the wrong model
  (e.g., sends `{"type": "enabled"}` to Opus 4.7). This should fail
  fast with a clear message; the `TIER_CONFIG` dict above prevents
  this at construction time.

---

## 5. Sanity-check plan (Phase E0a final step)

Per EVALUATION_PLAN.md §D.5, we must verify the chosen M-small tier
can actually produce parseable output on a representative cell before
committing. The check is **deferred to Phase E0b** rather than run
now because it requires the instrumented provider, but the protocol
is pinned here.

### 5.1 Protocol

Run *one* `verify-design` invocation on `eval/specs/A-L2/` using
M-small (Haiku 4.5 with `budget_tokens: 16384`), no cache:

```
python -m speceval.cli verify-design \
    --no-cache \
    --model M-small \
    --java-bin <jdk4py> \
    eval/specs/A-L2/
```

### 5.2 Pass conditions

All four must hold:

1. The response contains **both** a fenced ```` ```alloy ```` block
   and a fenced ```` ```json ```` block (manifest).
2. The manifest parses as valid JSON and declares at least one entry
   each in `patterns_applied` and `mutation_targets`.
3. The .als file compiles under Alloy (no parse errors;
   `runner.run_alloy_file` returns parseable verdicts).
4. The lifter's existing scorer D1 dimension scores 1.0 for this run
   (i.e., assertions ≥ 1 and Alloy returned parseable verdicts).

### 5.3 Failure handling

If any pass condition fails:

- **Drop M-small** from the design and document the failure in the
  plan and the write-up. (Skipping a tier is acceptable per §D.5.)
- Do **not** quietly substitute a different model — the asymmetry
  must be visible in the methodology.
- If we drop M-small, Stage 2 becomes M-mid-only (180 → 90 runs), and
  H6/H7 are weakened but still testable. Update §2.0 of
  EVALUATION_PLAN.md if this happens.

### 5.4 Why A-L2 specifically

A-L2 is mid-richness, mid-domain — neither the sparsest input
(which might fail trivially) nor the richest (which might exceed
Haiku's smaller 200k context if combined with patterns.md plus
the system prompt — though that's unlikely; the lifter's prompt
runs ~5–10k input tokens, far below 200k). A-L2 is a fair
representative of what the model will see across the actual sweep.

---

## 6. Cost re-estimate

The original plan estimated ~$18 for Stage 1's 90 M-best runs and ~$7
for Stage 2's 180 runs combined.

With Opus 4.7's new tokenizer (up to 1.35× more tokens) and adaptive
thinking burning output tokens (~5–15k thinking per call at
effort=max), the M-best run cost may be 2–3× higher than the original
estimate:

| Stage | Model | Runs | Est. cost (low) | Est. cost (high) |
|---|---|---:|---:|---:|
| 1 | M-best (Opus 4.7) | 90 | $18 | $50 |
| 2 | M-mid (Sonnet 4.6) | 90 | $4 | $12 |
| 2 | M-small (Haiku 4.5) | 90 | $1 | $4 |
| **Total Stage 1 + 2** | | **270** | **~$23** | **~$66** |

These are rough envelopes — actual cost depends on how aggressively
the model uses thinking at effort=max, which varies by cell. The plan
text in EVALUATION_PLAN.md §8 should be updated to "$18–50 for Stage 1,
$5–16 for Stage 2" rather than the original point estimates. This is
a documentation update, not a methodology change.

---

## 7. What Phase E0a deliberately did *not* decide

- The order of the Stage 2 sweep (M-mid first or M-small first) —
  parallel-runnable; choice doesn't affect the science. Default in
  `run_experiment.py`: `--models M-mid,M-small`.
- Whether to use the Batch API for any sweep — Stage 1 is small
  enough (~90 runs in ~1 hr) that synchronous Messages is simpler.
  If a later re-run pushes the run count up, Batch becomes worth
  evaluating; that's an E0b/E6 implementation choice, not a
  methodology choice.
- Whether to switch from raw `requests` to the Anthropic SDK —
  preserved as-is per the existing code's documented rationale
  (smaller dep surface, single-turn-only usage). No change in E0b.

---

## 8. 2026-05-18 revision (post-E0b)

**Status: COMMITTED 2026-05-18.** Phase E0b is complete. The decisions
in sections 1–7 above were the pre-registered E0a selections, made on
research before any code was written. Sections 1–7 are preserved
verbatim so the audit trail stays visible; this section captures the
revisions that came out of actually running E0b. In any conflict
between the body of this file and this section, this section is
authoritative.

### 8.1 — `effort: "max"` → `effort: "high"` + SSE streaming

`effort: "max"` proved operationally unreliable on Opus 4.7 during
E0b. Non-streaming HTTP requests hung past 30 minutes on richer cells
(e.g. A-L2) because intermediate proxies drop sockets that have
nothing to send during Opus 4.7's multi-minute adaptive-thinking
phase. Dropping the effort knob to `effort: "high"` alone did **not**
fix it — same socket-liveness problem. The real fix was
**SSE streaming**: `_consume_sse_stream(resp)` in
`speceval/providers/anthropic.py` parses Anthropic's
`message_start` / `content_block_start` / `content_block_delta` /
`message_delta` / `message_stop` events incrementally, which keeps the
socket alive throughout the thinking phase and makes 5–15-minute
lifts reliable.

The streaming code is therefore mandatory for M-best in this
evaluation. §4.4 of the body ("we are not required to switch to
streaming") is **superseded**: we *are* streaming, via raw `requests`
SSE parsing, not via the Anthropic SDK.

With streaming working, the smaller effort drop from `"max"` →
`"high"` is the second piece: `"high"` is Anthropic's documented
default for Opus 4.7 adaptive thinking, strictly weaker than `"max"`
but still extended-thinking-on. We pick `"high"` rather than `"max"`
because empirically `"high"` is enough to produce 8/9 PARSE_OK with
~97% aggregate PASS, and `"max"` was operationally fragile even with
streaming in early tests. The methodology drift "strongest available"
→ "default-strong-and-actually-reliable" is documented in
EVALUATION_PLAN.md Appendix E.1.

### 8.2 — Final M-best config

The `TIER_CONFIG` dict in §4.1 above is **superseded** by:

```python
TIER_CONFIG = {
    "M-best":  {"model": "claude-opus-4-7",
                "thinking": {"type": "adaptive", "display": "omitted"},
                "output_config": {"effort": "high"}},
    "M-mid":   {"model": "claude-sonnet-4-6",
                "thinking": {"type": "adaptive", "display": "omitted"},
                "output_config": {"effort": "high"}},
    "M-small": {"model": "claude-haiku-4-5",
                "thinking": {"type": "enabled", "budget_tokens": 16384}},
}
```

Other provider settings in the final E0b code:

| Setting | E0a value | E0b value (final) |
|---|---|---|
| `max_tokens` (all tiers) | 32000 | **64000** |
| `timeout_seconds` | 600 | **1800** (30 min) |
| `max_retries` | 2 | **4** (exponential backoff `min(60, 2**attempt)`) |
| `stream` | False | **True** (SSE) |

The retry loop now catches both `requests.RequestException` and a new
`_RetriableStreamError` raised by `_consume_sse_stream` on
mid-stream `overloaded_error` / `rate_limit_error` / `api_error`
events. Retriable HTTP status codes include **529 (overloaded)** in
addition to the standard 429/500/502/503/504.

`M-mid` and `M-small` entries are kept for code-path completeness so
the `--models` flag accepts them syntactically, but only M-best is
validated for use in Stage 1 (see §8.3).

### 8.3 — Stage 2 dropped

Per the 2026-05-18 decision: Stage 2 (the +180 runs on M-mid +
M-small) is dropped from this project. Hypotheses H5, H6, H7 will not
be tested. See EVALUATION_PLAN.md Appendix E.2 for the full rationale.
Implications for this file:

- The §5 sanity-check protocol on M-small was **not executed**
  (Stage 2 is not running; no need to validate M-small).
- M-small's `budget_tokens: 16384` choice is preserved in the
  `TIER_CONFIG` dict above but is **historical record only** — no
  Stage-1 run uses M-small.
- §6's cost table has been re-anchored — see §8.4.

### 8.4 — Cost re-estimate (empirically anchored)

E0b's three-iteration 9-cell survey gives the actual per-lift cost
distribution for the final M-best configuration. Replace §6's table
with:

| Stage | Model | Runs | Per-lift mean | Per-lift range | Total |
|---|---|---:|---:|---:|---:|
| 1 | M-best (Opus 4.7, effort=high, streaming) | 90 | ~$1.00 | $0.40–$1.54 | **~$90** |

Per-lift wall clock: **mean 6–9 min**, range 2.7–38 min. Stage 1 total
wall clock: **~15 hours** (overnight-runnable). The 30-minute per-
request timeout is well above the maximum observed lift time.

§6 of the body is superseded by this table. Tokens per lift typically
fall in the 10k–30k output-token range (Opus 4.7's adaptive thinking
is verbose); thinking tokens are folded into `output_tokens` and
billed at the standard output rate.

### 8.5 — Lifter prompt iterated 3× during E0b

The system prompt (`DESIGN_LIFT_SYSTEM_PROMPT` in
`speceval/prompts.py`) was iterated three times during E0b based on
empirical Alloy parse failures on Opus 4.7 lifts. The three fixes
(permission-matrix syntax, F_NonEmptyUniverse fact, parenthesize-
implies-one) are documented in detail in EVALUATION_PLAN.md
Appendix E.4.3 and are now **part of the methodology**.

For this file's purpose: the model selection and request bodies above
are valid only in combination with the current `DESIGN_LIFT_SYSTEM_PROMPT`
(as of 2026-05-18). Replicating the experiment with an earlier
version of the prompt and the same model lineup would *not* reproduce
the 8/9 PARSE_OK headline. The prompt and the model selection are
co-pinned for Stage 1.

### 8.6 — What is canonically the "final M-best config"

For any future reader: the canonical M-best configuration for Stage 1
is the union of §8.1, §8.2, and §8.5. Sections 1–7 above are
historical (the pre-registered E0a selections) and should be read
only for audit-trail purposes — the operative choices are in this
revision.

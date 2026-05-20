"""speceval.providers.anthropic — minimal Claude client over raw HTTPS.

We deliberately do NOT depend on the `anthropic` SDK. Two reasons:
  1. Smaller dependency surface (just `requests`, which is everywhere).
  2. We use a tiny, well-defined slice of the API (Messages, single turn,
     no streaming, no tool use), so the SDK adds little value.

Reference: https://docs.anthropic.com/en/api/messages

E0b additions (2026-05-17): tier-aware request bodies for the AQS
evaluation. The three tiers (M-best, M-mid, M-small) are pinned in
`TIER_CONFIG` per `eval/MODEL_SELECTION.md` §4.1. See that document for
the rationale behind the adaptive-vs-manual thinking asymmetry and the
per-tier prices used by `TIER_PRICES`.
"""

from __future__ import annotations

import copy
import json
import os
import time
from dataclasses import dataclass, field

import requests

from speceval.providers import Provider


ANTHROPIC_MESSAGES_ENDPOINT = "https://api.anthropic.com/v1/messages"
ANTHROPIC_API_VERSION = "2023-06-01"


# ---------------------------------------------------------------------------
# Tier configuration — source of truth: eval/MODEL_SELECTION.md §4.1
# ---------------------------------------------------------------------------

#: Per-tier request-body fragments. The lifter merges these into the
#: fixed-shape body { model, max_tokens, system, messages, ... }. Manual
#: mode (M-small) intentionally has no `output_config` — `effort` belongs
#: to adaptive thinking and is rejected in manual mode.
#:
#: E0b 2026-05-18 revision — M-best switched from `claude-opus-4-7`
#: (adaptive thinking) to `claude-opus-4-6` (no thinking). Rationale:
#: Opus 4.7's adaptive thinking with `effort: max` consumed 20+ min of
#: wall-clock per lift on A-L2 with no response (non-streaming HTTP
#: stalls past ~32 k output tokens). Dropping to `effort: high` still
#: hung at 13+ min. Anthropic's own docs say non-streaming is
#: unreliable for max_tokens > 21,333 and recommend SSE streaming —
#: but rather than add a streaming code path to providers/anthropic.py,
#: we fall back to Opus 4.6 with no thinking, which is the known-good
#: config Leon ran successfully on the banking baseline pre-E0b.
#: This is a real methodology drift (M-best is no longer "frontier
#: model with extended thinking at maximum") and must be flagged in
#: the EVALUATION_PLAN write-up — see eval/MODEL_SELECTION.md for the
#: full decision trail.
#:
#: M-mid (Sonnet 4.6 + adaptive + effort=high) and M-small (Haiku 4.5
#: + manual budget=16384) are unchanged. M-mid's request returns at
#: ~8 min wall clock (with max_tokens=64000) — viable for Stage 2.
TIER_CONFIG: dict[str, dict] = {
    # E0b 2026-05-18 final: SSE streaming is now in place, so the
    # non-streaming HTTP reliability ceiling no longer applies.
    # M-best returns to the original Phase E0a choice: Opus 4.7 with
    # adaptive thinking. effort=high (not max) — empirically max
    # produces unbounded thinking on rich inputs even with streaming,
    # whereas high completes in 5-15 min wall clock.
    "M-best": {
        "model": "claude-opus-4-7",
        "thinking": {"type": "adaptive", "display": "omitted"},
        "output_config": {"effort": "high"},
    },
    # Stage 2 re-enabled 2026-05-19 — M-mid switched from
    # adaptive(effort=high) → manual(budget_tokens=16384). Why:
    # adaptive at effort=high on the 3-iteration lifter prompt
    # consumed all 64000 output tokens on thinking alone, leaving
    # zero for text (live failure on A-L1/M-mid/run_01 2026-05-19:
    # output_tokens=63999, stop_reason=max_tokens, no text emitted).
    # Sonnet 4.6's max-output cap is 64k — we cannot raise
    # max_tokens further. Manual mode with budget_tokens=16384
    # gives a hard server-side cap on thinking, guaranteeing
    # ≥48k headroom for text. Matches M-small's shape exactly,
    # isolating model as the only variable between the two
    # smaller tiers. See [[project_eval_stage2_plan]] for the
    # methodology decision trail.
    "M-mid": {
        "model": "claude-sonnet-4-6",
        "thinking": {"type": "enabled", "budget_tokens": 16384},
    },
    # M-small budget_tokens raised 16384 → 32768 on 2026-05-19 after
    # Stage 2-A sanity check showed Haiku at 16k thinking only parsed
    # 3/9 cells, with several failures looking like relational-typing
    # mistakes (joining Task.team where team is on a different sig)
    # — i.e. reasoning errors plausibly fixable by more thinking time.
    # 32768 leaves 31232 tokens of text headroom (still ~3-6× more
    # than a typical Alloy lift emits). Haiku 4.5's max-output cap is
    # 64k so we have room. Pre-experiment hypothesis: 5-6/9 parse
    # rate (up from 3/9).
    "M-small": {
        "model": "claude-haiku-4-5",
        "thinking": {"type": "enabled", "budget_tokens": 32768},
    },
}

#: Per-tier prices, in USD per million tokens. (input, output).
#: Thinking tokens are billed as output tokens — no separate line item.
TIER_PRICES: dict[str, tuple[float, float]] = {
    "M-best":  (5.0, 25.0),
    "M-mid":   (3.0, 15.0),
    "M-small": (1.0, 5.0),
}


def tier_thinking_budget(tier: str) -> int | None:
    """Return the `budget_tokens` for manual tiers, or `None` for adaptive
    / no-thinking tiers."""
    cfg = TIER_CONFIG[tier]
    thinking = cfg.get("thinking", {})
    if thinking.get("type") == "enabled":
        return int(thinking.get("budget_tokens", 0))
    return None


def tier_thinking_enabled(tier: str) -> bool:
    """True iff the tier sends a `thinking` field (adaptive or manual)."""
    return "thinking" in TIER_CONFIG[tier]


def estimate_cost_usd(tier: str, input_tokens: int, output_tokens: int) -> float:
    """Cost in USD for a single request, given the tier and observed usage."""
    in_price, out_price = TIER_PRICES[tier]
    return (input_tokens / 1_000_000.0) * in_price + (
        output_tokens / 1_000_000.0
    ) * out_price


# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

@dataclass
class CompleteResult:
    """Return shape of `complete_with_usage`.

    `text` is the same string `complete(...)` returns; `input_tokens` and
    `output_tokens` come from the Messages-API `usage` block. Anthropic
    folds thinking tokens into `output_tokens` (see MODEL_SELECTION.md
    §4.5 — there is no separate `thinking_tokens` field in usage), so
    `output_tokens` is the billed total used for cost calculations.
    """
    text: str
    input_tokens: int
    output_tokens: int


@dataclass
class AnthropicProvider(Provider):
    """Single-turn Messages API client. Stateless.

    The provider is tier-parameterised: `tier` selects the model string,
    thinking mode, and optional `output_config` fragment to send. The
    default is "M-best" so existing callers (legacy `lifter.py`) get the
    strongest configuration without code change.
    """

    api_key: str
    tier: str = "M-best"
    model: str = ""               # auto-derived from tier if empty
    timeout_seconds: int = 1800   # E0b 2026-05-18: 600s wasn't enough for Sonnet adaptive at effort=high (read timeout × 3 retries). 1800s (30 min) covers the observed 14-min Opus 4.7 lift on A-L2 with headroom.
    max_retries: int = 2
    name: str = "anthropic"

    # E0b 2026-05-17: default max_tokens raised 32000 → 64000 after the
    # first A-L2 run saw Opus 4.7 at effort=high consume the full 32k
    # output budget on thinking alone and hit stop_reason=max_tokens
    # before writing any text. 64k fits all three tiers' max-output
    # caps (Opus 4.7: 128k, Sonnet 4.6 / Haiku 4.5: 64k).

    def __post_init__(self) -> None:
        if self.tier not in TIER_CONFIG:
            raise ValueError(
                f"Unknown tier {self.tier!r}; expected one of "
                f"{sorted(TIER_CONFIG)}"
            )
        if not self.model:
            self.model = TIER_CONFIG[self.tier]["model"]

    @classmethod
    def from_env(
        cls,
        *,
        tier: str = "M-best",
        model: str | None = None,
    ) -> "AnthropicProvider":
        """Build from environment variables.

        Reads ANTHROPIC_API_KEY (required). The `tier` selects the
        per-tier request shape from `TIER_CONFIG` (the source of truth
        for both model string and thinking config). An explicit `model`
        argument overrides the tier-derived model string but keeps the
        tier's thinking/output-config — useful for ad-hoc experiments,
        not used in the E0b evaluation path.

        Also tries to load `.env` from the current working directory
        before consulting os.environ, so users don't have to `source .env`
        first.
        """
        _load_dotenv_into_environ()
        api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
        if not api_key:
            raise RuntimeError(
                "ANTHROPIC_API_KEY is not set. Put it in `.env` or export it."
            )
        # Tier is the authoritative model selector for E0b. The legacy
        # SPECEVAL_LLM_MODEL env var is intentionally NOT honoured here:
        # otherwise an old `.env` (pre-E0b) silently overrides the tier
        # and the wrong model gets billed. Pass `model=` explicitly if
        # you need to override.
        return cls(api_key=api_key, tier=tier, model=model or "")

    # ----------------------------------------------------------------- API

    def complete(self, *, system: str, user: str, max_tokens: int = 64000) -> str:
        """Send a single user message and return the model's text reply.

        Thin wrapper around `complete_with_usage` for legacy callers that
        don't need the usage block. Default `max_tokens` bumped to 32000
        in E0b to make room for adaptive thinking at effort=max.
        """
        return self.complete_with_usage(
            system=system, user=user, max_tokens=max_tokens
        ).text

    def complete_with_usage(
        self, *, system: str, user: str, max_tokens: int = 64000
    ) -> CompleteResult:
        """Send a single user message and return text + usage tokens.

        E0b 2026-05-18: switched to Server-Sent Events streaming. This
        is the path Anthropic recommends for `max_tokens > 21,333` and
        for adaptive-thinking requests on Opus 4.7 — the non-streaming
        path stalls connection-wise on long thinking phases and was
        the root cause of the M-best hangs documented in
        [[project_eval_e0b_complete]]. The SSE protocol keeps the
        connection alive with continuous events and surfaces partial
        progress, so connection-idle timeouts don't fire mid-thinking.

        Returns a `CompleteResult` with `input_tokens` and
        `output_tokens` aggregated from `message_start.message.usage`
        plus `message_delta.usage` (the final delta carries the
        cumulative output_tokens).
        """
        tier_cfg = TIER_CONFIG[self.tier]
        body: dict = {
            "model": self.model or tier_cfg["model"],
            "max_tokens": max_tokens,
            "stream": True,
            "system": system,
            "messages": [{"role": "user", "content": user}],
        }
        # `thinking` and `output_config` are tier-conditional. M-best (Opus
        # 4.6 fallback) sends neither — it's a plain Messages request.
        if "thinking" in tier_cfg:
            body["thinking"] = copy.deepcopy(tier_cfg["thinking"])
        if "output_config" in tier_cfg:
            body["output_config"] = copy.deepcopy(tier_cfg["output_config"])
        headers = {
            "x-api-key": self.api_key,
            "anthropic-version": ANTHROPIC_API_VERSION,
            "content-type": "application/json",
            "accept": "text/event-stream",
        }

        last_err: Exception | None = None
        # Bump retries for the streaming path — Anthropic surfaces
        # transient overloaded_error / rate_limit_error events in-stream,
        # which we want to retry with exponential backoff rather than
        # propagate as hard failures.
        max_retries = max(self.max_retries, 4)
        for attempt in range(max_retries + 1):
            try:
                with requests.post(
                    ANTHROPIC_MESSAGES_ENDPOINT,
                    headers=headers,
                    json=body,
                    timeout=self.timeout_seconds,
                    stream=True,
                ) as resp:
                    if resp.status_code != 200:
                        retriable = resp.status_code in (429, 500, 502, 503, 504, 529)
                        if retriable and attempt < max_retries:
                            backoff = min(60, 2 ** attempt)
                            time.sleep(backoff)
                            continue
                        raise RuntimeError(
                            f"Anthropic API error {resp.status_code}: {resp.text[:500]}"
                        )
                    return _consume_sse_stream(resp)
            except requests.RequestException as e:
                last_err = e
                if attempt < max_retries:
                    time.sleep(min(60, 2 ** attempt))
                    continue
                raise RuntimeError(
                    f"Anthropic API network error after {attempt + 1} attempts: {e}"
                )
            except _RetriableStreamError as e:
                last_err = e
                if attempt < max_retries:
                    backoff = min(60, 2 ** attempt)
                    print(
                        f"[anthropic] {e}; retrying in {backoff}s "
                        f"(attempt {attempt + 1}/{max_retries})",
                        flush=True,
                    )
                    time.sleep(backoff)
                    continue
                raise RuntimeError(
                    f"Anthropic streaming retriable error after "
                    f"{attempt + 1} attempts: {e}"
                )

        # Defensive — loop should always return or raise.
        raise RuntimeError(f"Anthropic API failed: {last_err}")


class _RetriableStreamError(Exception):
    """Stream-level error from Anthropic that should be retried with
    backoff (overloaded_error, rate_limit_error, server_error). The
    retry loop in `complete_with_usage` catches this distinct from
    `requests.RequestException` so we can apply a longer backoff for
    overloaded-tier conditions."""


#: Stream `error` event types Anthropic returns that are transient
#: capacity / rate-limit conditions. See https://docs.anthropic.com/en/api/errors
#: — `overloaded_error` (529-equivalent), `rate_limit_error` (429),
#: `api_error` (5xx). Anything else is treated as a hard failure.
_RETRIABLE_STREAM_ERROR_TYPES = {
    "overloaded_error",
    "rate_limit_error",
    "api_error",
}


def _consume_sse_stream(resp) -> CompleteResult:
    """Parse a streaming Messages-API response into a CompleteResult.

    Anthropic's SSE protocol for `stream: true`:

      event: message_start
      data: {"type":"message_start","message":{"id":"...","usage":{...},...}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text"|"thinking"|"redacted_thinking",...}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"..."}}
      (also: thinking_delta, signature_delta for thinking blocks)

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":N}}

      event: message_stop
      data: {"type":"message_stop"}

      event: ping  (periodic, ignore)

    We aggregate text_delta strings across all text blocks (thinking is
    consumed but discarded for the lifter's two-fenced-block protocol),
    pull `input_tokens` from `message_start.message.usage`, and
    `output_tokens` from the final `message_delta.usage` (cumulative).
    """
    text_parts: list[str] = []
    block_types: dict[int, str] = {}     # index → "text" | "thinking" | ...
    input_tokens = 0
    output_tokens = 0
    stop_reason: str | None = None

    for raw_line in resp.iter_lines(decode_unicode=True):
        if raw_line is None:
            continue
        if not raw_line:
            continue   # blank line between events
        if not raw_line.startswith("data:"):
            continue   # `event: ...` lines are advisory; data has the type
        payload_str = raw_line[len("data:"):].strip()
        if not payload_str:
            continue
        try:
            ev = json.loads(payload_str)
        except json.JSONDecodeError:
            continue
        etype = ev.get("type")
        if etype == "message_start":
            usage = (ev.get("message") or {}).get("usage") or {}
            input_tokens = int(usage.get("input_tokens", 0) or 0)
            output_tokens = int(usage.get("output_tokens", 0) or 0)
        elif etype == "content_block_start":
            idx = ev.get("index", -1)
            block = ev.get("content_block") or {}
            block_types[idx] = str(block.get("type", "text"))
        elif etype == "content_block_delta":
            idx = ev.get("index", -1)
            delta = ev.get("delta") or {}
            dtype = delta.get("type")
            if dtype == "text_delta" and block_types.get(idx) == "text":
                text_parts.append(delta.get("text", ""))
            # thinking_delta / signature_delta deliberately ignored —
            # we don't surface thinking; usage tracking is enough.
        elif etype == "message_delta":
            delta = ev.get("delta") or {}
            usage = ev.get("usage") or {}
            if "output_tokens" in usage:
                output_tokens = int(usage["output_tokens"] or 0)
            if "input_tokens" in usage:
                input_tokens = int(usage["input_tokens"] or 0)
            if "stop_reason" in delta:
                stop_reason = delta["stop_reason"]
        elif etype == "message_stop":
            break
        elif etype == "error":
            err = ev.get("error") or {}
            err_type = str(err.get("type", "?"))
            err_msg  = str(err.get("message", ""))
            if err_type in _RETRIABLE_STREAM_ERROR_TYPES:
                raise _RetriableStreamError(
                    f"stream {err_type}: {err_msg}"
                )
            raise RuntimeError(
                f"Anthropic stream error: {err_type} — {err_msg}"
            )
        # ignore ping, content_block_stop, unknown

    text = "".join(text_parts).strip()
    if not text:
        if stop_reason == "max_tokens":
            raise RuntimeError(
                f"Anthropic streaming hit max_tokens before producing any "
                f"text (input_tokens={input_tokens}, output_tokens={output_tokens}). "
                f"Bump max_tokens so adaptive thinking has room for both "
                f"thinking AND the text reply."
            )
        raise RuntimeError(
            f"Anthropic streaming returned no text blocks "
            f"(stop_reason={stop_reason}, input_tokens={input_tokens}, "
            f"output_tokens={output_tokens})."
        )
    return CompleteResult(
        text=text,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
    )


def _extract_text(payload: dict) -> str:
    """Pull the text from a Messages API response.

    Response shape (simplified):
        { "content": [ { "type": "text", "text": "..." }, ... ],
          "stop_reason": "end_turn" | "max_tokens" | ...,
          "usage": { "input_tokens": N, "output_tokens": M, ... } }

    Adaptive-thinking responses may interleave `thinking` /
    `redacted_thinking` blocks; we only concatenate the `text` blocks
    since the lifter's protocol is two fenced-code blocks inside the
    final text reply.

    On `stop_reason: "max_tokens"` with no text generated, raises a
    targeted error so the caller knows the thinking budget ate the
    output cap — bump `max_tokens` in that case rather than chasing a
    parse error downstream.
    """
    content = payload.get("content")
    if not isinstance(content, list) or not content:
        raise RuntimeError(f"Anthropic API returned no content: {payload}")
    parts = [
        block.get("text", "")
        for block in content
        if isinstance(block, dict) and block.get("type") == "text"
    ]
    text = "".join(parts).strip()
    if not text:
        stop_reason = payload.get("stop_reason")
        usage = payload.get("usage") or {}
        if stop_reason == "max_tokens":
            raise RuntimeError(
                f"Anthropic API hit max_tokens before producing any text "
                f"(usage={usage}). Bump max_tokens in the provider so "
                f"adaptive thinking has room for both thinking AND the "
                f"text reply."
            )
        raise RuntimeError(
            f"Anthropic API returned no text blocks "
            f"(stop_reason={stop_reason}, usage={usage})."
        )
    return text


def _load_dotenv_into_environ() -> None:
    """Tiny .env loader — KEY=VALUE per line, no quoting tricks.

    We avoid the python-dotenv dependency. If `.env` doesn't exist, this
    silently does nothing. Existing environ values are NOT overwritten.
    """
    from pathlib import Path

    candidates = [
        Path.cwd() / ".env",
        Path(__file__).resolve().parent.parent.parent / ".env",
    ]
    for env_path in candidates:
        if not env_path.exists():
            continue
        try:
            for raw in env_path.read_text(encoding="utf-8").splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key and key not in os.environ:
                    os.environ[key] = value
        except OSError:
            pass
        # First match wins.
        return

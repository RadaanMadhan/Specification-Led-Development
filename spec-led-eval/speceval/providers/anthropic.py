"""speceval.providers.anthropic — minimal Claude client over raw HTTPS.

We deliberately do NOT depend on the `anthropic` SDK. Two reasons:
  1. Smaller dependency surface (just `requests`, which is everywhere).
  2. We use a tiny, well-defined slice of the API (Messages, single turn,
     no streaming, no tool use), so the SDK adds little value.

Reference: https://docs.anthropic.com/en/api/messages
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass

import requests

from speceval.providers import Provider


ANTHROPIC_MESSAGES_ENDPOINT = "https://api.anthropic.com/v1/messages"
ANTHROPIC_API_VERSION = "2023-06-01"
DEFAULT_MODEL = "claude-opus-4-6"


@dataclass
class AnthropicProvider(Provider):
    """Single-turn Messages API client. Stateless."""

    api_key: str
    model: str = DEFAULT_MODEL
    timeout_seconds: int = 120
    max_retries: int = 2
    name: str = "anthropic"

    @classmethod
    def from_env(cls, *, model: str | None = None) -> "AnthropicProvider":
        """Build from environment variables.

        Reads ANTHROPIC_API_KEY (required) and SPECEVAL_LLM_MODEL (optional).
        Also tries to load `.env` from the current working directory before
        consulting os.environ, so users don't have to `source .env` first.
        """
        _load_dotenv_into_environ()
        api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
        if not api_key:
            raise RuntimeError(
                "ANTHROPIC_API_KEY is not set. Put it in `.env` or export it."
            )
        chosen_model = (
            model
            or os.environ.get("SPECEVAL_LLM_MODEL", "").strip()
            or DEFAULT_MODEL
        )
        return cls(api_key=api_key, model=chosen_model)

    def complete(self, *, system: str, user: str, max_tokens: int = 4096) -> str:
        """Send a single user message and return the model's text reply."""
        body = {
            "model": self.model,
            "max_tokens": max_tokens,
            "system": system,
            "messages": [{"role": "user", "content": user}],
        }
        headers = {
            "x-api-key": self.api_key,
            "anthropic-version": ANTHROPIC_API_VERSION,
            "content-type": "application/json",
        }

        last_err: Exception | None = None
        for attempt in range(self.max_retries + 1):
            try:
                resp = requests.post(
                    ANTHROPIC_MESSAGES_ENDPOINT,
                    headers=headers,
                    json=body,
                    timeout=self.timeout_seconds,
                )
            except requests.RequestException as e:
                last_err = e
                if attempt < self.max_retries:
                    time.sleep(1.5 * (attempt + 1))
                    continue
                raise RuntimeError(
                    f"Anthropic API network error after {attempt + 1} attempts: {e}"
                )

            if resp.status_code == 200:
                payload = resp.json()
                return _extract_text(payload)

            # 429 (rate limit) or 5xx — retry; 4xx other — fail fast
            retriable = resp.status_code in (429, 500, 502, 503, 504)
            if retriable and attempt < self.max_retries:
                time.sleep(2 * (attempt + 1))
                continue
            raise RuntimeError(
                f"Anthropic API error {resp.status_code}: {resp.text[:500]}"
            )

        # Defensive — loop should always return or raise.
        raise RuntimeError(f"Anthropic API failed: {last_err}")


def _extract_text(payload: dict) -> str:
    """Pull the text from a Messages API response.

    Response shape (simplified):
        { "content": [ { "type": "text", "text": "..." }, ... ], ... }
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
        raise RuntimeError(f"Anthropic API returned empty text: {payload}")
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

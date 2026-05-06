"""LLM provider interface and adapters.

The lifter is provider-agnostic: it asks for `Provider.complete(...)` and
gets back text. Today we ship the Anthropic adapter; an Azure OpenAI
adapter slots in next to it without touching the lifter.
"""

from __future__ import annotations

from abc import ABC, abstractmethod


class Provider(ABC):
    """A minimal LLM-backend interface."""

    name: str = "abstract"
    model: str = "abstract"

    @abstractmethod
    def complete(self, *, system: str, user: str, max_tokens: int = 4096) -> str:
        """Send a single prompt and return the model's text response."""
        raise NotImplementedError

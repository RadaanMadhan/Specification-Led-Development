"""speceval.providers — LLM provider interface and adapters."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field


@dataclass
class CompletionResult:
    """Text response plus optional usage/timing metadata."""

    text: str
    input_tokens: int = 0
    output_tokens: int = 0
    model: str = ""
    stop_reason: str = ""
    extra: dict = field(default_factory=dict)


class Provider(ABC):
    """A minimal LLM-backend interface."""

    name: str = "abstract"
    model: str = "abstract"

    @abstractmethod
    def complete(self, *, system: str, user: str, max_tokens: int = 4096) -> str:
        """Send a single prompt and return the model's text response."""
        raise NotImplementedError

    def complete_with_usage(
        self, *, system: str, user: str, max_tokens: int = 4096
    ) -> CompletionResult:
        """Like complete(), but returns token usage metadata."""
        text = self.complete(system=system, user=user, max_tokens=max_tokens)
        return CompletionResult(text=text, model=self.model)

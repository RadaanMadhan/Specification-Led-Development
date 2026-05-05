import os
from abc import abstractmethod, ABC
import anthropic

class LLM(ABC):
    @abstractmethod
    def generate(self, prompt) -> str:
       ...

    @classmethod
    def init(cls, provider="anthropic"):
        # handle errors and implement the rest of the classes
        if provider == "anthropic":
            return AnthropicLLM
         

class AnthropicLLM(LLM):
    def __init__(self):
        self.model = os.getenv("ANTHROPIC_MODEL", "claude-opus-4-7")
        self.client = anthropic.Anthropic(
            api_key=os.getenv("ANTHROPIC_API_KEY")
        )
    # Need to test what are the best settings
    def generate(self, prompt) -> str:
        message = self.client.messages.create(
            model=self.model,
            max_tokens=1024,
            messages=[
                {"role": "user", "content": prompt}
            ],
        )

        block = message.content[0]
        if not isinstance(block, anthropic.types.TextBlock):
            raise ValueError(f"Expected TextBlock, got {type(block).__name__}")
        return block.text


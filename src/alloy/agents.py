from ..llm import LLM

# I will move this to a YAML file later
ALLOY_GENERATION_SYSTEM = (
    "You are an expert in Alloy formal specification language. "
    "Given a system design description, generate a complete Alloy model that "
    "captures the structure, relations, and constraints of the system. "
    "Output only valid Alloy code, no explanations."
)

ALLOY_TEST_SYSTEM = (
    "You are an expert in Alloy formal specification language. "
    "Given an Alloy model description and a set of KPIs/requirements, "
    "generate Alloy assertions (assert) and check commands that verify "
    "whether the model satisfies those requirements. "
    "Output only valid Alloy code, no explanations."
)

# This agent generates the Alloy description based on design from speckit
class AlloyGenerationAgent:
    def __init__(self, llm: LLM):
        self.llm = llm

    def generate(self, system_design: str) -> str:
        prompt = (
            f"System design:\n{system_design}\n\n"
            "Generate an Alloy model for the above system design."
        )
        return self.llm.generate(f"{ALLOY_GENERATION_SYSTEM}\n\n{prompt}")

# This agent generates Alloy test cases in the form of assertions 
class AlloyTestAgent:
    def __init__(self, llm: LLM):
        self.llm = llm

    def generate(self, alloy_description: str, kpis: str) -> str:
        prompt = (
            f"Alloy model:\n{alloy_description}\n\n"
            f"KPIs/Requirements:\n{kpis}\n\n"
            "Generate Alloy assertions and check commands that verify "
            "whether the model satisfies the above requirements."
            "Output only valid Alloy code, no explanations."
        )
        return self.llm.generate(f"{ALLOY_TEST_SYSTEM}\n\n{prompt}")

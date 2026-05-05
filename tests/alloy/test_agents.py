from dotenv import load_dotenv

load_dotenv()

from src.llm import LLM
from src.alloy.agents import AlloyGenerationAgent, AlloyTestAgent
from src.alloy.analyzer import AlloyAnalyzer

EXAMPLE_SYSTEM_DESIGN = """
A simple file system with the following properties:
- A file system contains a root directory.
- Directories can contain files and other directories.
- Each file and directory has exactly one parent directory, except the root.
- No directory can be its own ancestor (no cycles).
- File names within the same directory must be unique.
"""

EXAMPLE_KPIS = """
1. The root directory has no parent.
2. Every non-root directory has exactly one parent.
3. There are no cycles in the directory hierarchy.
4. A file cannot exist outside of a directory.
5. No two files in the same directory share the same name.
"""


def main():
    llm = LLM.init("anthropic")()

    # Generate Alloy model from system design
    gen_agent = AlloyGenerationAgent(llm)
    print("=== Generating Alloy Model ===\n")
    alloy_model = gen_agent.generate(EXAMPLE_SYSTEM_DESIGN)
    print(alloy_model)

    # Generate assertions from model + KPIs
    test_agent = AlloyTestAgent(llm)
    print("\n=== Generating Alloy Assertions ===\n")
    assertions = test_agent.generate(alloy_model, EXAMPLE_KPIS)
    print(assertions)

    # Combine model and assertions, then analyze
    full_model = alloy_model + "\n\n" + assertions
    analyzer = AlloyAnalyzer()
    print("\n=== Running Alloy Analyzer ===\n")
    result = analyzer.analyze(full_model)
    print(result.raw_output)

    if result.errors:
        print("\nErrors:")
        for error in result.errors:
            print(f"  - {error}")

    for cmd in result.commands:
        status = "PASS" if cmd.passed else "FAIL"
        print(f"  [{status}] {cmd.command}")

    if result.all_passed:
        print("\nAll checks passed.")
    else:
        print("\nSome checks failed or had errors.")


if __name__ == "__main__":
    main()

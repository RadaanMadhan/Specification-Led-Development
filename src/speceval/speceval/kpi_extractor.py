"""speceval.kpi_extractor — extract and manage Business KPIs from specs and prompts."""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class KPI:
    """A single Key Performance Indicator extracted from SpecKit or user prompt."""
    name: str                                    # e.g., "Audit Entry Immutability"
    category: str                                # e.g., "Data Integrity", "Success Rate"
    description: str                             # human-readable description
    formal_constraint: Optional[str] = None     # Alloy concept that enforces it
    measurement_strategy: Optional[str] = None   # how to measure/instrument it
    source: str = "speckit"                      # "speckit" or "user_prompt"
    source_location: Optional[str] = None        # e.g., "FR-001", "line X"
    status: str = "To be measured"               # "Fulfilled", "To be measured", or "Missing"
    matched_constraint: Optional[str] = None     # Matched Alloy predicate/fact name, if any

    def __hash__(self):
        """Hash on (name, category) for deduplication."""
        return hash((self.name, self.category))

    def __eq__(self, other):
        if not isinstance(other, KPI):
            return False
        return self.name == other.name and self.category == other.category

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return asdict(self)


@dataclass
class KPICollection:
    """Container for all extracted KPIs from a feature."""
    feature_id: str
    feature_name: Optional[str] = None
    speckit_kpis: list[KPI] = field(default_factory=list)
    user_prompt_kpis: list[KPI] = field(default_factory=list)

    @property
    def merged_kpis(self) -> list[KPI]:
        """Return deduplicated merged KPI list."""
        kpi_dict = {}
        
        # Prioritize speckit KPIs as they're more detailed
        for kpi in self.speckit_kpis:
            key = (kpi.name, kpi.category)
            kpi_dict[key] = kpi
        
        # Add user prompt KPIs only if not already present
        for kpi in self.user_prompt_kpis:
            key = (kpi.name, kpi.category)
            if key not in kpi_dict:
                kpi_dict[key] = kpi
        
        return sorted(list(kpi_dict.values()), key=lambda k: k.name)

    def to_dict(self) -> dict:
        """Serialize to dictionary for JSON output."""
        return {
            "feature_id": self.feature_id,
            "feature_name": self.feature_name,
            "metadata": {
                "total_speckit_kpis": len(self.speckit_kpis),
                "total_user_prompt_kpis": len(self.user_prompt_kpis),
                "total_unique_kpis": len(self.merged_kpis),
            },
            "kpis": [kpi.to_dict() for kpi in self.merged_kpis],
        }


class KPIExtractor:
    """Extract KPIs from SpecKit artefacts and user prompts."""

    @staticmethod
    def extract_from_spec_md(spec_md: str) -> list[KPI]:
        """Extract KPIs from 'Formal Requirements & Advanced KPI Mapping' table."""
        kpis = []

        # Look for the KPI mapping table section
        kpi_section_pattern = (
            r"##\s*Formal Requirements & Advanced KPI Mapping\s*\n"
            r"([\s\S]*?)(?=\n##|$)"
        )
        section_match = re.search(kpi_section_pattern, spec_md, re.IGNORECASE)
        if not section_match:
            return kpis

        section_text = section_match.group(1)

        # Extract table rows: | KPI Category | Specific Business Metric | ... |
        # Skip markdown header and separator rows
        lines = section_text.split('\n')
        in_table = False
        header_count = 0

        for line in lines:
            stripped = line.strip()
            
            # Skip empty lines
            if not stripped:
                continue
            
            # Detect table start
            if '|' not in line:
                continue
            
            # Skip separator rows (contain ---)
            if '---' in line:
                header_count += 1
                continue
            
            # Skip if this looks like a header (contains "KPI Category")
            if 'KPI Category' in line or 'Business Metric' in line:
                in_table = True
                continue
            
            if not in_table:
                continue
            
            # Parse table row
            cells = [cell.strip() for cell in line.split('|')]
            cells = [c for c in cells if c]  # Remove empty cells from edges
            
            if len(cells) >= 2:
                # Standard format: | Category | Metric | Constraint | Strategy |
                category = cells[0].strip('*_ ')
                metric_name = cells[1].strip('*_ ') if len(cells) > 1 else ""
                constraint = cells[2].strip('*_ ') if len(cells) > 2 else ""
                strategy = cells[3].strip('*_ ') if len(cells) > 3 else ""
                
                if metric_name and category:
                    kpi = KPI(
                        name=metric_name,
                        category=category,
                        description=metric_name,
                        formal_constraint=constraint if constraint else None,
                        measurement_strategy=strategy if strategy else None,
                        source="speckit",
                        source_location="spec.md: Formal Requirements & Advanced KPI Mapping",
                    )
                    kpis.append(kpi)

        return kpis

    @staticmethod
    def extract_from_user_prompt(prompt: str) -> list[KPI]:
        """Extract KPI keywords and patterns from user's natural language prompt."""
        kpis = []
        found_categories = {}

        # Mapping: (regex pattern, category name, typical measurement)
        patterns = [
            (r"(?:success|completion)\s+(?:rate|ratio|%)", "Success Rate", "Ratio of successful operations"),
            (r"(?:error|failure|fault)\s+(?:rate|ratio|%)", "Error Rate", "Ratio of failed operations"),
            (r"(?:availability|uptime|downtime)", "Availability", "System uptime percentage"),
            (r"(?:latency|response\s+time|delay)", "Latency", "Response time measurement"),
            (r"(?:throughput|requests?/s|operations?/s)", "Throughput", "Operations per second"),
            (r"(?:security|encryption|authentication|access\s+control)", "Security", "Security compliance metrics"),
            (r"(?:audit|compliance|retention|archival)", "Compliance", "Audit trail completeness"),
            (r"(?:propensity|prediction|predict|score|model)", "Propensity Score", "Predictive scoring"),
            (r"(?:reliability|fault\s+tolerance|redundancy)", "Reliability", "System reliability metrics"),
            (r"(?:scalability|capacity|load)", "Scalability", "Capacity and scaling metrics"),
            (r"(?:cost|budget|expense|pricing)", "Cost Efficiency", "Cost per operation"),
            (r"(?:user\s+satisfaction|nps|net\s+promoter|feedback)", "User Satisfaction", "User satisfaction score"),
            (r"(?:data\s+quality|accuracy|consistency|integrity)", "Data Quality", "Data quality metrics"),
            (r"(?:append\s+only|immutability|immutable)", "Data Immutability", "Append-only constraint"),
        ]

        for pattern, category, default_strategy in patterns:
            match = re.search(pattern, prompt, re.IGNORECASE)
            if match and category not in found_categories:
                # Extract nearby context for description
                start = max(0, match.start() - 50)
                end = min(len(prompt), match.end() + 50)
                context = prompt[start:end].strip()
                
                kpi = KPI(
                    name=category,
                    category=category,
                    description=context,
                    formal_constraint=None,
                    measurement_strategy=default_strategy,
                    source="user_prompt",
                    source_location="User-provided description",
                )
                kpis.append(kpi)
                found_categories[category] = True

        return kpis


class KPIMatcher:
    """Match KPIs against Alloy code to determine fulfillment status."""

    # KPI categories that are typically runtime metrics (not formal constraints)
    RUNTIME_ONLY_CATEGORIES = {
        "Success Rate",
        "Error Rate",
        "Throughput",
        "Latency",
        "Availability",
        "User Satisfaction",
        "Cost Efficiency",
    }

    def __init__(self, alloy_code: str):
        """Initialize matcher with Alloy source code."""
        self.alloy_code = alloy_code
        self.predicates = self._extract_predicates()
        self.assertions = self._extract_assertions()
        self.facts = self._extract_facts()

    def _extract_predicates(self) -> set[str]:
        """Extract all predicate names from Alloy code."""
        # Pattern: pred <name> or pred <name>[...]
        pattern = r"pred\s+(\w+)"
        return set(re.findall(pattern, self.alloy_code))

    def _extract_assertions(self) -> set[str]:
        """Extract all assertion names from Alloy code."""
        # Pattern: assert <name>
        pattern = r"assert\s+(\w+)"
        return set(re.findall(pattern, self.alloy_code))

    def _extract_facts(self) -> set[str]:
        """Extract all named fact names from Alloy code."""
        # Pattern: fact F_<name> or fact <name>
        pattern = r"fact\s+(\w+)"
        return set(re.findall(pattern, self.alloy_code))

    def _normalize_name(self, name: str) -> str:
        """Normalize name for comparison: lowercase, remove underscores/dashes."""
        return re.sub(r"[_\-\s]+", "", name).lower()

    def _compute_similarity(self, kpi_name: str, constraint_name: str) -> float:
        """Compute string similarity between KPI and constraint name (0-1)."""
        norm_kpi = self._normalize_name(kpi_name)
        norm_constraint = self._normalize_name(constraint_name)
        
        # Exact match (highest priority)
        if norm_kpi == norm_constraint:
            return 1.0
        
        # Check if one contains the other
        if norm_kpi in norm_constraint or norm_constraint in norm_kpi:
            return 0.7
        
        # Levenshtein-like distance (simple approximation)
        # Count matching trigrams
        kpi_trigrams = set(
            norm_kpi[i:i+3] for i in range(len(norm_kpi) - 2)
        )
        constraint_trigrams = set(
            norm_constraint[i:i+3] for i in range(len(norm_constraint) - 2)
        )
        
        if not (kpi_trigrams or constraint_trigrams):
            return 0.0
        
        overlap = len(kpi_trigrams & constraint_trigrams)
        total = len(kpi_trigrams | constraint_trigrams)
        return overlap / total if total > 0 else 0.0

    def _find_best_match(self, kpi_name: str) -> tuple[Optional[str], float]:
        """Find the best matching Alloy constraint for a KPI name.
        
        Returns (matched_name, similarity_score).
        """
        all_constraints = self.predicates | self.assertions | self.facts
        best_match = None
        best_score = 0.0
        
        for constraint in all_constraints:
            score = self._compute_similarity(kpi_name, constraint)
            if score > best_score:
                best_score = score
                best_match = constraint
        
        return best_match, best_score

    def match_and_tag_kpi(self, kpi: KPI) -> None:
        """Match a KPI against Alloy code and update its status."""
        # If it's a runtime-only KPI, mark as "To be measured"
        if kpi.category in self.RUNTIME_ONLY_CATEGORIES:
            kpi.status = "To be measured"
            return
        
        # Try to find a matching constraint
        matched_constraint, similarity = self._find_best_match(kpi.name)
        
        # High similarity threshold for "Fulfilled"
        if similarity >= 0.6 and matched_constraint:
            kpi.status = "Fulfilled"
            kpi.matched_constraint = matched_constraint
        elif similarity > 0.3 and matched_constraint:
            # Medium similarity: might be partial
            kpi.status = "To be measured"
            kpi.matched_constraint = matched_constraint
        else:
            # No meaningful match found
            kpi.status = "Missing"
            kpi.matched_constraint = None


def extract_all_kpis(
    feature_id: str,
    spec_md: str,
    user_prompt: str,
    feature_name: Optional[str] = None,
    alloy_code: Optional[str] = None,
) -> KPICollection:
    """Extract and merge KPIs from SpecKit spec.md and user prompt.
    
    If alloy_code is provided, matches KPIs against Alloy predicates/assertions
    and tags them as "Fulfilled", "To be measured", or "Missing".
    """
    extractor = KPIExtractor()
    
    speckit_kpis = extractor.extract_from_spec_md(spec_md)
    prompt_kpis = extractor.extract_from_user_prompt(user_prompt)
    
    collection = KPICollection(
        feature_id=feature_id,
        feature_name=feature_name,
        speckit_kpis=speckit_kpis,
        user_prompt_kpis=prompt_kpis,
    )
    
    # If Alloy code is provided, match KPIs against it
    if alloy_code:
        matcher = KPIMatcher(alloy_code)
        for kpi in collection.merged_kpis:
            matcher.match_and_tag_kpi(kpi)
    
    return collection


def save_kpis_json(
    collection: KPICollection,
    output_path: Path,
) -> None:
    """Write KPI collection to JSON file."""
    output_path.write_text(
        json.dumps(collection.to_dict(), indent=2),
        encoding="utf-8"
    )


if __name__ == "__main__":  # Quick manual test
    import sys
    if len(sys.argv) < 2:
        print("Usage: python kpi_extractor.py <spec.md_path> [user_prompt] [alloy_file]")
        sys.exit(1)
    
    spec_path = Path(sys.argv[1])
    user_prompt = sys.argv[2] if len(sys.argv) > 2 else ""
    alloy_path = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    
    spec_md = spec_path.read_text(encoding="utf-8")
    alloy_code = alloy_path.read_text(encoding="utf-8") if alloy_path else None
    
    collection = extract_all_kpis(
        feature_id=spec_path.parent.name,
        spec_md=spec_md,
        user_prompt=user_prompt,
        alloy_code=alloy_code,
    )
    
    print(f"Feature: {collection.feature_id}")
    print(f"SpecKit KPIs: {len(collection.speckit_kpis)}")
    print(f"User Prompt KPIs: {len(collection.user_prompt_kpis)}")
    print(f"Merged (unique) KPIs: {len(collection.merged_kpis)}")
    
    if alloy_code:
        fulfilled = sum(1 for k in collection.merged_kpis if k.status == "Fulfilled")
        to_measure = sum(1 for k in collection.merged_kpis if k.status == "To be measured")
        missing = sum(1 for k in collection.merged_kpis if k.status == "Missing")
        print(f"\nKPI Status (vs Alloy code):")
        print(f"  ✓ Fulfilled:      {fulfilled}")
        print(f"  ○ To be measured: {to_measure}")
        print(f"  ✗ Missing:        {missing}")
    
    print("\nMerged KPI List:")
    for kpi in collection.merged_kpis:
        status_icon = {"Fulfilled": "✓", "To be measured": "○", "Missing": "✗"}.get(
            kpi.status, "?"
        )
        print(f"  {status_icon} {kpi.category}: {kpi.name}")
        if kpi.matched_constraint:
            print(f"      → {kpi.matched_constraint}")

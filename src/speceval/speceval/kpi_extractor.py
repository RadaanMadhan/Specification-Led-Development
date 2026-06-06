"""speceval.kpi_extractor — extract and manage Business KPIs from specs and prompts."""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional


def classify_kpi(category: str, name: str, description: str) -> str:
    """Classify KPI as 'Technical' or 'Business' based on category, name, and description."""
    category_lower = category.lower()
    name_lower = name.lower()
    description_lower = description.lower()
    
    # 1. Broad category-based indicators
    technical_categories = {
        "success rate", "error rate", "availability", "latency", "throughput",
        "security", "reliability", "scalability", "data quality", "data immutability",
        "data integrity", "performance", "response time"
    }
    
    business_categories = {
        "compliance", "propensity score", "cost efficiency", "user satisfaction",
        "business goal", "revenue", "roi", "financial", "churn", "retention"
    }
    
    if any(tech in category_lower for tech in technical_categories):
        return "Technical"
    if any(bus in category_lower for bus in business_categories):
        return "Business"
        
    # 2. Keyword check on name and description
    tech_keywords = {
        "error", "failure", "success rate", "latency", "throughput", "response time",
        "uptime", "downtime", "availability", "performance", "database", "api",
        "security", "encryption", "auth", "immutable", "integrity", "correctness",
        "atomically", "gated", "circuit breaker", "traces", "cache", "network"
    }
    
    bus_keywords = {
        "cost", "revenue", "budget", "satisfaction", "nps", "compliance", "audit",
        "fraud", "churn", "conversion", "propensity", "user behavior", "risk profile",
        "marketing", "sales", "business", "regulatory", "billing", "pricing"
    }
    
    for kw in tech_keywords:
        if kw in name_lower or kw in description_lower:
            return "Technical"
            
    for kw in bus_keywords:
        if kw in name_lower or kw in description_lower:
            return "Business"
            
    # 3. Fallback based on typical attributes (e.g. if it has code patterns/Alloy terms, it's Technical)
    if any(p in name_lower or p in description_lower for p in ["sig ", "pred ", "fact ", "assert ", "relation", "cardinality"]):
        return "Technical"
        
    # Default fallback
    return "Business"


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
    kpi_type: str = "Business"                   # "Technical" or "Business"

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

    @property
    def merged_kpis(self) -> list[KPI]:
        """Return deduplicated merged KPI list."""
        kpi_dict = {}
        
        # Deduplicate speckit KPIs
        for kpi in self.speckit_kpis:
            key = (kpi.name, kpi.category)
            kpi_dict[key] = kpi
        
        return sorted(list(kpi_dict.values()), key=lambda k: k.name)

    def to_dict(self) -> dict:
        """Serialize to dictionary for JSON output."""
        return {
            "feature_id": self.feature_id,
            "feature_name": self.feature_name,
            "metadata": {
                "total_speckit_kpis": len(self.speckit_kpis),
                "total_unique_kpis": len(self.merged_kpis),
                "total_technical_kpis": sum(1 for k in self.merged_kpis if k.kpi_type == "Technical"),
                "total_business_kpis": sum(1 for k in self.merged_kpis if k.kpi_type == "Business"),
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
                    kpi_type = classify_kpi(category, metric_name, strategy)
                    kpi = KPI(
                        name=metric_name,
                        category=category,
                        description=metric_name,
                        formal_constraint=constraint if constraint else None,
                        measurement_strategy=strategy if strategy else None,
                        source="speckit",
                        source_location="spec.md: Formal Requirements & Advanced KPI Mapping",
                        kpi_type=kpi_type,
                    )
                    kpis.append(kpi)

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
        # Try direct vocabulary bridge match first (generated by SpecKit)
        all_constraints = list(self.predicates.keys()) + list(self.assertions.keys()) + list(self.facts.keys())
        if kpi.formal_constraint and kpi.formal_constraint.strip() in all_constraints:
            kpi.status = "Fulfilled"
            kpi.matched_constraint = kpi.formal_constraint.strip()
            return
            
        # If it's a runtime-only KPI and we didn't find an explicit logical bridge, mark as "To be measured"
        if kpi.category in self.RUNTIME_ONLY_CATEGORIES:
            kpi.status = "To be measured"
            return
        
        # Fall back to NLP similarity search
        matched_constraint, similarity = self._find_best_match(kpi.name)
        
        # High or medium similarity with a constraint means it is logically enforced
        if similarity >= 0.3 and matched_constraint:
            kpi.status = "Fulfilled"
            kpi.matched_constraint = matched_constraint
        else:
            # No meaningful match found
            kpi.status = "Missing"
            kpi.matched_constraint = None


def extract_all_kpis(
    feature_id: str,
    spec_md: str,
    feature_name: Optional[str] = None,
    alloy_code: Optional[str] = None,
) -> KPICollection:
    """Extract KPIs from SpecKit spec.md."""
    extractor = KPIExtractor()
    
    speckit_kpis = extractor.extract_from_spec_md(spec_md)
    
    collection = KPICollection(
        feature_id=feature_id,
        feature_name=feature_name,
        speckit_kpis=speckit_kpis,
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

#!/usr/bin/env python3
"""Generate a Markdown architecture SPEC from inventory and diagrams."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


COMPONENT_ORDER = [
    "state-sync",
    "workflow-engine",
    "agent-bridge",
    "workspace",
    "dispatch",
    "orchestrator",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--diagram-dir", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def fill_template(template: str, replacements: dict[str, str]) -> str:
    result = template
    for key, value in replacements.items():
        result = result.replace("{{" + key + "}}", value)
    return result


def load_inventory(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def component_index(inventory: dict) -> dict[str, dict]:
    return {item["name"]: item for item in inventory.get("architecture_components", [])}


def build_component_sections(inventory: dict) -> str:
    components = component_index(inventory)
    sections = []
    relationships = inventory.get("component_relationships", [])
    for name in COMPONENT_ORDER:
        component = components.get(name, {})
        inbound = [item["from"] for item in relationships if item["to"] == name]
        outbound = [item["to"] for item in relationships if item["from"] == name]
        sections.append(
            "\n".join(
                [
                    f"### {name}",
                    "",
                    component.get("summary", "Inferred architecture boundary."),
                    "",
                    f"- Paths: {', '.join(component.get('paths', [])[:6]) or 'not inferred'}",
                    f"- Member count: {component.get('member_count', 0)}",
                    f"- Primary languages: {', '.join(component.get('primary_languages', [])) or 'unknown'}",
                    f"- Depends on: {', '.join(outbound) or 'none observed'}",
                    f"- Used by: {', '.join(inbound) or 'none observed'}",
                ]
            )
        )
    return "\n\n".join(sections)


def build_interactions() -> str:
    return "\n".join(
        [
            "1. `dispatch` fetches candidate issues and computes the transition/profile to run.",
            "2. `orchestrator` coordinates retries, capacity, and dispatch scheduling.",
            "3. `workspace` provisions an isolated execution root for the chosen issue.",
            "4. `workflow-engine` loads runtime config and prompt templates for the run.",
            "5. `agent-bridge` starts the Codex app-server session and executes turns against the workspace.",
            "6. `state-sync` persists reusable session/config state so the loop survives reloads and re-entry.",
        ]
    )


def build_diagrams(diagram_dir: Path) -> str:
    lines = []
    for filename in sorted(path.name for path in diagram_dir.glob("*.mmd")):
        lines.append(f"- [{filename}]({filename})")
    return "\n".join(lines)


def build_drift_candidates(inventory: dict) -> str:
    missing_refs = [item for item in inventory.get("doc_references", []) if item["status"] == "missing"]
    if not missing_refs:
        return "- No missing documentation references were detected during the scan."
    lines = []
    for item in missing_refs[:8]:
        lines.append(
            f"- `{item['path']}:{item['line']}` references missing `{item['target']}`"
        )
    return "\n".join(lines)


def build_module_appendix(inventory: dict) -> str:
    lines = []
    for module in inventory.get("source_modules", [])[:20]:
        lines.append(f"- `{module['path']}`: {module['summary']}")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    inventory = load_inventory(Path(args.inventory))
    diagram_dir = Path(args.diagram_dir)
    output = Path(args.output)
    template = (Path(__file__).resolve().parent.parent / "assets" / "templates" / "SPEC.md.tmpl").read_text(encoding="utf-8")

    overview = (
        "This repository runs an issue-driven automation loop: tracker adapters surface work, "
        "the orchestrator decides when to dispatch, workspaces isolate execution, the workflow engine "
        "builds prompt/runtime context, the agent bridge talks to Codex, and state-sync stores keep the "
        "system resilient across retries and reloads."
    )

    content = fill_template(
        template,
        {
            "GENERATED_AT": datetime.now(timezone.utc).isoformat(),
            "OVERVIEW": overview,
            "ENTRYPOINTS": ", ".join(inventory.get("entrypoints", [])) or "none detected",
            "LANGUAGES": ", ".join(f"{item['name']} ({item['file_count']})" for item in inventory.get("languages", [])),
            "MODULE_COUNT": str(len(inventory.get("source_modules", []))),
            "COMPONENT_SECTIONS": build_component_sections(inventory),
            "INTERACTIONS": build_interactions(),
            "DIAGRAMS": build_diagrams(diagram_dir),
            "DRIFT_CANDIDATES": build_drift_candidates(inventory),
            "MODULE_APPENDIX": build_module_appendix(inventory),
        },
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content.strip() + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

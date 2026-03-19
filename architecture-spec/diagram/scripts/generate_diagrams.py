#!/usr/bin/env python3
"""Render Mermaid C4/UML diagrams from an architecture inventory."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


REQUIRED_COMPONENTS = [
    "orchestrator",
    "dispatch",
    "workspace",
    "agent-bridge",
    "workflow-engine",
    "state-sync",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True, help="Path to architecture inventory JSON")
    parser.add_argument("--output-dir", required=True, help="Directory for Mermaid outputs")
    return parser.parse_args()


def load_template(template_dir: Path, filename: str) -> str:
    return (template_dir / filename).read_text(encoding="utf-8")


def fill_template(template: str, replacements: dict[str, str]) -> str:
    result = template
    for key, value in replacements.items():
        result = result.replace("{{" + key + "}}", value)
    return result


def component_map(inventory: dict) -> dict[str, dict]:
    return {item["name"]: item for item in inventory.get("architecture_components", [])}


def render_container_lines(components: dict[str, dict]) -> str:
    lines = []
    for name in REQUIRED_COMPONENTS:
        component = components.get(name, {"summary": "Inferred architecture boundary."})
        alias = "container_" + name.replace("-", "_")
        label = name
        technology = ", ".join(component.get("primary_languages", [])[:2]) or "mixed"
        lines.append(f'  Container({alias}, "{label}", "{technology}", "{component["summary"]}")')
    return "\n".join(lines)


def render_component_lines(components: dict[str, dict]) -> str:
    lines = []
    for name in REQUIRED_COMPONENTS:
        component = components.get(name, {"summary": "Inferred architecture boundary.", "member_count": 0})
        alias = "component_" + name.replace("-", "_")
        detail = f'{component["summary"]} Members: {component.get("member_count", 0)}.'
        lines.append(f'  Component({alias}, "{name}", "architecture component", "{detail}")')
    return "\n".join(lines)


def render_relationship_lines(inventory: dict) -> str:
    declared = {(item["from"], item["to"]): item["strength"] for item in inventory.get("component_relationships", [])}
    defaults = [
        ("orchestrator", "dispatch", "schedules and coordinates"),
        ("orchestrator", "workspace", "allocates workspaces"),
        ("orchestrator", "agent-bridge", "runs agent turns"),
        ("dispatch", "workflow-engine", "uses transition/profile policy"),
        ("dispatch", "state-sync", "reads pending transitions"),
        ("agent-bridge", "workflow-engine", "renders prompts"),
        ("agent-bridge", "state-sync", "records session updates"),
        ("workspace", "agent-bridge", "provides execution roots"),
    ]
    lines = []
    for src, dst, label in defaults:
        strength = declared.get((src, dst))
        suffix = f" (observed imports: {strength})" if strength else ""
        lines.append(
            f'Rel(component_{src.replace("-", "_")}, component_{dst.replace("-", "_")}, "{label}{suffix}")'
        )
    return "\n".join(lines)


def render_class_map(inventory: dict) -> tuple[str, str]:
    modules = inventory.get("source_modules", [])[:18]
    classes = []
    dependencies = []
    id_to_name = {item["id"]: item["name"] for item in inventory.get("source_modules", [])}
    for module in modules:
        alias = module["id"].replace(".", "_").replace("-", "_")
        classes.append(f'class {alias}["{module["name"]}\\n{module["path"]}"]')
    module_ids = {item["id"] for item in modules}
    for rel in inventory.get("source_relationships", []):
        if rel["from"] in module_ids and rel["to"] in module_ids:
            dependencies.append(
                f'{rel["from"].replace(".", "_").replace("-", "_")} --> {rel["to"].replace(".", "_").replace("-", "_")} : imports'
            )
    return "\n".join(classes), "\n".join(dependencies)


def main() -> int:
    args = parse_args()
    inventory = json.loads(Path(args.inventory).read_text(encoding="utf-8"))
    output_dir = Path(args.output_dir)
    template_dir = Path(__file__).resolve().parent.parent / "assets" / "templates"
    output_dir.mkdir(parents=True, exist_ok=True)

    components = component_map(inventory)
    classes, dependencies = render_class_map(inventory)

    files = {
        "l1-system-context.mmd": fill_template(
            load_template(template_dir, "l1-system-context.mmd.tmpl"),
            {
                "TITLE": "L1 System Context",
                "SYSTEM_SUMMARY": "Polls tracker work, manages issue workspaces, and runs Codex-backed execution loops.",
            },
        ),
        "l2-container-view.mmd": fill_template(
            load_template(template_dir, "l2-container-view.mmd.tmpl"),
            {
                "TITLE": "L2 Container View",
                "CONTAINERS": render_container_lines(components),
            },
        ),
        "l3-component-view.mmd": fill_template(
            load_template(template_dir, "l3-component-view.mmd.tmpl"),
            {
                "TITLE": "L3 Component View",
                "COMPONENTS": render_component_lines(components),
                "RELATIONSHIPS": render_relationship_lines(inventory),
            },
        ),
        "l4-code-map.mmd": fill_template(
            load_template(template_dir, "l4-code-map.mmd.tmpl"),
            {
                "TITLE": "L4 Code Map",
                "CLASSES": classes,
                "DEPENDENCIES": dependencies,
            },
        ),
        "dispatch-sequence.mmd": fill_template(
            load_template(template_dir, "dispatch-sequence.mmd.tmpl"),
            {"TITLE": "Dispatch Sequence"},
        ),
    }

    for filename, content in files.items():
        (output_dir / filename).write_text(content.strip() + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

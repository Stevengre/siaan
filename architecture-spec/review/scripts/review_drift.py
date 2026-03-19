#!/usr/bin/env python3
"""Review architecture drift between a generated SPEC and the current repository."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


COMPONENT_NAMES = [
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
    parser.add_argument("--spec", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def markdown_links(text: str) -> list[str]:
    return re.findall(r"\[[^\]]+\]\(([^)]+)\)", text)


def main() -> int:
    args = parse_args()
    inventory = json.loads(Path(args.inventory).read_text(encoding="utf-8"))
    spec_path = Path(args.spec)
    spec_text = spec_path.read_text(encoding="utf-8")
    findings = {"high": [], "medium": [], "low": []}

    for component in COMPONENT_NAMES:
        if component not in spec_text:
            findings["high"].append(
                f"- Missing component coverage: `{component}` does not appear in `{spec_path.as_posix()}`."
            )

    for item in inventory.get("doc_references", []):
        if item["status"] == "missing":
            findings["medium"].append(
                f"- Broken repo doc reference: `{item['path']}:{item['line']}` points to missing `{item['target']}`."
            )

    for link in markdown_links(spec_text):
        if link.startswith(("http://", "https://", "#")):
            continue
        target = (spec_path.parent / link.split("#", 1)[0]).resolve()
        if not target.exists():
            findings["medium"].append(
                f"- Broken SPEC link: `{spec_path.as_posix()}` references missing `{link}`."
            )

    if not any(findings.values()):
        findings["low"].append("- No architecture drift detected.")

    lines = ["# Architecture Drift Review", ""]
    for severity in ["high", "medium", "low"]:
        lines.append(f"## {severity.capitalize()}")
        lines.append("")
        if findings[severity]:
            lines.extend(findings[severity])
        else:
            lines.append("- None.")
        lines.append("")

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

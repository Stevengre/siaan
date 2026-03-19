#!/usr/bin/env python3
"""Generate a portable architecture inventory for an arbitrary repository."""

from __future__ import annotations

import argparse
import json
import os
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Tuple


IGNORE_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".idea",
    ".vscode",
    "node_modules",
    ".next",
    ".turbo",
    ".venv",
    "venv",
    "__pycache__",
    "_build",
    "deps",
    "dist",
    "build",
    "coverage",
}

IGNORED_PREFIXES = (
    ".claude/",
    ".codex/",
    "architecture-spec/",
)

CODE_EXTENSIONS = {
    ".ex": "elixir",
    ".exs": "elixir",
    ".py": "python",
    ".js": "javascript",
    ".jsx": "javascript",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".go": "go",
    ".rb": "ruby",
    ".rs": "rust",
    ".java": "java",
    ".kt": "kotlin",
    ".swift": "swift",
}

DOC_EXTENSIONS = {".md", ".markdown", ".mdx", ".rst", ".txt"}

ARCH_RULES = [
    (
        "orchestrator",
        "Coordinates polling, dispatch, retries, and session lifecycle decisions.",
        ["orchestrator", "status_dashboard", "observability", "dashboard_live"],
    ),
    (
        "dispatch",
        "Translates tracker state into execution transitions and routes work between adapters.",
        ["dispatch", "tracker", "github/adapter", "linear/adapter", "local/adapter"],
    ),
    (
        "workspace",
        "Creates, validates, and cleans isolated issue workspaces across local and SSH workers.",
        ["workspace", "path_safety", "ssh", "workspace.before_remove"],
    ),
    (
        "agent-bridge",
        "Bridges repository workspaces to Codex app-server sessions and dynamic tools.",
        ["agent_runner", "codex", "dynamic_tool", "app_server", "prompt_builder"],
    ),
    (
        "workflow-engine",
        "Loads workflow/runtime configuration and materializes prompt contracts for each issue.",
        ["workflow", "runtime_config", "runtime_file", "prompt_builder", "config/schema"],
    ),
    (
        "state-sync",
        "Caches runtime state, issue sessions, and last-known-good config for resilient orchestration.",
        ["store", "session_stats", "runtime_source", "runtime_config_store", "memory"],
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="Repository root to scan")
    parser.add_argument("--output", required=True, help="Output inventory JSON path")
    return parser.parse_args()


def iter_files(root: Path) -> Iterable[Path]:
    for current_root, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]
        base = Path(current_root)
        for filename in files:
            yield base / filename


def relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def language_for(path: Path) -> str | None:
    return CODE_EXTENSIONS.get(path.suffix.lower())


def should_scan_path(path_str: str) -> bool:
    return not any(path_str == prefix[:-1] or path_str.startswith(prefix) for prefix in IGNORED_PREFIXES)


def include_code_file(path_str: str) -> bool:
    if not should_scan_path(path_str):
        return False
    if "/test/" in f"/{path_str}/" or path_str.endswith("_test.exs"):
        return False
    significant_dirs = ("/lib/", "/src/", "/app/", "/cmd/", "/pkg/", "/internal/")
    return any(segment in f"/{path_str}" for segment in significant_dirs)


def extract_elixir_metadata(text: str) -> Tuple[str | None, str | None, List[str]]:
    name_match = re.search(r"defmodule\s+([A-Za-z0-9_.!?]+)", text)
    module_name = name_match.group(1) if name_match else None

    doc_match = re.search(r'@moduledoc\s+"""(.*?)"""', text, re.S)
    summary = None
    if doc_match:
        summary = first_sentence(doc_match.group(1))

    deps = []
    for pattern in [r"alias\s+([A-Z][A-Za-z0-9_.]+)", r"use\s+([A-Z][A-Za-z0-9_.]+)", r"require\s+([A-Z][A-Za-z0-9_.]+)", r"import\s+([A-Z][A-Za-z0-9_.]+)"]:
        deps.extend(re.findall(pattern, text))

    return module_name, summary, deps


def extract_python_metadata(text: str) -> Tuple[str | None, str | None, List[str]]:
    name_match = re.search(r"^(?:class|def)\s+([A-Za-z_][A-Za-z0-9_]*)", text, re.M)
    symbol_name = name_match.group(1) if name_match else None

    doc_match = re.search(r'"""(.*?)"""', text, re.S)
    summary = first_sentence(doc_match.group(1)) if doc_match else None

    deps = []
    deps.extend(re.findall(r"^\s*import\s+([A-Za-z0-9_., ]+)", text, re.M))
    deps.extend(re.findall(r"^\s*from\s+([A-Za-z0-9_.]+)\s+import", text, re.M))
    normalized = []
    for dep in deps:
        normalized.extend(part.strip() for part in dep.split(",") if part.strip())
    return symbol_name, summary, normalized


def extract_generic_summary(text: str) -> str | None:
    lines = [line.strip(" #/*\t") for line in text.splitlines()[:20]]
    lines = [line for line in lines if line]
    return first_sentence(lines[0]) if lines else None


def first_sentence(value: str | None) -> str | None:
    if not value:
        return None
    compact = " ".join(value.strip().split())
    if not compact:
        return None
    match = re.search(r"(.+?[.!?])(?:\s|$)", compact)
    return match.group(1) if match else compact[:180]


def module_id_from_path(path_str: str) -> str:
    return path_str.replace("/", ".").replace("-", "_")


def classify_component(module_record: dict) -> str:
    haystack = " ".join(
        [
            module_record.get("name", ""),
            module_record.get("path", ""),
            module_record.get("summary", ""),
        ]
    ).lower()
    scores = []
    for component_name, _summary, keywords in ARCH_RULES:
        score = sum(2 if keyword in module_record.get("path", "").lower() else 1 for keyword in keywords if keyword in haystack)
        scores.append((score, component_name))
    score, winner = max(scores, default=(0, "repo-core"))
    if score <= 0:
        first_segment = module_record["path"].split("/", 1)[0]
        return f"scope:{first_segment}"
    return winner


def parse_doc_references(text: str, file_path: str, root: Path) -> List[dict]:
    refs = []
    lines = text.splitlines()
    link_pattern = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
    for idx, line in enumerate(lines, start=1):
        for match in link_pattern.finditer(line):
            raw_target = match.group(1)
            if not raw_target or raw_target.startswith(("http://", "https://", "#")):
                continue
            candidate = raw_target.split("#", 1)[0]
            resolved = (Path(file_path).parent / candidate).resolve() if not Path(candidate).is_absolute() else Path(candidate)
            try:
                exists = resolved.exists()
                rel_target = resolved.relative_to(root).as_posix()
            except Exception:
                exists = resolved.exists()
                rel_target = candidate
            refs.append(
                {
                    "path": file_path,
                    "line": idx,
                    "target": candidate,
                    "resolved_target": rel_target,
                    "status": "present" if exists else "missing",
                    "evidence": line.strip(),
                }
            )
    return refs


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    output = Path(args.output)

    language_counts: Counter[str] = Counter()
    source_modules: List[dict] = []
    doc_references: List[dict] = []
    module_index: Dict[str, str] = {}

    for path in iter_files(root):
        rel = relative(path, root)
        suffix = path.suffix.lower()
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        if suffix in DOC_EXTENSIONS and should_scan_path(rel):
            doc_references.extend(parse_doc_references(text, rel, root))

        language = language_for(path)
        if not language:
            continue
        if not include_code_file(rel):
            continue
        language_counts[language] += 1

        if language == "elixir":
            name, summary, deps = extract_elixir_metadata(text)
        elif language == "python":
            name, summary, deps = extract_python_metadata(text)
        else:
            name, summary, deps = None, extract_generic_summary(text), []

        if not name:
            name = module_id_from_path(rel)

        record = {
            "id": module_id_from_path(rel),
            "name": name,
            "path": rel,
            "language": language,
            "summary": summary or f"Source module from `{rel}`.",
            "raw_dependencies": sorted(set(dep for dep in deps if dep)),
        }
        source_modules.append(record)
        module_index[name] = record["id"]

    relationships = []
    for module in source_modules:
        for dep in module["raw_dependencies"]:
            target = module_index.get(dep)
            if target:
                relationships.append(
                    {
                        "from": module["id"],
                        "to": target,
                        "type": "imports",
                        "evidence": dep,
                    }
                )

    components: Dict[str, dict] = {}
    membership: Dict[str, str] = {}
    for module in source_modules:
        component_name = classify_component(module)
        membership[module["id"]] = component_name
        if component_name not in components:
            summary = next((item[1] for item in ARCH_RULES if item[0] == component_name), "Inferred architecture boundary.")
            components[component_name] = {
                "name": component_name,
                "summary": summary,
                "members": [],
                "paths": [],
                "languages": Counter(),
            }
        components[component_name]["members"].append(module["id"])
        components[component_name]["paths"].append(module["path"])
        components[component_name]["languages"][module["language"]] += 1

    component_relationships = defaultdict(int)
    for rel in relationships:
        source_component = membership.get(rel["from"])
        target_component = membership.get(rel["to"])
        if source_component and target_component and source_component != target_component:
            component_relationships[(source_component, target_component)] += 1

    architecture_components = []
    for name, data in sorted(components.items()):
        architecture_components.append(
            {
                "name": name,
                "summary": data["summary"],
                "member_count": len(data["members"]),
                "members": sorted(data["members"]),
                "paths": sorted(set(data["paths"])),
                "primary_languages": [lang for lang, _count in data["languages"].most_common(3)],
            }
        )

    entrypoints = []
    for candidate in ["start-siaan.sh", "docker-compose.yml", "Dockerfile", "elixir/lib/symphony_elixir/cli.ex", "elixir/lib/symphony_elixir/http_server.ex"]:
        if (root / candidate).exists():
            entrypoints.append(candidate)

    data = {
        "inventory_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "repo_root": str(root),
        "languages": [{"name": name, "file_count": count} for name, count in language_counts.most_common()],
        "entrypoints": entrypoints,
        "source_modules": sorted(source_modules, key=lambda item: item["path"]),
        "source_relationships": relationships,
        "architecture_components": architecture_components,
        "component_relationships": [
            {"from": src, "to": dst, "strength": strength}
            for (src, dst), strength in sorted(component_relationships.items())
        ],
        "doc_references": sorted(doc_references, key=lambda item: (item["status"], item["path"], item["line"])),
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

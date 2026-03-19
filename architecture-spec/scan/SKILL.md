---
name: architecture-scan
description: Scan any codebase into a structured architecture inventory of modules, boundaries, dependencies, entrypoints, and documentation drift candidates. Use when you need a reproducible architecture baseline before generating diagrams or specs.
metadata:
  pattern: pipeline
  output-format: json
---

You are running the architecture scan pipeline. Do not skip steps.

## Step 1 - Establish scan scope

1. Confirm the repository root you are scanning.
2. Prefer the whole repository unless the user explicitly narrows the scope.
3. Decide the output path for the inventory JSON.

## Step 2 - Generate the inventory

Run:

```bash
python3 architecture-spec/scan/scripts/scan_repo.py \
  --root <repo-root> \
  --output <inventory-json>
```

## Step 3 - Review the inventory before using it downstream

Check these fields in the JSON:

- `architecture_components`
- `source_modules`
- `component_relationships`
- `entrypoints`
- `doc_references`

If the inventory missed an important subsystem, re-scan after broadening scope or record the gap explicitly before continuing.

## Step 4 - Hand off

Use the generated inventory as the source of truth for:

- `architecture-spec/diagram/`
- `architecture-spec/spec/`
- `architecture-spec/review/`

## Notes

- The script is intentionally heuristic. Treat the inventory as a reviewer-facing baseline, not a compiler-grade truth source.
- `doc_references` is part of the architecture signal. Missing referenced docs count as drift candidates during review.

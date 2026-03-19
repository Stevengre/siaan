---
name: architecture-diagram
description: Generate Mermaid C4 and UML diagrams from an architecture inventory. Use after `architecture-scan` when you need consistent visual architecture artifacts.
metadata:
  pattern: generator
  output-format: mermaid
---

You are generating architecture diagrams from a scan inventory.

## Inputs

- inventory JSON from `architecture-spec/scan/`
- output directory for Mermaid files

## Procedure

1. Load the scan inventory and inspect `architecture_components` plus `component_relationships`.
2. Use the provided templates under `assets/templates/` as the required output shapes.
3. Run:

```bash
python3 architecture-spec/diagram/scripts/generate_diagrams.py \
  --inventory <inventory-json> \
  --output-dir <diagram-dir>
```

4. Confirm that the generator produced:
   - `l1-system-context.mmd`
   - `l2-container-view.mmd`
   - `l3-component-view.mmd`
   - `l4-code-map.mmd`
   - `dispatch-sequence.mmd`

## Quality bar

- Prefer architecture component names over raw file names for C4 diagrams.
- Keep Mermaid output readable in plain text.
- If the scan inventory is weak, fix the scan input before hand-editing diagrams.

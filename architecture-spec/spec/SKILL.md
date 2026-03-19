---
name: architecture-spec
description: Assemble a reviewer-readable architecture SPEC.md from a scan inventory plus generated Mermaid diagrams. Use after `architecture-scan` and `architecture-diagram`.
metadata:
  pattern: generator
  output-format: markdown
---

You are generating a living architecture spec.

## Inputs

- inventory JSON from `architecture-spec/scan/`
- diagram directory from `architecture-spec/diagram/`
- output path for `SPEC.md`

## Procedure

1. Load `assets/templates/SPEC.md.tmpl`.
2. Run:

```bash
python3 architecture-spec/spec/scripts/generate_spec.py \
  --inventory <inventory-json> \
  --diagram-dir <diagram-dir> \
  --output <spec-md>
```

3. Verify the generated spec includes:
   - system summary
   - runtime boundaries
   - architecture component coverage
   - diagram references
   - evidence-backed drift candidates

## Quality bar

- Keep the document understandable to a human who has not read the source code.
- Prefer subsystem narratives over file dumps.
- Preserve exact component names when they matter to the surrounding workflow or review criteria.

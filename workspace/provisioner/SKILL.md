---
name: workspace-provisioner
description: >
  Workspace creation, path safety validation, and cleanup for isolated
  per-issue execution environments. Use when provisioning or managing
  agent workspaces.
---

# Workspace Provisioner

Use this folder for workspace creation, cleanup, and path-safety logic.

- `lib/workspace.ex`: provisioning and lifecycle entrypoints
- `lib/path_safety.ex`: canonicalization and root-boundary checks

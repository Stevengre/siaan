<!--
Repeat the full Change Proof block (`### Behavior Delta` through `### Review Focus`)
for each independent change group in the PR. Keep the Architecture Trace appendix once,
covering all change groups together.
-->

### Behavior Delta

| | Before | After |
|---|---|---|
| Trigger | <!-- What caused the old behavior? --> | <!-- What causes the new behavior? --> |
| Observable effect | <!-- What could a reviewer or user observe before? --> | <!-- What is now observable? --> |
| Affected inputs | <!-- Which inputs/configs/paths mattered before? --> | <!-- Which inputs/configs/paths matter now? --> |

<!-- For behavior-heavy changes, add a mermaid sequence diagram or state transition under this table. -->
<!-- For pure refactors, state "none" in the After column and explain the preserved behavior in Invariants / Non-goals. -->

### Invariants / Non-goals

- **Must still hold**: <!-- What contract, behavior, or operational property must still be true? -->
- **Explicitly unchanged**: <!-- What remains out of blast radius, and why? -->
- **Out of scope**: <!-- What intentionally did not change in this PR? -->

### Validation

| Risk point | Evidence | Link |
|---|---|---|
| <!-- Most likely regression point --> | <!-- test / before-after output / trace / benchmark --> | <!-- Permanent link, artifact, or "N/A (local command)" --> |

### Risk / Blast Radius / Rollback

- **Most likely failure**: <!-- If this breaks, where is it most likely to break first? -->
- **Blast radius**: <!-- Which files, modules, services, or user paths are affected? -->
- **How to detect**: <!-- Log, metric, failing check, user-visible symptom, or alert -->
- **How to rollback**: <!-- Revert commit, disable flag, or operational fallback -->

### Review Focus

1. <!-- Highest-risk decision or correctness claim to inspect -->
2. <!-- Secondary review focus -->
3. <!-- Optional third focus if useful -->

<details>
<summary><b>Architecture Trace</b></summary>

### Context (C4-L1)

<!-- Describe system-level external interaction changes. -->
<!-- If none, explain why this level is excluded, e.g. "No L1 change — internal orchestrator-only change." -->

### Container (C4-L2)

<!-- Describe which services or deployable containers are involved. -->
<!-- If none, explain why this level is excluded. -->

### Component (C4-L3)

<!-- Describe the modules/components that participate and how they interact. -->
<!-- Prefer a mermaid component diagram when topology matters. -->

### Code Trace (C4-L4)

- <!-- Component -> function -> permanent link -->

### Decision Record

- **Decision**: <!-- The design choice introduced or confirmed in this PR -->
- **Alternatives considered**: <!-- Plausible alternatives and why they were not chosen -->
- **Trade-offs**: <!-- What this choice optimizes and what it makes worse -->
- **Why chosen**: <!-- Why this is the best fit for this diff/issue -->
- **Implementation links**: <!-- Permanent links to the key implementation points -->
<!-- If no new design decision exists, replace the bullets with exactly: No design decision introduced in this PR. -->

</details>

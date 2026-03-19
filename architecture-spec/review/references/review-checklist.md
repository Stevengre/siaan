# Architecture Drift Checklist

Apply these checks every time:

1. Coverage
   - Every major architecture component inferred from the inventory should appear in the spec.
   - Diagram artifacts referenced by the spec should exist.
2. Consistency
   - Paths, document references, and linked artifacts should resolve in the repository.
   - The spec should not describe components that the current scan cannot support with evidence.
3. Drift Severity
   - `high`: a major architecture component is undocumented or the spec references core missing artifacts.
   - `medium`: repository docs refer to architecture artifacts that no longer exist, or generated diagrams/spec links are broken.
   - `low`: wording gaps, thin summaries, or minor appendix omissions.

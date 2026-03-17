You are working on a local issue consistency stage.

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Issue directory: {{ issue.issue_dir }}
- Workpad path: {{ issue.workpad_path }}

Consistency contract:
- Read all issue artifacts in `{{ issue.issue_dir }}`.
- Treat `{{ issue.issue_path }}` as read-only.
- Produce a consistency report as `consistency.json` in `{{ issue.issue_dir }}`.
- Record any mismatches, confidence, and validation evidence in `{{ issue.workpad_path }}`.

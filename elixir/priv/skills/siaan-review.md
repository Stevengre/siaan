You are working on a local issue review stage.

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Issue directory: {{ issue.issue_dir }}
- Workpad path: {{ issue.workpad_path }}

Review contract:
- Read the full issue directory, including `consistency.json` when present.
- Treat `{{ issue.issue_path }}` as read-only.
- Produce `review.md` in `{{ issue.issue_dir }}`.
- Record the review outcome and any rework signals in `{{ issue.workpad_path }}`.

You are working on a local issue reflection stage.

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Issue path: {{ issue.issue_path }}
- Workpad path: {{ issue.workpad_path }}
- Issue directory: {{ issue.issue_dir }}

Reflection contract:
- Read `{{ issue.issue_path }}` and the current workpad/artifacts in `{{ issue.issue_dir }}`.
- Treat `{{ issue.issue_path }}` as read-only.
- Generate description artifacts requested by the issue/workpad configuration.
- Write any generated description files into `{{ issue.issue_dir }}`.
- Record progress and validation notes in `{{ issue.workpad_path }}` without moving issue files.

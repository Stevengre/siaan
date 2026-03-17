You are working on a local issue execution stage.

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- Issue path: {{ issue.issue_path }}
- Workpad path: {{ issue.workpad_path }}
- Issue directory: {{ issue.issue_dir }}
- Project directory: {{ issue.project_dir }}
- Base branch: {{ issue.base_branch }}
- Current branch: {{ issue.current_branch }}

Execution contract:
- Read issue context from `{{ issue.issue_path }}`.
- Treat `{{ issue.issue_path }}` as read-only.
- Write progress, validation, and transition intent to `{{ issue.workpad_path }}`.
- Keep `{{ issue.workpad_path }}` as valid markdown with YAML frontmatter bounded by opening and closing `---` lines.
- This stage runs on the local machine from `{{ issue.project_dir }}`; it is not dispatched to remote worker hosts.
- Do not move issue files or directories.
- Do not update remote issue status directly.
- When the execution work is complete, express transition intent by writing this exact frontmatter shape at the top of `workpad.md`:

```yaml
---
status: review
---
```

Execution flow:
1. Reconcile the existing workpad.
2. Plan the implementation and acceptance criteria.
3. Reproduce the current issue signal before edits.
4. Implement the code changes in `{{ issue.project_dir }}`.
5. Validate the changes.
6. Update the workpad with final notes and transition intent.

use crate::issue::Issue;
use std::collections::{HashMap, HashSet};

/// Sort mode for issues within each project group.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortMode {
    Priority,
    Type,
    Title,
}

impl SortMode {
    pub fn next(self) -> Self {
        match self {
            Self::Priority => Self::Type,
            Self::Type => Self::Title,
            Self::Title => Self::Priority,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Priority => "priority",
            Self::Type => "type",
            Self::Title => "title",
        }
    }
}

/// A flattened row for display, carrying depth for indentation.
#[derive(Debug)]
pub enum DisplayRow<'a> {
    /// Project header, with collapsed state and issue count.
    ProjectHeader {
        name: &'a str,
        collapsed: bool,
        count: usize,
    },
    IssueRow {
        issue: &'a Issue,
        depth: usize,
        has_children: bool,
        collapsed: bool,
    },
}

impl<'a> DisplayRow<'a> {
    /// Whether this row is selectable (issues yes, headers no).
    pub fn is_selectable(&self) -> bool {
        matches!(self, DisplayRow::IssueRow { .. })
    }
}

fn sort_issues(issues: &mut [&Issue], mode: SortMode) {
    match mode {
        SortMode::Priority => issues.sort_by(|a, b| {
            priority_sort_key(a)
                .cmp(&priority_sort_key(b))
                .then_with(|| cmp_title(a, b))
        }),
        SortMode::Type => issues.sort_by(|a, b| {
            type_sort_key(a.display_type())
                .cmp(&type_sort_key(b.display_type()))
                .then_with(|| cmp_title(a, b))
        }),
        SortMode::Title => {
            issues.sort_by(|a, b| cmp_title(a, b));
        }
    }
}

fn cmp_title(a: &Issue, b: &Issue) -> std::cmp::Ordering {
    let a_lower = a.frontmatter.title.to_lowercase();
    let b_lower = b.frontmatter.title.to_lowercase();
    a_lower
        .cmp(&b_lower)
        .then_with(|| a.frontmatter.title.cmp(&b.frontmatter.title))
}

fn type_sort_key(raw: &str) -> u8 {
    match raw {
        "epic" => 0,
        "feature" => 1,
        "bug" => 2,
        "task" => 3,
        "research" => 4,
        _ => 5,
    }
}

fn priority_sort_key(issue: &Issue) -> (u8, u32, &str) {
    match issue.frontmatter.priority.as_deref() {
        Some(raw) => {
            let trimmed = raw.trim();
            match trimmed
                .strip_prefix('p')
                .or_else(|| trimmed.strip_prefix('P'))
            {
                Some(rest) if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) => {
                    (0, rest.parse::<u32>().unwrap_or(u32::MAX), trimmed)
                }
                Some(_) => (1, u32::MAX, trimmed),
                None if trimmed.is_empty() => (2, u32::MAX, ""),
                None => (1, u32::MAX, trimmed),
            }
        }
        None => (2, u32::MAX, ""),
    }
}

fn project_sort_key(project: &str) -> (u8, String) {
    if project == "(no project)" {
        (1, String::new())
    } else {
        (0, project.to_lowercase())
    }
}

/// Build a flat display list with project grouping, hierarchy, collapse, and sorting.
pub fn build_display_rows<'a>(
    issues: &'a [Issue],
    collapsed_projects: &HashSet<String>,
    collapsed_issues: &HashSet<String>,
    sort_mode: SortMode,
) -> Vec<DisplayRow<'a>> {
    // Group by project (then sort project headers deterministically).
    let mut by_project: HashMap<&str, Vec<&Issue>> = HashMap::new();

    for issue in issues {
        let project = issue
            .frontmatter
            .project
            .as_deref()
            .unwrap_or("(no project)");
        by_project.entry(project).or_default().push(issue);
    }

    let mut by_project: Vec<(&str, Vec<&Issue>)> = by_project.into_iter().collect();
    by_project.sort_by(|(a, _), (b, _)| project_sort_key(a).cmp(&project_sort_key(b)));

    let mut rows = Vec::new();

    let show_headers = by_project.len() > 1
        || (by_project.len() == 1
            && by_project
                .first()
                .is_some_and(|(name, _)| *name != "(no project)"));

    for (project, mut project_issues) in by_project {
        let is_collapsed = collapsed_projects.contains(project);
        let count = project_issues.len();

        if show_headers {
            rows.push(DisplayRow::ProjectHeader {
                name: project,
                collapsed: is_collapsed,
                count,
            });
        }

        if is_collapsed {
            continue;
        }

        // Sort issues, then derive hierarchy edges for this project.
        sort_issues(&mut project_issues, sort_mode);

        // Build slug → issue lookup
        let slug_map: HashMap<&str, &Issue> = project_issues
            .iter()
            .copied()
            .map(|i| (i.slug.as_str(), i))
            .collect();

        let mut children_by_parent: HashMap<&str, Vec<&Issue>> = HashMap::new();
        let mut child_slugs: HashSet<&str> = HashSet::new();

        for parent in &project_issues {
            if let Some(subs) = &parent.frontmatter.sub_issues {
                let mut children: Vec<&Issue> = subs
                    .iter()
                    .filter_map(|slug| slug_map.get(slug.as_str()).copied())
                    .collect();
                if !children.is_empty() {
                    sort_issues(&mut children, sort_mode);
                    for child in &children {
                        child_slugs.insert(child.slug.as_str());
                    }
                    children_by_parent.insert(parent.slug.as_str(), children);
                }
            }
        }

        // Top-level = not referenced as anyone's sub_issue
        let mut top_level: Vec<&Issue> = project_issues
            .iter()
            .copied()
            .filter(|i| !child_slugs.contains(i.slug.as_str()))
            .collect();
        sort_issues(&mut top_level, sort_mode);

        let mut visited = HashSet::new();
        for issue in top_level {
            let has_children = children_by_parent.contains_key(issue.slug.as_str());
            let collapsed = has_children && collapsed_issues.contains(&issue.slug);
            rows.push(DisplayRow::IssueRow {
                issue,
                depth: 0,
                has_children,
                collapsed,
            });
            visited.insert(issue.slug.clone());
            if has_children && !collapsed {
                add_children(
                    &mut rows,
                    issue,
                    &children_by_parent,
                    1,
                    &mut visited,
                    collapsed_issues,
                );
            }
        }
    }

    rows
}

fn add_children<'a>(
    rows: &mut Vec<DisplayRow<'a>>,
    parent: &'a Issue,
    children_by_parent: &HashMap<&str, Vec<&'a Issue>>,
    depth: usize,
    visited: &mut HashSet<String>,
    collapsed_issues: &HashSet<String>,
) {
    let children = children_by_parent
        .get(parent.slug.as_str())
        .map(Vec::as_slice)
        .unwrap_or(&[]);

    for child in children {
        if !visited.insert(child.slug.clone()) {
            continue;
        }
        let has_children = children_by_parent.contains_key(child.slug.as_str());
        let collapsed = has_children && collapsed_issues.contains(&child.slug);

        rows.push(DisplayRow::IssueRow {
            issue: child,
            depth,
            has_children,
            collapsed,
        });

        if has_children && !collapsed && depth < 10 {
            add_children(
                rows,
                child,
                children_by_parent,
                depth + 1,
                visited,
                collapsed_issues,
            );
        }
    }
}

/// Count how many selectable (issue) rows there are.
pub fn selectable_count(rows: &[DisplayRow<'_>]) -> usize {
    rows.iter().filter(|r| r.is_selectable()).count()
}

/// Map a "selectable index" to a display row index.
pub fn selectable_to_row_index(rows: &[DisplayRow<'_>], selectable_idx: usize) -> usize {
    rows.iter()
        .enumerate()
        .filter(|(_, r)| r.is_selectable())
        .nth(selectable_idx)
        .map(|(i, _)| i)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::issue;
    use std::fs;
    use tempfile::TempDir;

    fn no_collapse() -> HashSet<String> {
        HashSet::new()
    }

    fn no_issue_collapse() -> HashSet<String> {
        HashSet::new()
    }

    fn setup_hierarchy() -> (TempDir, Vec<Issue>) {
        let dir = TempDir::new().unwrap();

        fs::write(
            dir.path().join("pipeline.md"),
            r#"---
project: siaan
title: Issue Pipeline
type: epic
priority: p1
sub_issues:
  - storage
  - triage-local
---
Epic body
"#,
        )
        .unwrap();

        fs::write(
            dir.path().join("storage.md"),
            r#"---
project: siaan
title: Storage Layer
type: task
priority: p1
---
Storage body
"#,
        )
        .unwrap();

        fs::write(
            dir.path().join("triage-local.md"),
            r#"---
project: siaan
title: Triage Localization
type: task
priority: p2
---
Triage body
"#,
        )
        .unwrap();

        fs::write(
            dir.path().join("standalone.md"),
            r#"---
project: siaan
title: Standalone Feature
type: feature
priority: p0
---
Standalone body
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        (dir, issues)
    }

    #[test]
    fn test_hierarchy_single_project() {
        let (_dir, issues) = setup_hierarchy();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );

        let headers: Vec<_> = rows
            .iter()
            .filter(|r| matches!(r, DisplayRow::ProjectHeader { .. }))
            .collect();
        assert_eq!(headers.len(), 1);

        let issue_rows: Vec<_> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow { issue, depth, .. } => Some((issue.slug.as_str(), *depth)),
                _ => None,
            })
            .collect();
        assert_eq!(issue_rows.len(), 4);

        let children: Vec<_> = issue_rows.iter().filter(|(_, d)| *d == 1).collect();
        assert_eq!(children.len(), 2);
    }

    #[test]
    fn test_collapsed_project_hides_issues() {
        let (_dir, issues) = setup_hierarchy();
        let mut collapsed = HashSet::new();
        collapsed.insert("siaan".to_string());

        let rows = build_display_rows(
            &issues,
            &collapsed,
            &no_issue_collapse(),
            SortMode::Priority,
        );

        // Only the header should remain
        assert_eq!(rows.len(), 1);
        assert!(matches!(
            rows[0],
            DisplayRow::ProjectHeader {
                collapsed: true,
                count: 4,
                ..
            }
        ));
        assert_eq!(selectable_count(&rows), 0);
    }

    #[test]
    fn test_multi_project() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("a.md"),
            r#"---
project: alpha
title: Alpha Issue
type: task
priority: p1
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("b.md"),
            r#"---
project: beta
title: Beta Issue
type: bug
priority: p0
---
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );

        let headers: Vec<_> = rows
            .iter()
            .filter(|r| matches!(r, DisplayRow::ProjectHeader { .. }))
            .collect();
        assert_eq!(headers.len(), 2);

        let names: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::ProjectHeader { name, .. } => Some(*name),
                _ => None,
            })
            .collect();
        assert_eq!(names, vec!["alpha", "beta"]);
    }

    #[test]
    fn test_collapse_one_project_keeps_other() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("a.md"),
            r#"---
project: alpha
title: Alpha
type: task
priority: p1
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("b.md"),
            r#"---
project: beta
title: Beta
type: task
priority: p1
---
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        let mut collapsed = HashSet::new();
        collapsed.insert("alpha".to_string());

        let rows = build_display_rows(
            &issues,
            &collapsed,
            &no_issue_collapse(),
            SortMode::Priority,
        );
        // 2 headers + 1 issue (beta's)
        assert_eq!(selectable_count(&rows), 1);
    }

    #[test]
    fn test_no_project_field() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("orphan.md"),
            r#"---
title: Orphan
type: task
priority: p2
---
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );

        let headers: Vec<_> = rows
            .iter()
            .filter(|r| matches!(r, DisplayRow::ProjectHeader { .. }))
            .collect();
        assert!(headers.is_empty());
    }

    #[test]
    fn test_sort_by_type() {
        let (_dir, issues) = setup_hierarchy();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Type,
        );

        let top_level_types: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow {
                    issue, depth: 0, ..
                } => Some(issue.display_type()),
                _ => None,
            })
            .collect();
        // custom type order: epic -> feature -> bug -> task -> research -> unknown
        assert_eq!(top_level_types, vec!["epic", "feature"]);
    }

    #[test]
    fn test_sort_by_type_unknown_goes_last() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("known.md"),
            r#"---
project: p
title: Known
type: bug
priority: p1
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("unknown.md"),
            r#"---
project: p
title: Unknown
type: misc
priority: p1
---
"#,
        )
        .unwrap();
        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Type,
        );
        let titles: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow {
                    issue, depth: 0, ..
                } => Some(issue.frontmatter.title.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(titles, vec!["Known", "Unknown"]);
    }

    #[test]
    fn test_priority_sort_uses_numeric_rank() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("a.md"),
            r#"---
project: p
title: P10
type: task
priority: p10
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("b.md"),
            r#"---
project: p
title: P2
type: task
priority: p2
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("c.md"),
            r#"---
project: p
title: NoPriority
type: task
---
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );
        let titles: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow {
                    issue, depth: 0, ..
                } => Some(issue.frontmatter.title.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(titles, vec!["P2", "P10", "NoPriority"]);
    }

    #[test]
    fn test_priority_sort_handles_text_blank_and_uppercase_prefix() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("upper.md"),
            r#"---
project: p
title: Upper
type: task
priority: P3
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("text.md"),
            r#"---
project: p
title: Text
type: task
priority: urgent
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("blank.md"),
            r#"---
project: p
title: Blank
type: task
priority: "   "
---
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );
        let titles: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow {
                    issue, depth: 0, ..
                } => Some(issue.frontmatter.title.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(titles, vec!["Upper", "Text", "Blank"]);
    }

    #[test]
    fn test_tree_priority_sort_key_handles_overflow_numeric() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("overflow.md"),
            r#"---
project: p
title: Overflow
type: task
priority: p999999999999999999999999
---
"#,
        )
        .unwrap();
        let issues = issue::list_issues(dir.path()).unwrap();
        assert_eq!(issues.len(), 1);
        let key = priority_sort_key(&issues[0]);
        assert_eq!(key.0, 0);
    }

    #[test]
    fn test_tree_priority_sort_key_parses_normal_numeric() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("normal.md"),
            r#"---
project: p
title: Normal
type: task
priority: p2
---
"#,
        )
        .unwrap();
        let issues = issue::list_issues(dir.path()).unwrap();
        assert_eq!(issues.len(), 1);
        let key = priority_sort_key(&issues[0]);
        assert_eq!(key, (0, 2, "p2"));
    }

    #[test]
    fn test_tree_priority_sort_key_handles_prefixed_invalid_values() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("invalid.md"),
            r#"---
project: p
title: Invalid
type: task
priority: pabc
---
"#,
        )
        .unwrap();
        let issues = issue::list_issues(dir.path()).unwrap();
        assert_eq!(issues.len(), 1);
        let key = priority_sort_key(&issues[0]);
        assert_eq!(key, (1, u32::MAX, "pabc"));
    }

    #[test]
    fn test_no_project_header_sorted_last_when_mixed_projects() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("a.md"),
            r#"---
project: alpha
title: A
type: task
priority: p1
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("none.md"),
            r#"---
title: Orphan
type: task
priority: p1
---
"#,
        )
        .unwrap();
        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );
        let headers: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::ProjectHeader { name, .. } => Some(*name),
                _ => None,
            })
            .collect();
        assert_eq!(headers, vec!["alpha", "(no project)"]);
    }

    #[test]
    fn test_sort_by_title() {
        let (_dir, issues) = setup_hierarchy();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Title,
        );

        let top_level_titles: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow {
                    issue, depth: 0, ..
                } => Some(issue.frontmatter.title.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(
            top_level_titles,
            vec!["Issue Pipeline", "Standalone Feature"]
        );
    }

    #[test]
    fn test_sort_by_title_case_insensitive_tie_break() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("a.md"),
            r#"---
project: p
title: alpha
type: task
priority: p1
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("b.md"),
            r#"---
project: p
title: Alpha
type: task
priority: p1
---
"#,
        )
        .unwrap();
        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Title,
        );
        let titles: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow {
                    issue, depth: 0, ..
                } => Some(issue.frontmatter.title.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(titles, vec!["Alpha", "alpha"]);
    }

    #[test]
    fn test_sort_by_type_covers_research_rank() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("research.md"),
            r#"---
project: p
title: Research
type: research
priority: p1
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("task.md"),
            r#"---
project: p
title: Task
type: task
priority: p1
---
"#,
        )
        .unwrap();
        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Type,
        );
        let titles: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow {
                    issue, depth: 0, ..
                } => Some(issue.frontmatter.title.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(titles, vec!["Task", "Research"]);
    }

    #[test]
    fn test_sort_mode_cycle() {
        assert_eq!(SortMode::Priority.next(), SortMode::Type);
        assert_eq!(SortMode::Type.next(), SortMode::Title);
        assert_eq!(SortMode::Title.next(), SortMode::Priority);
    }

    #[test]
    fn test_sort_mode_label() {
        assert_eq!(SortMode::Priority.label(), "priority");
        assert_eq!(SortMode::Type.label(), "type");
        assert_eq!(SortMode::Title.label(), "title");
    }

    #[test]
    fn test_selectable_count_and_index() {
        let (_dir, issues) = setup_hierarchy();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );

        assert_eq!(selectable_count(&rows), 4);

        let first_row = selectable_to_row_index(&rows, 0);
        assert_eq!(first_row, 1);
    }

    #[test]
    fn test_empty_issues() {
        let rows = build_display_rows(
            &[],
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );
        assert!(rows.is_empty());
        assert_eq!(selectable_count(&rows), 0);
    }

    #[test]
    fn test_sub_issue_slug_not_found() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("epic.md"),
            r#"---
project: test
title: Epic
type: epic
priority: p1
sub_issues:
  - nonexistent
---
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );

        let issue_rows: Vec<_> = rows.iter().filter(|r| r.is_selectable()).collect();
        assert_eq!(issue_rows.len(), 1);
    }

    #[test]
    fn test_duplicate_sub_issue_slug_is_ignored() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("epic.md"),
            r#"---
project: p
title: Epic
type: epic
priority: p1
sub_issues:
  - child
  - child
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("child.md"),
            r#"---
project: p
title: Child
type: task
priority: p1
---
"#,
        )
        .unwrap();
        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );
        let issue_titles: Vec<&str> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow { issue, .. } => Some(issue.frontmatter.title.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(issue_titles, vec!["Epic", "Child"]);
    }

    #[test]
    fn test_add_children_recurses_to_grandchildren() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("epic.md"),
            r#"---
project: p
title: Epic
type: epic
priority: p1
sub_issues:
  - child
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("child.md"),
            r#"---
project: p
title: Child
type: task
priority: p1
sub_issues:
  - grand
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("grand.md"),
            r#"---
project: p
title: Grand
type: task
priority: p1
---
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );
        let tuples: Vec<(&str, usize)> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow { issue, depth, .. } => {
                    Some((issue.frontmatter.title.as_str(), *depth))
                }
                _ => None,
            })
            .collect();
        assert_eq!(tuples, vec![("Epic", 0), ("Child", 1), ("Grand", 2)]);
    }

    #[test]
    fn test_issue_collapse_hides_subtree_only() {
        let (_dir, issues) = setup_hierarchy();
        let mut collapsed_issues = HashSet::new();
        collapsed_issues.insert("pipeline".to_string());

        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &collapsed_issues,
            SortMode::Priority,
        );
        let tuples: Vec<(&str, usize)> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow { issue, depth, .. } => {
                    Some((issue.frontmatter.title.as_str(), *depth))
                }
                _ => None,
            })
            .collect();

        assert_eq!(
            tuples,
            vec![("Standalone Feature", 0), ("Issue Pipeline", 0)]
        );
    }

    #[test]
    fn test_sort_mode_reorders_children() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("epic.md"),
            r#"---
project: p
title: Epic
type: epic
priority: p1
sub_issues:
  - child-a
  - child-b
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("child-a.md"),
            r#"---
project: p
title: Zebra
type: task
priority: p1
---
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("child-b.md"),
            r#"---
project: p
title: Alpha
type: task
priority: p2
---
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        let rows_priority = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );
        let rows_title = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Title,
        );

        let children_priority: Vec<&str> = rows_priority
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow {
                    issue, depth: 1, ..
                } => Some(issue.frontmatter.title.as_str()),
                _ => None,
            })
            .collect();
        let children_title: Vec<&str> = rows_title
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow {
                    issue, depth: 1, ..
                } => Some(issue.frontmatter.title.as_str()),
                _ => None,
            })
            .collect();

        assert_eq!(children_priority, vec!["Zebra", "Alpha"]);
        assert_eq!(children_title, vec!["Alpha", "Zebra"]);
    }

    #[test]
    fn test_add_children_stops_at_depth_ten() {
        let dir = TempDir::new().unwrap();
        for idx in 0..12 {
            let slug = format!("n{idx}");
            let title = format!("N{idx}");
            let maybe_sub = if idx < 11 {
                format!("sub_issues:\n  - n{}\n", idx + 1)
            } else {
                String::new()
            };
            fs::write(
                dir.path().join(format!("{slug}.md")),
                format!(
                    "---\nproject: p\ntitle: {title}\ntype: task\npriority: p1\n{maybe_sub}---\n"
                ),
            )
            .unwrap();
        }

        let issues = issue::list_issues(dir.path()).unwrap();
        let rows = build_display_rows(
            &issues,
            &no_collapse(),
            &no_issue_collapse(),
            SortMode::Priority,
        );
        let tuples: Vec<(&str, usize)> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::IssueRow { issue, depth, .. } => {
                    Some((issue.frontmatter.title.as_str(), *depth))
                }
                _ => None,
            })
            .collect();

        assert_eq!(tuples.len(), 11);
        assert_eq!(tuples[0], ("N0", 0));
        assert_eq!(tuples[10], ("N10", 10));
    }
}

#[cfg(test)]
mod real_data_tests {
    use super::*;
    use crate::issue;
    use std::collections::HashSet;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_real_triage_data() {
        let dir = TempDir::new().unwrap();

        fs::write(
            dir.path().join("extract-issue-skills-repo.md"),
            r#"---
project: siaan
title: Extract issue-* skills into standalone repo
type: task
priority: p1
area:
  - config
agents:
  triage: "claude -r bdb9b007"
---
Body
"#,
        )
        .unwrap();

        fs::write(
            dir.path().join("local-markdown-issue-pipeline.md"),
            r#"---
project: siaan
title: Issue Pipeline
type: epic
priority: p1
sub_issues:
  - adapter-layer
  - state-transition-dsl
  - workflow-skill-decomposition
  - orchestrator-local-first
  - stage-inprogress
  - stage-reflect
agents:
  triage: "claude -r issue-triage"
---
Body
"#,
        )
        .unwrap();

        fs::write(
            dir.path().join("skill-package-management.md"),
            r#"---
project: siaan
title: Skill package management
type: epic
priority: p1
sub_issues:
  - skill-pkg-manager
  - extract-issue-skills-repo
agents:
  triage: "claude -r bdb9b007"
---
Body
"#,
        )
        .unwrap();

        fs::write(
            dir.path().join("skill-pkg-manager.md"),
            r#"---
project: siaan
title: Design skill package management
type: feature
priority: p1
agents:
  triage: "claude -r bdb9b007"
---
Body
"#,
        )
        .unwrap();

        let issues = issue::list_issues(dir.path()).unwrap();
        assert_eq!(issues.len(), 4);

        let rows = build_display_rows(
            &issues,
            &HashSet::new(),
            &HashSet::new(),
            SortMode::Priority,
        );
        // Should not hang or OOM
        assert!(!rows.is_empty());

        let selectable = selectable_count(&rows);
        assert_eq!(selectable, 4);
    }
}

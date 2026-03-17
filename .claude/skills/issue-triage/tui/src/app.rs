use crate::issue::{self, Issue};
use crate::tree::{self, DisplayRow, SortMode};
use anyhow::Result;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

pub enum Action {
    Resume(String), // command to exec
    Edit(PathBuf),  // open issue file in editor
    New,            // start new issue triage
    Quit,
}

pub struct App {
    pub issues: Vec<Issue>,
    /// Index into selectable rows (skips headers)
    pub selected: usize,
    pub triage_dir: PathBuf,
    pub collapsed_projects: HashSet<String>,
    pub collapsed_issues: HashSet<String>,
    pub sort_mode: SortMode,
}

impl App {
    pub fn new(triage_dir: PathBuf) -> Result<Self> {
        let issues = issue::list_issues(&triage_dir)?;
        Ok(Self {
            issues,
            selected: 0,
            triage_dir,
            collapsed_projects: HashSet::new(),
            collapsed_issues: HashSet::new(),
            sort_mode: SortMode::Priority,
        })
    }

    /// Build the display rows from current issues, respecting collapsed state.
    pub fn display_rows(&self) -> Vec<DisplayRow<'_>> {
        tree::build_display_rows(
            &self.issues,
            &self.collapsed_projects,
            &self.collapsed_issues,
            self.sort_mode,
        )
    }

    pub fn selectable_count(&self) -> usize {
        tree::selectable_count(&self.display_rows())
    }

    pub fn next(&mut self) {
        let count = self.selectable_count();
        if count > 0 {
            self.selected = (self.selected + 1) % count;
        }
    }

    pub fn previous(&mut self) {
        let count = self.selectable_count();
        if count > 0 {
            self.selected = self.selected.checked_sub(1).unwrap_or(count - 1);
        }
    }

    /// Get the currently selected issue (None if header is selected).
    pub fn selected_issue(&self) -> Option<&Issue> {
        let rows = self.display_rows();
        let row_idx = tree::selectable_to_row_index(&rows, self.selected);
        match rows.get(row_idx) {
            Some(DisplayRow::IssueRow { issue, .. }) => {
                self.issues.iter().find(|i| i.slug == issue.slug)
            }
            _ => None,
        }
    }

    /// Toggle collapse for the selected issue subtree (when it has children),
    /// otherwise toggle collapse for the issue's project group.
    pub fn toggle_collapse(&mut self) {
        let rows_before = self.display_rows();
        let row_idx = tree::selectable_to_row_index(&rows_before, self.selected);

        let selected_issue_slug = rows_before.get(row_idx).and_then(|row| match row {
            DisplayRow::IssueRow {
                issue,
                has_children,
                ..
            } if *has_children => Some(issue.slug.clone()),
            _ => None,
        });

        if let Some(slug) = selected_issue_slug {
            if self.collapsed_issues.contains(&slug) {
                self.collapsed_issues.remove(&slug);
            } else {
                self.collapsed_issues.insert(slug);
            }

            let rows_after = self.display_rows();
            self.selected = nearest_selectable_index(&rows_after, row_idx).unwrap_or_default();
            return;
        }

        // Walk backwards from current row to find its project header.
        let project = rows_before[..=row_idx].iter().rev().find_map(|r| match r {
            DisplayRow::ProjectHeader { name, .. } => Some(name.to_string()),
            _ => None,
        });

        if let Some(name) = project {
            if self.collapsed_projects.contains(&name) {
                self.collapsed_projects.remove(&name);
            } else {
                self.collapsed_projects.insert(name);
            }

            // Keep focus near previous visual position after folding/unfolding.
            let rows_after = self.display_rows();
            self.selected = nearest_selectable_index(&rows_after, row_idx).unwrap_or_default();
        }
    }

    pub fn cycle_sort(&mut self) {
        self.sort_mode = self.sort_mode.next();
        // Clamp selection
        let count = self.selectable_count();
        if count > 0 && self.selected >= count {
            self.selected = count - 1;
        }
    }

    pub fn triage_dir(&self) -> &Path {
        self.triage_dir.as_path()
    }

    pub fn confirm(&self) -> Action {
        match self.selected_issue().and_then(|i| i.resume_command()) {
            Some(cmd) => Action::Resume(cmd.to_string()),
            None => Action::Quit,
        }
    }
}

fn nearest_selectable_index(rows: &[DisplayRow<'_>], preferred_row_idx: usize) -> Option<usize> {
    let selectable_rows: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter_map(|(idx, row)| row.is_selectable().then_some(idx))
        .collect();

    if selectable_rows.is_empty() {
        return None;
    }

    // Prefer the first selectable row at/after current visual row; fallback to last before.
    let pos = selectable_rows
        .iter()
        .position(|&idx| idx >= preferred_row_idx)
        .unwrap_or(selectable_rows.len() - 1);
    Some(pos)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn setup_dir() -> TempDir {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("issue-a.md"),
            r#"---
project: test
title: Alpha
type: task
priority: p1
agents:
  triage: "claude -r aaa"
---
Body A
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("issue-b.md"),
            r#"---
project: test
title: Beta
type: epic
priority: p0
agents:
  triage: "claude -r bbb"
sub_issues:
  - issue-a
---
Body B
"#,
        )
        .unwrap();
        dir
    }

    fn setup_multi_project() -> TempDir {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("a.md"),
            r#"---
project: alpha
title: Alpha Issue
type: task
priority: p1
agents:
  triage: "claude -r aaa"
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
agents:
  triage: "claude -r bbb"
---
"#,
        )
        .unwrap();
        dir
    }

    #[test]
    fn test_app_loads_issues() {
        let dir = setup_dir();
        let app = App::new(dir.path().to_path_buf()).unwrap();
        assert_eq!(app.issues.len(), 2);
        assert_eq!(app.triage_dir(), dir.path());
    }

    #[test]
    fn test_app_display_rows_hierarchy() {
        let dir = setup_dir();
        let app = App::new(dir.path().to_path_buf()).unwrap();
        let rows = app.display_rows();

        // header + epic(depth=0) + alpha(depth=1) = 3
        assert_eq!(rows.len(), 3);
        assert_eq!(app.selectable_count(), 2);
    }

    #[test]
    fn test_app_navigation() {
        let dir = setup_dir();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        assert_eq!(app.selected, 0);
        app.next();
        assert_eq!(app.selected, 1);
        app.next();
        assert_eq!(app.selected, 0);
        app.previous();
        assert_eq!(app.selected, 1);
    }

    #[test]
    fn test_app_selected_issue() {
        let dir = setup_dir();
        let app = App::new(dir.path().to_path_buf()).unwrap();
        let issue = app.selected_issue().unwrap();
        assert_eq!(issue.frontmatter.title, "Beta");
    }

    #[test]
    fn test_app_confirm_resume() {
        let dir = setup_dir();
        let app = App::new(dir.path().to_path_buf()).unwrap();
        assert_eq!(
            std::mem::discriminant(&app.confirm()),
            std::mem::discriminant(&Action::Resume(String::new()))
        );
    }

    #[test]
    fn test_app_empty_dir() {
        let dir = TempDir::new().unwrap();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        assert!(app.issues.is_empty());
        app.next();
        app.previous();
        assert_eq!(
            std::mem::discriminant(&app.confirm()),
            std::mem::discriminant(&Action::Quit)
        );
    }

    #[test]
    fn test_app_new_errors_for_non_directory_path() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("not-a-dir.md");
        fs::write(&file, "x").unwrap();
        assert!(App::new(file).is_err());
    }

    #[test]
    fn test_toggle_collapse() {
        let dir = setup_multi_project();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();

        assert_eq!(app.selectable_count(), 2);

        // Collapse the project the first selected issue belongs to
        app.toggle_collapse();
        assert_eq!(app.selectable_count(), 1);

        // Clamp should have moved selection to the only remaining issue
        assert_eq!(app.selected, 0);

        // Toggle again — now we're on the other project, so this collapses that one
        // Need to expand the first one, so let's toggle collapse on current selection's project
        // Actually the selection moved to the other project's issue, so toggling collapses that
        // Let's just verify we can expand by inserting the first project back
        app.collapsed_projects.clear();
        assert_eq!(app.selectable_count(), 2);
    }

    #[test]
    fn test_toggle_collapse_keeps_selection_nearby() {
        let dir = setup_multi_project();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        app.selected = 1; // second project's only issue

        app.toggle_collapse(); // collapses beta

        // beta hidden, alpha remains; selection should move to remaining issue
        assert_eq!(app.selectable_count(), 1);
        assert_eq!(app.selected, 0);
        assert_eq!(
            app.selected_issue().map(|i| i.frontmatter.title.as_str()),
            Some("Alpha Issue")
        );
    }

    #[test]
    fn test_toggle_collapse_expands_when_already_collapsed() {
        let dir = setup_dir();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        app.collapsed_issues.insert("issue-b".to_string());
        app.selected = 0;

        // Selected epic is already folded; toggling expands it.
        app.toggle_collapse();
        assert!(!app.collapsed_issues.contains("issue-b"));
    }

    #[test]
    fn test_toggle_collapse_expands_project_when_precollapsed() {
        let dir = setup_dir();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        app.collapsed_projects.insert("test".to_string());
        app.selected = 0;

        app.toggle_collapse();
        assert!(!app.collapsed_projects.contains("test"));
    }

    #[test]
    fn test_toggle_collapse_with_single_project_keeps_selectable_rows() {
        let dir = setup_dir();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        app.selected = 0;
        app.toggle_collapse();
        assert_eq!(app.selectable_count(), 1);
        assert_eq!(app.selected, 0);
    }

    #[test]
    fn test_toggle_collapse_on_parent_issue_hides_children() {
        let dir = setup_dir();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        app.selected = 0; // Beta epic
        app.toggle_collapse();
        assert_eq!(app.selectable_count(), 1);
        assert!(app.collapsed_issues.contains("issue-b"));
    }

    #[test]
    fn test_cycle_sort_clamps_out_of_range_selection() {
        let dir = setup_dir();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        app.selected = 999;
        app.cycle_sort();
        assert!(app.selected < app.selectable_count());
    }

    #[test]
    fn test_toggle_collapse_no_project_header_is_noop() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("orphan.md"),
            r#"---
title: Orphan
type: task
priority: p1
---
"#,
        )
        .unwrap();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        let before = app.selectable_count();
        app.toggle_collapse();
        assert_eq!(app.selectable_count(), before);
    }

    #[test]
    fn test_cycle_sort() {
        let dir = setup_dir();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        assert_eq!(app.sort_mode, SortMode::Priority);

        app.cycle_sort();
        assert_eq!(app.sort_mode, SortMode::Type);

        app.cycle_sort();
        assert_eq!(app.sort_mode, SortMode::Title);

        app.cycle_sort();
        assert_eq!(app.sort_mode, SortMode::Priority);
    }

    #[test]
    fn test_nearest_selectable_index_none_when_empty_rows() {
        let rows: Vec<DisplayRow<'_>> = Vec::new();
        assert_eq!(nearest_selectable_index(&rows, 0), None);
    }
}

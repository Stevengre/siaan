use crate::issue::{self, Issue};
use anyhow::Result;
use std::path::{Path, PathBuf};

pub enum Action {
    Resume(String), // command to exec
    New,            // start new issue triage
    Quit,
}

pub struct App {
    pub issues: Vec<Issue>,
    pub selected: usize,
    pub triage_dir: PathBuf,
}

impl App {
    pub fn new(triage_dir: PathBuf) -> Result<Self> {
        let issues = issue::list_issues(&triage_dir)?;
        Ok(Self {
            issues,
            selected: 0,
            triage_dir,
        })
    }

    pub fn next(&mut self) {
        if !self.issues.is_empty() {
            self.selected = (self.selected + 1) % self.issues.len();
        }
    }

    pub fn previous(&mut self) {
        if !self.issues.is_empty() {
            self.selected = self
                .selected
                .checked_sub(1)
                .unwrap_or(self.issues.len() - 1);
        }
    }

    pub fn selected_issue(&self) -> Option<&Issue> {
        self.issues.get(self.selected)
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
title: Beta
type: epic
priority: p0
agents:
  triage: "claude -r bbb"
---
Body B
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
    fn test_app_navigation() {
        let dir = setup_dir();
        let mut app = App::new(dir.path().to_path_buf()).unwrap();
        assert_eq!(app.selected, 0);
        app.next();
        assert_eq!(app.selected, 1);
        app.next();
        assert_eq!(app.selected, 0); // wraps
        app.previous();
        assert_eq!(app.selected, 1); // wraps back
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
        app.next(); // should not panic
        app.previous(); // should not panic
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
}

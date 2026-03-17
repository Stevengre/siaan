use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize)]
pub struct IssueFrontmatter {
    pub project: Option<String>,
    pub title: String,
    pub status: Option<String>,
    #[serde(rename = "type")]
    pub issue_type: Option<String>,
    pub priority: Option<String>,
    pub area: Option<Vec<String>>,
    pub agents: Option<HashMap<String, String>>,
    pub sub_issues: Option<Vec<String>>,
}

#[derive(Debug, Clone)]
pub struct Issue {
    pub slug: String,
    pub path: PathBuf,
    pub frontmatter: IssueFrontmatter,
    pub body: String,
}

impl Issue {
    pub fn resume_command(&self) -> Option<&str> {
        self.frontmatter
            .agents
            .as_ref()
            .and_then(|a| a.get("triage"))
            .map(|s| s.as_str())
    }

    pub fn display_type(&self) -> &str {
        self.frontmatter.issue_type.as_deref().unwrap_or("???")
    }

    pub fn display_priority(&self) -> &str {
        self.frontmatter.priority.as_deref().unwrap_or("??")
    }

    pub fn display_areas(&self) -> String {
        self.frontmatter
            .area
            .as_ref()
            .map(|a| a.join(", "))
            .unwrap_or_default()
    }

    pub fn display_project(&self) -> &str {
        self.frontmatter
            .project
            .as_deref()
            .unwrap_or("(no project)")
    }

    pub fn display_status(&self) -> &str {
        self.frontmatter.status.as_deref().unwrap_or("(no status)")
    }

    pub fn body_preview(&self) -> &str {
        self.body.lines().next().unwrap_or("").trim()
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

/// Parse a markdown file with YAML frontmatter into an Issue.
pub fn parse_issue(path: &Path) -> Result<Issue> {
    let content = fs::read_to_string(path).context(format!("reading {}", path.display()))?;

    let slug = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string();

    let (frontmatter, body) = parse_frontmatter(&content)
        .with_context(|| format!("parsing frontmatter in {}", path.display()))?;

    Ok(Issue {
        slug,
        path: path.to_path_buf(),
        frontmatter,
        body,
    })
}

/// Split content into frontmatter and body.
pub fn parse_frontmatter(content: &str) -> Result<(IssueFrontmatter, String)> {
    let content = content.trim();
    if !content.starts_with("---") {
        anyhow::bail!("no frontmatter delimiter found");
    }

    let after_first = &content[3..];
    let end = after_first
        .find("\n---")
        .ok_or(anyhow::anyhow!("no closing frontmatter delimiter"))?;

    let yaml_str = &after_first[..end];
    let body = after_first[end + 4..].trim().to_string();

    let frontmatter: IssueFrontmatter =
        serde_yaml::from_str(yaml_str).context("invalid frontmatter YAML")?;

    Ok((frontmatter, body))
}

/// List all issues in a given directory (non-recursive).
/// Handles both single-file issues (<slug>.md) and directory issues (<slug>/issue.md).
pub fn list_issues(dir: &Path) -> Result<Vec<Issue>> {
    if !dir.exists() {
        return Ok(vec![]);
    }

    let mut issues = Vec::new();

    for path in fs::read_dir(dir)
        .context(format!("reading dir {}", dir.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
    {
        let issue_path = if path.is_file() && path.extension().is_some_and(|e| e == "md") {
            Some(path)
        } else if path.is_dir() {
            let md = path.join("issue.md");
            if md.exists() {
                Some(md)
            } else {
                None
            }
        } else {
            None
        };

        if let Some(p) = issue_path {
            match parse_issue(&p) {
                Ok(issue) => issues.push(issue),
                Err(e) => eprintln!("warn: skipping {}: {}", p.display(), e),
            }
        }
    }

    // Sort by priority (p0 first), then by title
    issues.sort_by(|a, b| {
        priority_sort_key(a)
            .cmp(&priority_sort_key(b))
            .then_with(|| a.frontmatter.title.cmp(&b.frontmatter.title))
    });

    Ok(issues)
}

/// Default triage directory path.
pub fn default_triage_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or(PathBuf::from("."))
        .join(".config/skills/issue-config/triage")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn sample_issue() -> &'static str {
        r#"---
project: siaan
title: Test Issue
status: triage
type: feature
priority: p1
area:
  - orchestrator
agents:
  triage: "claude -r abc123"
---

## Problem

Some problem description.
"#
    }

    fn epic_issue() -> &'static str {
        r#"---
project: siaan
title: Epic Issue
status: triage
type: epic
priority: p0
area:
  - orchestrator
  - agent-runner
agents:
  triage: "claude -r def456"
sub_issues:
  - sub-one
  - sub-two
---

## Goal

An epic goal.
"#
    }

    fn minimal_issue() -> &'static str {
        r#"---
title: Minimal
---

Body only.
"#
    }

    #[test]
    fn test_parse_frontmatter_basic() {
        let (fm, body) = parse_frontmatter(sample_issue()).unwrap();
        assert_eq!(fm.title, "Test Issue");
        assert_eq!(fm.issue_type.as_deref(), Some("feature"));
        assert_eq!(fm.priority.as_deref(), Some("p1"));
        assert_eq!(fm.status.as_deref(), Some("triage"));
        assert_eq!(fm.area.as_ref().unwrap(), &vec!["orchestrator".to_string()]);
        assert!(body.contains("Some problem description."));
    }

    #[test]
    fn test_parse_frontmatter_agents() {
        let (fm, _) = parse_frontmatter(sample_issue()).unwrap();
        let agents = fm.agents.as_ref().unwrap();
        assert_eq!(agents.get("triage").unwrap(), "claude -r abc123");
    }

    #[test]
    fn test_parse_frontmatter_epic_sub_issues() {
        let (fm, _) = parse_frontmatter(epic_issue()).unwrap();
        assert_eq!(fm.issue_type.as_deref(), Some("epic"));
        let subs = fm.sub_issues.as_ref().unwrap();
        assert_eq!(subs, &vec!["sub-one".to_string(), "sub-two".to_string()]);
    }

    #[test]
    fn test_parse_frontmatter_minimal() {
        let (fm, body) = parse_frontmatter(minimal_issue()).unwrap();
        assert_eq!(fm.title, "Minimal");
        assert!(fm.issue_type.is_none());
        assert!(fm.agents.is_none());
        assert!(body.contains("Body only."));
    }

    #[test]
    fn test_parse_frontmatter_no_delimiter() {
        let result = parse_frontmatter("no frontmatter here");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_frontmatter_no_closing_delimiter() {
        let input = r#"---
title: missing end
"#;
        let result = parse_frontmatter(input);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_frontmatter_invalid_yaml() {
        let input = r#"---
title: [unterminated
---
body
"#;
        let result = parse_frontmatter(input);
        assert!(result.is_err());
    }

    #[test]
    fn test_issue_resume_command() {
        let (fm, _) = parse_frontmatter(sample_issue()).unwrap();
        let issue = Issue {
            slug: "test".into(),
            path: PathBuf::from("test.md"),
            frontmatter: fm,
            body: String::new(),
        };
        assert_eq!(issue.resume_command(), Some("claude -r abc123"));
    }

    #[test]
    fn test_issue_resume_command_none() {
        let (fm, _) = parse_frontmatter(minimal_issue()).unwrap();
        let issue = Issue {
            slug: "test".into(),
            path: PathBuf::from("test.md"),
            frontmatter: fm,
            body: String::new(),
        };
        assert_eq!(issue.resume_command(), None);
    }

    #[test]
    fn test_list_issues_single_files() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("issue-a.md"), sample_issue()).unwrap();
        fs::write(dir.path().join("issue-b.md"), epic_issue()).unwrap();

        let issues = list_issues(dir.path()).unwrap();
        assert_eq!(issues.len(), 2);
        // p0 (epic) should come first
        assert_eq!(issues[0].frontmatter.title, "Epic Issue");
        assert_eq!(issues[1].frontmatter.title, "Test Issue");
    }

    #[test]
    fn test_list_issues_directory_format() {
        let dir = TempDir::new().unwrap();
        let sub = dir.path().join("my-issue");
        fs::create_dir(&sub).unwrap();
        fs::write(sub.join("issue.md"), sample_issue()).unwrap();

        let issues = list_issues(dir.path()).unwrap();
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].frontmatter.title, "Test Issue");
    }

    #[test]
    fn test_list_issues_empty_dir() {
        let dir = TempDir::new().unwrap();
        let issues = list_issues(dir.path()).unwrap();
        assert!(issues.is_empty());
    }

    #[test]
    fn test_list_issues_errors_for_non_directory_path() {
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("not-a-dir.md");
        fs::write(&file, "x").unwrap();

        let result = list_issues(&file);
        assert!(result.is_err());
    }

    #[test]
    fn test_list_issues_nonexistent_dir() {
        let issues = list_issues(Path::new("/nonexistent/path")).unwrap();
        assert!(issues.is_empty());
    }

    #[test]
    fn test_list_issues_skips_invalid() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("good.md"), sample_issue()).unwrap();
        fs::write(dir.path().join("bad.md"), "no frontmatter").unwrap();
        fs::write(dir.path().join("not-md.txt"), "ignored").unwrap();

        let issues = list_issues(dir.path()).unwrap();
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].slug, "good");
    }

    #[test]
    fn test_list_issues_sorts_by_title_when_priority_ties() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("zeta.md"),
            r#"---
title: Zeta
priority: p1
---
z
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("alpha.md"),
            r#"---
title: Alpha
priority: p1
---
a
"#,
        )
        .unwrap();

        let issues = list_issues(dir.path()).unwrap();
        assert_eq!(issues.len(), 2);
        assert_eq!(issues[0].frontmatter.title, "Alpha");
        assert_eq!(issues[1].frontmatter.title, "Zeta");
    }

    #[test]
    fn test_list_issues_sorts_priority_numerically() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("p10.md"),
            r#"---
title: P10
priority: p10
---
x
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("p2.md"),
            r#"---
title: P2
priority: p2
---
x
"#,
        )
        .unwrap();

        let issues = list_issues(dir.path()).unwrap();
        assert_eq!(issues.len(), 2);
        assert_eq!(issues[0].frontmatter.title, "P2");
        assert_eq!(issues[1].frontmatter.title, "P10");
    }

    #[test]
    fn test_list_issues_priority_handles_blank_and_text_and_overflow() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("overflow.md"),
            r#"---
title: Overflow
priority: p999999999999999999999999
---
x
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("text.md"),
            r#"---
title: Text
priority: urgent
---
x
"#,
        )
        .unwrap();
        fs::write(
            dir.path().join("blank.md"),
            r#"---
title: Blank
priority: "   "
---
x
"#,
        )
        .unwrap();

        let issues = list_issues(dir.path()).unwrap();
        let titles: Vec<&str> = issues
            .iter()
            .map(|i| i.frontmatter.title.as_str())
            .collect();
        assert_eq!(titles, vec!["Overflow", "Text", "Blank"]);
    }

    #[test]
    fn test_priority_sort_key_overflow_stays_numeric_bucket() {
        let issue = Issue {
            slug: "x".into(),
            path: PathBuf::from("x.md"),
            frontmatter: IssueFrontmatter {
                project: None,
                title: "Overflow".into(),
                status: None,
                issue_type: None,
                priority: Some("p999999999999999999999999".into()),
                area: None,
                agents: None,
                sub_issues: None,
            },
            body: String::new(),
        };
        let key = priority_sort_key(&issue);
        assert_eq!(key.0, 0);
    }

    #[test]
    fn test_priority_sort_key_parses_normal_numeric() {
        let issue = Issue {
            slug: "x".into(),
            path: PathBuf::from("x.md"),
            frontmatter: IssueFrontmatter {
                project: None,
                title: "Normal".into(),
                status: None,
                issue_type: None,
                priority: Some("p2".into()),
                area: None,
                agents: None,
                sub_issues: None,
            },
            body: String::new(),
        };
        let key = priority_sort_key(&issue);
        assert_eq!(key, (0, 2, "p2"));
    }

    #[test]
    fn test_priority_sort_key_handles_prefixed_invalid_values() {
        let mk = |priority: &str| Issue {
            slug: "x".into(),
            path: PathBuf::from("x.md"),
            frontmatter: IssueFrontmatter {
                project: None,
                title: "X".into(),
                status: None,
                issue_type: None,
                priority: Some(priority.to_string()),
                area: None,
                agents: None,
                sub_issues: None,
            },
            body: String::new(),
        };
        assert_eq!(priority_sort_key(&mk("p")), (1, u32::MAX, "p"));
        assert_eq!(priority_sort_key(&mk("pabc")), (1, u32::MAX, "pabc"));
    }

    #[test]
    fn test_display_type_and_priority() {
        let (fm, _) = parse_frontmatter(sample_issue()).unwrap();
        let issue = Issue {
            slug: "test".into(),
            path: PathBuf::from("test.md"),
            frontmatter: fm,
            body: "## Problem\nMore details".to_string(),
        };
        assert_eq!(issue.display_type(), "feature");
        assert_eq!(issue.display_priority(), "p1");
        assert_eq!(issue.display_areas(), "orchestrator");
        assert_eq!(issue.display_project(), "siaan");
        assert_eq!(issue.display_status(), "triage");
        assert_eq!(issue.body_preview(), "## Problem");
    }

    #[test]
    fn test_display_defaults_when_missing() {
        let (fm, _) = parse_frontmatter(minimal_issue()).unwrap();
        let issue = Issue {
            slug: "test".into(),
            path: PathBuf::from("test.md"),
            frontmatter: fm,
            body: String::new(),
        };
        assert_eq!(issue.display_type(), "???");
        assert_eq!(issue.display_priority(), "??");
        assert_eq!(issue.display_areas(), "");
        assert_eq!(issue.display_project(), "(no project)");
        assert_eq!(issue.display_status(), "(no status)");
        assert_eq!(issue.body_preview(), "");
    }

    #[test]
    fn test_list_issues_dir_without_issue_md() {
        let dir = TempDir::new().unwrap();
        // Directory exists but has no issue.md inside
        let sub = dir.path().join("empty-dir");
        fs::create_dir(&sub).unwrap();
        fs::write(sub.join("workpad.md"), "not an issue").unwrap();

        let issues = list_issues(dir.path()).unwrap();
        assert!(issues.is_empty());
    }

    #[test]
    fn test_default_triage_dir() {
        let path = default_triage_dir();
        assert!(path.ends_with(".config/skills/issue-config/triage"));
    }

    #[test]
    fn test_parse_issue_missing_file() {
        let result = parse_issue(Path::new("/definitely-missing-issue.md"));
        assert!(result.is_err());
    }
}

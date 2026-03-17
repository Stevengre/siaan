use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub global: GlobalConfig,
    #[serde(default)]
    pub projects: HashMap<String, ProjectConfig>,
}

#[derive(Debug, Deserialize, Default, Clone)]
pub struct GlobalConfig {
    /// Editor command for opening issue files (e.g., "hx", "nvim", "code").
    /// Falls back to $EDITOR, then "vi".
    pub editor: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct ProjectConfig {
    pub dir: String,
}

impl Config {
    pub fn project_dir(&self, project: &str) -> Option<&str> {
        self.projects.get(project).map(|p| p.dir.as_str())
    }

    /// Resolve editor: config.global.editor → $EDITOR → "vi"
    pub fn editor(&self) -> String {
        self.global
            .editor
            .clone()
            .or_else(|| std::env::var("EDITOR").ok())
            .unwrap_or_else(|| "vi".to_string())
    }

    /// Return the first configured project (name, dir). Useful as fallback
    /// when no issue is selected (e.g., empty triage, pressing 'n').
    pub fn first_project(&self) -> Option<(&str, &str)> {
        self.projects
            .iter()
            .next()
            .map(|(name, cfg)| (name.as_str(), cfg.dir.as_str()))
    }
}

/// Load config from the default path (~/.config/skills/issue-config/config.toml).
pub fn load_config() -> Result<Config> {
    let path = default_config_path();
    load_config_from(&path)
}

pub fn load_config_from(path: &Path) -> Result<Config> {
    if !path.exists() {
        return Ok(Config::default());
    }
    let content = fs::read_to_string(path).context(format!("reading {}", path.display()))?;
    let config: Config = toml::from_str(&content).context("parsing config.toml")?;
    Ok(config)
}

fn default_config_path() -> PathBuf {
    default_config_path_from(dirs::home_dir())
}

fn default_config_path_from(home_dir: Option<PathBuf>) -> PathBuf {
    home_dir
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".config/skills/issue-config/config.toml")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::sync::{Mutex, OnceLock};
    use tempfile::TempDir;

    fn home_lock() -> &'static Mutex<()> {
        static HOME_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        HOME_LOCK.get_or_init(|| Mutex::new(()))
    }

    struct HomeGuard {
        previous: Option<OsString>,
    }

    impl Drop for HomeGuard {
        fn drop(&mut self) {
            match &self.previous {
                Some(value) => std::env::set_var("HOME", value),
                None => std::env::remove_var("HOME"),
            }
        }
    }

    fn set_home(path: &Path) -> HomeGuard {
        let previous = std::env::var_os("HOME");
        std::env::set_var("HOME", path);
        HomeGuard { previous }
    }

    fn restore_home(previous: Option<OsString>) {
        match previous {
            Some(value) => std::env::set_var("HOME", value),
            None => std::env::remove_var("HOME"),
        }
    }

    fn restore_editor(previous: Option<OsString>) {
        match previous {
            Some(value) => std::env::set_var("EDITOR", value),
            None => std::env::remove_var("EDITOR"),
        }
    }

    #[test]
    fn test_load_config_with_projects() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(
            &path,
            r#"
[storage]
path = "~/.config/skills/issue-config/"

[projects.siaan]
dir = "/Users/alice/projs/siaan"

[projects.other]
dir = "/Users/alice/projs/other"
"#,
        )
        .unwrap();

        let config = load_config_from(&path).unwrap();
        assert_eq!(
            config.project_dir("siaan"),
            Some("/Users/alice/projs/siaan")
        );
        assert_eq!(
            config.project_dir("other"),
            Some("/Users/alice/projs/other")
        );
        assert_eq!(config.project_dir("missing"), None);
    }

    #[test]
    fn test_load_config_missing_file() {
        let config = load_config_from(Path::new("/nonexistent/config.toml")).unwrap();
        assert!(config.projects.is_empty());
    }

    #[test]
    fn test_load_config_no_projects_section() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(
            &path,
            r#"
[storage]
path = "~/.config/skills/issue-config/"
"#,
        )
        .unwrap();

        let config = load_config_from(&path).unwrap();
        assert!(config.projects.is_empty());
    }

    #[test]
    fn test_load_config_invalid_toml() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(&path, "[projects.bad\ndir = \"oops\"").unwrap();

        let result = load_config_from(&path);
        assert!(result.is_err());
    }

    #[test]
    fn test_load_config_read_error_for_directory_path() {
        let dir = TempDir::new().unwrap();
        let result = load_config_from(dir.path());
        assert!(result.is_err());
    }

    #[test]
    fn test_load_config_uses_default_path() {
        let _lock = home_lock().lock().unwrap();
        let home = TempDir::new().unwrap();
        let _home_guard = set_home(home.path());

        let config_path = home.path().join(".config/skills/issue-config/config.toml");
        fs::create_dir_all(config_path.parent().unwrap()).unwrap();
        fs::write(
            &config_path,
            r#"
[projects.siaan]
dir = "/tmp/siaan"
"#,
        )
        .unwrap();

        let config = load_config().unwrap();
        assert_eq!(config.project_dir("siaan"), Some("/tmp/siaan"));
    }

    #[test]
    fn test_default_config_path_from_home_variants() {
        let with_home = default_config_path_from(Some(PathBuf::from("/tmp/home")));
        assert_eq!(
            with_home,
            PathBuf::from("/tmp/home/.config/skills/issue-config/config.toml")
        );

        let without_home = default_config_path_from(None);
        assert_eq!(
            without_home,
            PathBuf::from("./.config/skills/issue-config/config.toml")
        );
    }

    #[test]
    fn test_home_guard_restores_missing_home() {
        let _lock = home_lock().lock().unwrap();
        let original = std::env::var_os("HOME");
        std::env::remove_var("HOME");

        {
            let temp = TempDir::new().unwrap();
            let _guard = set_home(temp.path());
            assert!(std::env::var_os("HOME").is_some());
        }

        assert!(std::env::var_os("HOME").is_none());
        restore_home(original);
    }

    #[test]
    fn test_home_guard_restores_existing_home() {
        let _lock = home_lock().lock().unwrap();
        let original = std::env::var_os("HOME");
        std::env::set_var("HOME", "/tmp/home-before");

        {
            let temp = TempDir::new().unwrap();
            let _guard = set_home(temp.path());
            assert_ne!(
                std::env::var_os("HOME"),
                Some(OsString::from("/tmp/home-before"))
            );
        }

        assert_eq!(
            std::env::var_os("HOME"),
            Some(OsString::from("/tmp/home-before"))
        );
        restore_home(original);
    }

    #[test]
    fn test_restore_home_none_branch() {
        let _lock = home_lock().lock().unwrap();
        restore_home(None);
        assert!(std::env::var_os("HOME").is_none());
    }

    #[test]
    fn test_restore_home_some_branch() {
        let _lock = home_lock().lock().unwrap();
        let original = std::env::var_os("HOME");
        restore_home(Some(OsString::from("/tmp/issue-tui-home")));
        assert_eq!(
            std::env::var_os("HOME"),
            Some(OsString::from("/tmp/issue-tui-home"))
        );
        restore_home(original);
    }

    #[test]
    fn test_editor_from_config() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(
            &path,
            r#"
[global]
editor = "hx"
"#,
        )
        .unwrap();
        let config = load_config_from(&path).unwrap();
        assert_eq!(config.editor(), "hx");
    }

    #[test]
    fn test_editor_fallback_to_vi() {
        let _lock = home_lock().lock().unwrap();
        let original_editor = std::env::var_os("EDITOR");
        std::env::remove_var("EDITOR");

        let config = Config::default();
        assert_eq!(config.editor(), "vi");

        restore_editor(original_editor);
    }

    #[test]
    fn test_editor_fallback_to_env_var() {
        let _lock = home_lock().lock().unwrap();
        let original_editor = std::env::var_os("EDITOR");
        std::env::set_var("EDITOR", "vim");

        let config = Config::default();
        assert_eq!(config.editor(), "vim");

        restore_editor(original_editor);
    }

    #[test]
    fn test_editor_restore_branch_when_original_editor_exists() {
        let _lock = home_lock().lock().unwrap();
        let original_editor = std::env::var_os("EDITOR");
        std::env::set_var("EDITOR", "nano");
        let saved = std::env::var_os("EDITOR");
        std::env::remove_var("EDITOR");

        let config = Config::default();
        assert_eq!(config.editor(), "vi");

        restore_editor(saved);
        restore_editor(original_editor);
    }

    #[test]
    fn test_restore_editor_none_branch() {
        let _lock = home_lock().lock().unwrap();
        restore_editor(None);
        assert!(std::env::var_os("EDITOR").is_none());
    }

    #[test]
    fn test_restore_editor_some_branch() {
        let _lock = home_lock().lock().unwrap();
        let original_editor = std::env::var_os("EDITOR");
        restore_editor(Some(OsString::from("nano")));
        assert_eq!(std::env::var_os("EDITOR"), Some(OsString::from("nano")));
        restore_editor(original_editor);
    }

    #[test]
    fn test_first_project_none_when_empty() {
        let config = Config::default();
        assert!(config.first_project().is_none());
    }

    #[test]
    fn test_first_project_returns_some_when_present() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(
            &path,
            r#"
[projects.alpha]
dir = "/tmp/alpha"
"#,
        )
        .unwrap();
        let config = load_config_from(&path).unwrap();
        let first = config.first_project();
        assert!(first.is_some());
    }
}

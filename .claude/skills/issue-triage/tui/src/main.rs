#![forbid(unsafe_code)]
#![deny(unsafe_op_in_unsafe_fn)]

mod app;
mod config;
mod issue;
mod tree;
mod ui;

use anyhow::Result;
use app::{Action, App};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use std::process::Command;

fn main() -> Result<()> {
    let triage_dir = std::env::args()
        .nth(1)
        .map(std::path::PathBuf::from)
        .unwrap_or_else(issue::default_triage_dir);

    let config = config::load_config()?;
    let mut app = App::new(triage_dir)?;

    // Enter TUI (ratatui::init handles raw mode + alternate screen)
    let mut terminal = ratatui::init();
    let result = run_loop(&mut terminal, &mut app);

    // Grab project info before we lose access to app
    let selected_project = app
        .selected_issue()
        .and_then(|i| i.frontmatter.project.clone());

    // Restore terminal (ratatui::restore handles cleanup)
    ratatui::restore();

    // Handle action after terminal is restored
    match result {
        Ok(Action::Resume(cmd)) => {
            let project_dir = selected_project
                .as_deref()
                .and_then(|p| config.project_dir(p));
            exec_in_project_dir(&cmd, project_dir, selected_project.as_deref())?;
        }
        Ok(Action::Edit(path)) => {
            let editor = config.editor();
            println!("Opening: {} {}", editor, path.display());
            Command::new(&editor).arg(&path).status()?;
        }
        Ok(Action::New) => {
            let (project_name, project_dir) = selected_project
                .as_deref()
                .and_then(|p| config.project_dir(p).map(|d| (p, d)))
                .or_else(|| config.first_project())
                .unzip();
            exec_in_project_dir("claude", project_dir, project_name)?;
        }
        Ok(Action::Quit) | Err(_) => {}
    }

    Ok(())
}

fn exec_in_project_dir(
    cmd: &str,
    project_dir: Option<&str>,
    project_name: Option<&str>,
) -> Result<()> {
    match project_dir {
        Some(dir) => {
            println!("Running: {} (in {})", cmd, dir);
            let parts: Vec<&str> = cmd.split_whitespace().collect();
            if let Some((program, args)) = parts.split_first() {
                Command::new(program).args(args).current_dir(dir).status()?;
            }
            Ok(())
        }
        None => {
            let name = project_name.unwrap_or("(unknown)");
            eprintln!(
                "No project dir configured. Add to ~/.config/skills/issue-config/config.toml:\n\n[projects.{}]\ndir = \"/path/to/{}\"",
                name, name
            );
            Ok(())
        }
    }
}

fn run_loop(terminal: &mut ratatui::DefaultTerminal, app: &mut App) -> Result<Action> {
    loop {
        terminal.draw(|frame| ui::draw(frame, app))?;

        if let Event::Key(key) = event::read()? {
            if key.kind != KeyEventKind::Press {
                continue;
            }
            match key.code {
                KeyCode::Char('q') | KeyCode::Esc => return Ok(Action::Quit),
                KeyCode::Down | KeyCode::Char('j') => app.next(),
                KeyCode::Up | KeyCode::Char('k') => app.previous(),
                KeyCode::Enter => return Ok(app.confirm()),
                KeyCode::Char('e') => {
                    if let Some(issue) = app.selected_issue() {
                        return Ok(Action::Edit(issue.path.clone()));
                    }
                }
                KeyCode::Char('n') => return Ok(Action::New),
                KeyCode::Tab => app.cycle_sort(),
                KeyCode::Char(' ') => app.toggle_collapse(),
                KeyCode::Char('p') => app.toggle_project_collapse(),
                KeyCode::Char('a') => app.toggle_all_projects(),
                _ => {}
            }
        }
    }
}

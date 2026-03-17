use crate::app::App;
use crate::tree::{self, DisplayRow};
use ratatui::{
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Cell, Paragraph, Row, Table},
    Frame,
};

pub fn draw(frame: &mut Frame, app: &App) {
    let chunks = Layout::vertical([
        Constraint::Length(3), // header
        Constraint::Min(5),    // table
        Constraint::Length(5), // detail
        Constraint::Length(1), // help
    ])
    .split(frame.area());

    draw_header(frame, app, chunks[0]);
    draw_table(frame, app, chunks[1]);
    draw_detail(frame, app, chunks[2]);
    draw_help(frame, chunks[3]);
}

fn draw_header(frame: &mut Frame, app: &App, area: Rect) {
    let title = format!(
        "Issue Triage - {}  [sort: {}]",
        app.triage_dir().display(),
        app.sort_mode.label()
    );
    let header = Paragraph::new(title)
        .style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )
        .block(Block::default().borders(Borders::BOTTOM));
    frame.render_widget(header, area);
}

fn draw_table(frame: &mut Frame, app: &App, area: Rect) {
    let display_rows = app.display_rows();

    if display_rows.is_empty() {
        let empty = Paragraph::new("  No issues in triage/  (press n to create)")
            .style(Style::default().fg(Color::DarkGray))
            .block(Block::default().borders(Borders::ALL).title(" Issues "));
        frame.render_widget(empty, area);
        return;
    }

    let header = Row::new(vec![
        Cell::from("TYPE"),
        Cell::from("PRI"),
        Cell::from("TITLE"),
        Cell::from("AREAS"),
    ])
    .style(
        Style::default()
            .fg(Color::DarkGray)
            .add_modifier(Modifier::BOLD),
    )
    .bottom_margin(1);

    let selected_row_idx = tree::selectable_to_row_index(&display_rows, app.selected);

    let rows: Vec<Row> = display_rows
        .iter()
        .enumerate()
        .map(|(i, row)| match row {
            DisplayRow::ProjectHeader {
                name,
                collapsed,
                count,
            } => {
                let arrow = if *collapsed { "▶" } else { "▼" };
                Row::new(vec![
                    Cell::from(format!("{} [{}] ({})", arrow, name, count)).style(
                        Style::default()
                            .fg(Color::White)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Cell::from(""),
                    Cell::from(""),
                    Cell::from(""),
                ])
            }
            DisplayRow::IssueRow {
                issue,
                depth,
                has_children,
                collapsed,
            } => {
                let is_selected = i == selected_row_idx;
                let style = if is_selected {
                    Style::default()
                        .fg(Color::Yellow)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                };

                let type_color = match issue.display_type() {
                    "epic" => Color::Magenta,
                    "feature" => Color::Green,
                    "bug" => Color::Red,
                    "task" => Color::Blue,
                    "research" => Color::Yellow,
                    _ => Color::White,
                };

                let visual_depth = (*depth).min(5);
                let indent = " ".repeat(visual_depth * 2);
                let marker = if *has_children {
                    if *collapsed {
                        "▸ "
                    } else {
                        "▾ "
                    }
                } else {
                    "· "
                };
                let title = if *depth > 5 {
                    format!(
                        "{}{}[d{}] {}",
                        indent, marker, depth, issue.frontmatter.title
                    )
                } else {
                    format!("{}{}{}", indent, marker, issue.frontmatter.title)
                };

                Row::new(vec![
                    Cell::from(issue.display_type()).style(Style::default().fg(type_color)),
                    Cell::from(issue.display_priority()),
                    Cell::from(title),
                    Cell::from(issue.display_areas()),
                ])
                .style(style)
            }
        })
        .collect();

    let widths = [
        Constraint::Length(10),
        Constraint::Length(4),
        Constraint::Min(20),
        Constraint::Length(25),
    ];

    let table = Table::new(rows, widths)
        .header(header)
        .block(Block::default().borders(Borders::ALL).title(" Issues "));

    frame.render_widget(table, area);
}

fn draw_detail(frame: &mut Frame, app: &App, area: Rect) {
    let content = match app.selected_issue() {
        Some(issue) => {
            let resume = issue.resume_command().unwrap_or("(no session)");
            let subs = issue
                .frontmatter
                .sub_issues
                .as_ref()
                .map(|s| format!("sub-issues: {}", s.join(", ")))
                .unwrap_or_default();
            vec![
                Line::from(vec![
                    Span::styled("slug: ", Style::default().fg(Color::DarkGray)),
                    Span::raw(&issue.slug),
                    Span::raw("  "),
                    Span::styled("file: ", Style::default().fg(Color::DarkGray)),
                    Span::raw(issue.path.display().to_string()),
                ]),
                Line::from(vec![
                    Span::styled("project: ", Style::default().fg(Color::DarkGray)),
                    Span::raw(issue.display_project()),
                    Span::raw("  "),
                    Span::styled("status: ", Style::default().fg(Color::DarkGray)),
                    Span::raw(issue.display_status()),
                ]),
                Line::from(vec![
                    Span::styled("resume: ", Style::default().fg(Color::DarkGray)),
                    Span::styled(resume, Style::default().fg(Color::Cyan)),
                ]),
                Line::from(vec![
                    Span::styled("body: ", Style::default().fg(Color::DarkGray)),
                    Span::raw(issue.body_preview()),
                ]),
                if subs.is_empty() {
                    Line::default()
                } else {
                    Line::from(vec![Span::styled(
                        subs,
                        Style::default().fg(Color::DarkGray),
                    )])
                },
            ]
        }
        None => vec![Line::from("(no issue selected)")],
    };

    let detail =
        Paragraph::new(content).block(Block::default().borders(Borders::ALL).title(" Detail "));
    frame.render_widget(detail, area);
}

fn draw_help(frame: &mut Frame, area: Rect) {
    let help = Line::from(vec![
        Span::styled(" ↑/k", Style::default().fg(Color::Yellow)),
        Span::raw(" up  "),
        Span::styled("↓/j", Style::default().fg(Color::Yellow)),
        Span::raw(" down  "),
        Span::styled("Enter", Style::default().fg(Color::Yellow)),
        Span::raw(" resume  "),
        Span::styled("e", Style::default().fg(Color::Yellow)),
        Span::raw(" edit  "),
        Span::styled("n", Style::default().fg(Color::Yellow)),
        Span::raw(" new  "),
        Span::styled("Tab", Style::default().fg(Color::Yellow)),
        Span::raw(" sort  "),
        Span::styled("Space", Style::default().fg(Color::Yellow)),
        Span::raw(" fold issue  "),
        Span::styled("p", Style::default().fg(Color::Yellow)),
        Span::raw(" fold project  "),
        Span::styled("a", Style::default().fg(Color::Yellow)),
        Span::raw(" fold all  "),
        Span::styled("q", Style::default().fg(Color::Yellow)),
        Span::raw(" quit"),
    ]);
    frame.render_widget(Paragraph::new(help), area);
}

//! Диалог конфигурации — параметры окружения и приложения.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};
use ratatui::Frame;

use crate::app::App;
use crate::catalog::CATALOG;
use crate::theme;

pub fn draw(f: &mut Frame, app: &App) {
    if !app.config_dialog_open {
        return;
    }

    let area = centered_rect(76, 90, f.area());
    f.render_widget(Clear, area);

    let marker = Span::styled(" ◆", Style::default().fg(theme::DIALOG_MARKER));
    let title_span = Span::styled(
        " Configuration ",
        Style::default().fg(theme::CONFIG_TITLE).add_modifier(Modifier::BOLD),
    );

    let block = Block::default()
        .title(Line::from(vec![marker, title_span]))
        .title_bottom(Line::from(Span::styled(
            " Esc · i — закрыть ",
            Style::default().fg(theme::CONFIG_BORDER),
        )))
        .borders(Borders::ALL)
        .border_style(Style::default().fg(theme::CONFIG_BORDER))
        .style(Style::default().bg(theme::CONFIG_BG));

    let inner = block.inner(area);
    f.render_widget(block, area);

    // key column = 25, separator "║ " = 2, остаток — под value
    let val_width = (inner.width.saturating_sub(2) as usize).saturating_sub(25 + 2);

    let mut lines: Vec<Line> = Vec::new();

    lines.push(Line::raw(""));

    // Параметры приложения
    lines.push(format_row("Repo root", &app.repo_root.display().to_string(), val_width));
    lines.push(format_row("Time -t", &format!("{}s", app.time_test_s), val_width));
    lines.push(format_row("Wait pause", &format!("{}s", app.time_wait_s), val_width));

    let node_mark = if app.phases.node { "✓" } else { " " };
    lines.push(format_row("Phase node", node_mark, val_width));

    let dc_mark = if app.phases.dc { "✓" } else { " " };
    lines.push(format_row("Phase dc", dc_mark, val_width));

    let count = app.selected.iter().filter(|&&x| x).count();
    let total = CATALOG.len();
    lines.push(format_row("Tests selected", &format!("{} / {}", count, total), val_width));

    let dry_mark = if app.dry_run { "Yes" } else { "No" };
    lines.push(format_row("Dry-run", dry_mark, val_width));

    lines.push(Line::raw(""));

    // Переменные окружения из env.sh
    let cfg = &app.env_config;
    let ev = |k: &str| cfg.get(k).map(|s| s.as_str()).unwrap_or("—").to_string();

    lines.push(format_row("SINGLE_HOST",           &ev("SINGLE_HOST"),           val_width));
    lines.push(format_row("DC_HOSTS",              &ev("DC_HOSTS"),              val_width));
    lines.push(format_row("NET_IFACE",             &ev("NET_IFACE"),             val_width));
    lines.push(format_row("DEFAULT_NET_DELAY",     &ev("DEFAULT_NET_DELAY"),     val_width));
    lines.push(format_row("DEFAULT_NET_LOSS",      &ev("DEFAULT_NET_LOSS"),      val_width));
    lines.push(format_row("DEFAULT_BW_RATE",       &ev("DEFAULT_BW_RATE"),       val_width));
    lines.push(format_row("YDB_PORTS",             &ev("YDB_PORTS"),             val_width));
    lines.push(format_row("YDBD_STORAGE_SERVICE",  &ev("YDBD_STORAGE_SERVICE"),  val_width));
    lines.push(format_row("YDBD_TENANT_SERVICES",  &ev("YDBD_TENANT_SERVICES"),  val_width));
    lines.push(format_row("YDBD_TENANT_UNIT_GLOB", &ev("YDBD_TENANT_UNIT_GLOB"), val_width));
    lines.push(format_row("DEFAULT_MEM_PERCENT",   &ev("DEFAULT_MEM_PERCENT"),   val_width));
    lines.push(format_row("DEFAULT_MEM_RATE",      &ev("DEFAULT_MEM_RATE"),      val_width));
    lines.push(format_row("DEFAULT_DISK_DEVICE",   &ev("DEFAULT_DISK_DEVICE"),   val_width));
    lines.push(format_row("DEFAULT_YDBD_BIN",      &ev("DEFAULT_YDBD_BIN"),      val_width));
    lines.push(format_row("SSH_OPTS",              &ev("SSH_OPTS"),              val_width));
    lines.push(format_row("GRAFANA_URL",           &ev("GRAFANA_URL"),           val_width));
    lines.push(format_row("GRAFANA_TOKEN",         &ev("GRAFANA_TOKEN"),         val_width));

    let p = Paragraph::new(lines)
        .style(Style::default().bg(theme::CONFIG_BG).fg(theme::CONFIG_FG));

    let inner_offset = Rect {
        x: inner.x + 1,
        y: inner.y,
        width: inner.width.saturating_sub(2),
        height: inner.height,
    };

    f.render_widget(p, inner_offset);
}

fn format_row(key: &str, value: &str, val_width: usize) -> Line<'static> {
    Line::from(vec![
        Span::styled(
            format!("{:<25}", key),
            Style::default().fg(theme::CONFIG_FG),
        ),
        Span::styled(
            "║ ",
            Style::default().fg(theme::CONFIG_BORDER),
        ),
        Span::styled(
            truncate_value(value, val_width),
            Style::default().fg(theme::CONFIG_FG),
        ),
    ])
}

fn truncate_value(s: &str, max: usize) -> String {
    if max == 0 { return s.to_string(); }
    let chars: Vec<char> = s.chars().collect();
    if chars.len() > max {
        let truncated: String = chars[..max - 1].iter().collect();
        format!("{}…", truncated)
    } else {
        s.to_string()
    }
}

fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let vert = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(r);
    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(vert[1])[1]
}

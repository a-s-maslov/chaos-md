//! Главная раскладка UI.

pub mod clock;
pub mod config_dialog;
pub mod dialog;
pub mod log;
pub mod progress;
pub mod remaining_time;
pub mod selector;
pub mod status;
pub mod timeline;

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Style;
use ratatui::text::Span;
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::App;

pub fn draw(f: &mut Frame, app: &App) {
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(0), Constraint::Length(1)])
        .split(f.area());

    let menu_bar = outer[0];
    let main_area = outer[1];
    let status_bar = outer[2];

    // main: левая | (центр + timeline) | (часы + статус)
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Length(24),
            Constraint::Min(40),
            Constraint::Length(23),
        ])
        .split(main_area);

    // средняя колонка: лог сверху, timeline снизу
    let mid_rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(10)])
        .split(cols[1]);

    // правая колонка: часы сверху, ETE, ETA, статус снизу
    let right_rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Length(6), Constraint::Length(1), Constraint::Length(1), Constraint::Length(1), Constraint::Min(0)])
        .split(cols[2]);

    selector::draw(f, app, cols[0]);
    log::draw(f, app, mid_rows[0]);
    timeline::draw(f, app, mid_rows[1]);
    clock::draw(f, app, right_rows[1]);
    remaining_time::draw(f, app, right_rows[2]);
    status::draw(f, app, right_rows[5]);

    draw_menu_bar(f, app, menu_bar);
    draw_status_bar(f, app, status_bar);

    // Диалоги — рендерим поверх всего остального.
    if app.config_dialog_open {
        config_dialog::draw(f, app);
    } else {
        dialog::draw(f, app);
    }
}

fn draw_menu_bar(f: &mut Frame, _app: &App, area: Rect) {
    let style = Style::default()
        .bg(ratatui::style::Color::Rgb(55, 63, 67))
        .fg(ratatui::style::Color::Gray);

    let dots = "·".repeat(area.width.saturating_sub(22) as usize);
    let text = format!(" 🗿 Chaos MD · v0.5.1  {}", dots);

    let p = Paragraph::new(ratatui::text::Line::from(text))
        .style(style);
    f.render_widget(p, area);
}

fn draw_status_bar(f: &mut Frame, _app: &App, area: Rect) {
    let style = Style::default()
        .bg(crate::theme::STATUS_BG_DARK)
        .fg(crate::theme::DIM);

    let parts = [
        ("Tab", "Фокус"),
        ("c", "Проверка"),
        ("i", "Конфиг"),
        ("S", "Запустить хаос!"),
    ];

    let mut left_spans = Vec::new();
    for (k, v) in parts {
        left_spans.push(Span::styled(format!(" {k} "), Style::default().bg(crate::theme::CYBER_GRAY).fg(crate::theme::OK).add_modifier(ratatui::style::Modifier::BOLD)));
        left_spans.push(Span::styled(format!(" {v}  "), Style::default().bg(crate::theme::STATUS_BG_DARK).fg(ratatui::style::Color::White)));
    }

    let right_text = " YDB · 2026 ";

    let right_style = Style::default()
        .bg(crate::theme::STATUS_BG_DARK)
        .fg(crate::theme::DIM)
        .add_modifier(ratatui::style::Modifier::BOLD);
    let right_p = Paragraph::new(ratatui::text::Line::from(right_text))
        .style(right_style)
        .alignment(ratatui::layout::Alignment::Right);
    
    // Рендерим левую часть
    let left_p = Paragraph::new(ratatui::text::Line::from(left_spans))
        .style(style);
    
    // Разделяем область на левую и правую части
    let layout = Layout::default()
        .direction(ratatui::layout::Direction::Horizontal)
        .constraints([
            ratatui::layout::Constraint::Min(0),  // левая часть растягивается
            ratatui::layout::Constraint::Length(right_text.len() as u16),  // правая часть фиксированная
        ])
        .split(area);
    
    f.render_widget(left_p, layout[0]);
    f.render_widget(right_p, layout[1]);
}

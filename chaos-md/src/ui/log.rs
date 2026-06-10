//! Центральная зона: PTY-вывод текущего теста + scrollbar + прогресс-бар текущего шага.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState, Wrap};
use ratatui::Frame;
use ratatui_braille_bar::BrailleBar;

use crate::ansi::parse_ansi_line;
use crate::app::{App, Focus, RunnerStatus};
use crate::queue::Step;
use crate::theme;

pub fn draw(f: &mut Frame, app: &App, area: Rect) {
    let focused = app.focus == Focus::Log;
    let title = if let Some((_, _)) = app.running_step() {
        format!(" ♦ Запуск ({}/{}) ", app.step_count().0, app.step_count().1)
    } else {
        " ♦ Запуск ".to_string()
    };
    let block = Block::default()
        .title(Span::styled(title, theme::block_title(focused)))
        .borders(Borders::ALL)
        .border_style(theme::block_border(focused));
    let inner = block.inner(area);
    f.render_widget(block, area);

    // Разделяем область: лог сверху, прогресс-бар снизу
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(1)])
        .split(inner);

    let log_area = chunks[0];
    let progress_area = chunks[1];

    // Собираем строки: история + (current_line, если есть)
    let mut lines: Vec<Line> = app.log_lines.iter().cloned().collect();
    if let Some(cur) = &app.log_current {
        lines.push(parse_ansi_line(cur));
    }

    if lines.is_empty() {
        // Анимированная надпись ГОТОВ (шрифт Брайля)
        // Генератор: https://lazesoftware.com/en/tool/brailleaagen/
        let ready_art = [
            r#"⠘⣿⣷⡀⡀⡀⡀⣾⣿⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⢰⣿⣷⡀⣿⣿⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
            r#"⡀⢹⣿⣆⡀⡀⣸⣿⠇⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⠘⠛⠛⡀⠛⠛⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
            r#"⡀⡀⢿⣿⡀⢀⣿⡟⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
            r#"⡀⡀⠈⣿⣿⣿⣿⡀⡀⡀⡀⣶⣿⣿⣿⣿⡄⡀⡀⢀⣾⣿⣿⣿⣷⡀⡀⡀⣰⣿⣿⣿⣿⣦⡀⡀⡀⡀⡀⡀⠹⣿⣆⡀⡀⣿⡇⡀⢠⣿⡟⡀⡀⡀⡀⣿⣿⣿⣿⣿⡀⡀⡀⢀⣾⣿⣿⣿⣷⡀⡀⣿⣿⣿⣿⣿⣿⡀"#,
            r#"⡀⡀⡀⠸⣿⣿⠃⡀⡀⡀⢸⣿⡏⡀⡀⣿⣿⡀⡀⣿⣿⠁⡀⢸⣿⣧⡀⡀⣿⣿⡀⡀⣿⣿⡀⡀⡀⡀⡀⡀⡀⢻⣿⡄⡀⣿⡇⡀⣿⣿⡀⡀⡀⡀⡀⣿⡇⡀⣿⣿⡀⡀⡀⣿⣿⠁⡀⢸⣿⡇⡀⡀⡀⣿⣿⡀⡀⡀"#,
            r#"⡀⡀⡀⣼⣿⣿⡄⡀⡀⡀⡀⡀⡀⡀⣀⣿⣿⡀⡀⣿⣿⡀⡀⢸⣿⣿⡀⡀⣿⣿⡀⡀⠙⠛⡀⡀⡀⡀⡀⡀⡀⡀⢿⣿⡀⣿⡇⣼⣿⠁⡀⡀⡀⡀⡀⣿⡇⡀⣿⣿⡀⡀⡀⣿⣿⣀⣀⣸⣿⣿⡀⡀⡀⣿⣿⡀⡀⡀"#,
            r#"⡀⡀⢠⣿⡟⣿⣿⡀⡀⡀⡀⣠⣾⣿⠛⣿⣿⡀⡀⣿⣿⡀⡀⢸⣿⣿⡀⡀⣿⣿⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⢠⣿⠗⣿⡗⣿⣇⡀⡀⡀⡀⡀⢸⣿⠃⡀⣿⣿⡀⡀⡀⣿⣿⠛⠛⠛⠛⠛⡀⡀⡀⣿⣿⡀⡀⡀"#,
            r#"⡀⡀⣿⣿⡀⠘⣿⣷⡀⡀⢰⣿⡟⡀⡀⣿⣿⡀⡀⣿⣿⡀⡀⢸⣿⣿⡀⡀⣿⣿⡀⡀⣶⣶⡀⡀⡀⡀⡀⡀⡀⢀⣿⡿⡀⣿⡇⠹⣿⡄⡀⡀⡀⡀⣿⣿⡀⡀⣿⣿⡀⡀⡀⣿⣿⡀⡀⢠⣤⣤⡀⡀⡀⣿⣿⡀⡀⡀"#,
            r#"⡀⣼⣿⠃⡀⡀⢹⣿⣆⡀⢸⣿⣧⡀⣠⣿⣿⡀⡀⢿⣿⡄⡀⣸⣿⡏⡀⡀⣿⣿⡀⡀⣿⣿⡀⡀⡀⡀⡀⡀⡀⣿⣿⡀⡀⣿⡇⡀⢻⣿⡀⡀⢀⣾⡿⠁⡀⡀⣿⣿⡀⡀⡀⢿⣿⡄⡀⢸⣿⡇⡀⡀⡀⣿⣿⡀⡀⡀"#,
            r#"⢠⣿⡿⡀⡀⡀⡀⢿⣿⡀⡀⢿⣿⣿⠋⣿⣿⡀⡀⡀⠿⣿⣿⣿⠟⡀⡀⡀⠙⢿⣿⣿⣿⠋⡀⡀⡀⡀⡀⡀⣾⣿⠁⡀⡀⣿⡇⡀⡀⣿⣿⡀⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⡀⠈⠿⣿⣿⣿⠟⡀⡀⡀⡀⣿⣿⡀⡀⡀"#,
            r#"⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⣿⣿⡀⡀⡀⡀⡀⡀⣿⡇⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
            r#"⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⠿⠟⡀⡀⡀⡀⡀⡀⠿⠇⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
        ];
        
        let art_height = ready_art.len() as u16;
        let art_width = ready_art[0].chars().count() as u16;
        
        // Центрирование
        let y_offset = inner.height.saturating_sub(art_height) / 2;
        let x_offset = inner.width.saturating_sub(art_width) / 2;
        
        let now = chrono::Local::now().timestamp_millis();
        
        let mut art_lines = vec![Line::raw(""); y_offset as usize];
        
        let now_sec = now as f64 / 1000.0;
        
        // Логика редких вспышек с паузами
        // Окно в 3 секунды
        let window = (now_sec / 3.0).floor() as u64;
        // Псевдослучайный хэш окна (0..100)
        let window_hash = (window * 12345) % 100;
        // Вспышка происходит, если хэш > 30 (70% окон имеют вспышку) и только в первые 0.25 сек окна
        let in_glint_phase = window_hash > 30 && (now_sec % 3.0) < 0.25;
        
        for (i, &line) in ready_art.iter().enumerate() {
            let mut spans = vec![Span::raw(" ".repeat(x_offset as usize))];
            
            for (j, ch) in line.chars().enumerate() {
                if ch == '⡀' || ch == ' ' {
                    // Заменяем пустые символы Брайля на обычные пробелы, чтобы убрать "точки заполнения"
                    spans.push(Span::raw(" "));
                    continue;
                }
                
                // Плавная волна с помощью синуса
                // Очень широкая волна (делитель 100.0) и очень медленное движение (умножитель 0.3)
                let phase = ((j as f64 + i as f64 * 2.0) / 100.0 - now_sec * 0.3) * std::f64::consts::PI * 2.0;
                let sin_val = (phase.sin() + 1.0) / 2.0; // от 0.0 до 1.0
                
                // Эффект редких резких бликов
                let hash = (i * 313 + j * 177 + (now / 50) as usize) % 1000;
                let is_glint = in_glint_phase && hash > 980; // 2% шанс во время фазы вспышки
                
                let style = if is_glint {
                    // Яркий белый блик
                    Style::default().fg(ratatui::style::Color::White).add_modifier(ratatui::style::Modifier::BOLD)
                } else {
                    // Приглушенные оттенки от темно-зеленого до темно-цианового с бОльшим контрастом
                    let r = 0;
                    let g = 20 + (80.0 * sin_val) as u8; // 20 .. 100
                    let b = 10 + (90.0 * sin_val) as u8; // 10 .. 100
                    Style::default().fg(ratatui::style::Color::Rgb(r, g, b)) // Без BOLD для приглушенности
                };
                
                spans.push(Span::styled(ch.to_string(), style));
            }
            art_lines.push(Line::from(spans));
            // Рисуем прогресс-бар текущего шага под логом
            let (step_progress, _) = match &app.runner {
                RunnerStatus::Running { started_at, step_idx, .. } => {
                    let elapsed = started_at.elapsed().as_secs_f64();
                    let step = &app.queue[*step_idx];
                    let duration = match step {
                        Step::Run { .. } => app.time_test_s as f64,
                        Step::Pause { seconds, .. } => *seconds as f64,
                        Step::Teardown { .. } => 5.0, // Примерное время
                    };
                    let ratio = (elapsed / duration).clamp(0.0, 1.0);
                    (ratio, format!("Текущий шаг: {:.0}%", ratio * 100.0))
                }
                _ => (0.0, "Ожидание...".to_string()),
            };
        
            f.render_widget(BrailleBar::new(step_progress, 1.0).fill_color(theme::ACCENT), progress_area);
        }
        
        let p = Paragraph::new(art_lines);
        f.render_widget(p, log_area);
        
        // Рисуем прогресс-бар текущего шага под логом
        let (step_progress, _) = match &app.runner {
            RunnerStatus::Running { started_at, step_idx, .. } => {
                let elapsed = started_at.elapsed().as_secs_f64();
                let step = &app.queue[*step_idx];
                let duration = match step {
                    Step::Run { .. } => app.time_test_s as f64,
                    Step::Pause { seconds, .. } => *seconds as f64,
                    Step::Teardown { .. } => 5.0, // Примерное время
                };
                let ratio = (elapsed / duration).clamp(0.0, 1.0);
                (ratio, format!("Текущий шаг: {:.0}%", ratio * 100.0))
            }
            _ => (0.0, "Ожидание...".to_string()),
        };
        
        f.render_widget(BrailleBar::new(step_progress, 1.0).fill_color(theme::ACCENT), progress_area);
        return;
    }

    let total = lines.len();
    let viewport = log_area.height as usize;
    // log_scroll = 0 → стик к низу; >0 → отступ строк от низа.
    let scroll = app.log_scroll.min(total.saturating_sub(viewport));
    let bottom = total.saturating_sub(scroll);
    let top = bottom.saturating_sub(viewport);
    let visible = lines[top..bottom].to_vec();

    let p = Paragraph::new(visible).wrap(Wrap { trim: false });
    f.render_widget(p, log_area);

    // Scrollbar справа (внутри log_area, но визуально на правом краю области).
    if total > viewport {
        let mut state = ScrollbarState::new(total).position(top);
        let sb = Scrollbar::new(ScrollbarOrientation::VerticalRight)
            .begin_symbol(None)
            .end_symbol(None);
        f.render_stateful_widget(sb, log_area, &mut state);
    }
    
    // Рисуем прогресс-бар текущего шага под логом
    let (step_progress, _) = match &app.runner {
        RunnerStatus::Running { started_at, step_idx, .. } => {
            let elapsed = started_at.elapsed().as_secs_f64();
            let step = &app.queue[*step_idx];
            let duration = match step {
                Step::Run { .. } => app.time_test_s as f64,
                Step::Pause { seconds, .. } => *seconds as f64,
                Step::Teardown { .. } => 5.0, // Примерное время
            };
            let ratio = (elapsed / duration).clamp(0.0, 1.0);
            (ratio, format!("Текущий шаг: {:.0}%", ratio * 100.0))
        }
        _ => (0.0, "Ожидание...".to_string()),
    };

    f.render_widget(BrailleBar::new(step_progress, 1.0).fill_color(theme::ACCENT), progress_area);
}

// Подавляем «unused field» в state-структурах: эти поля задействуются в
// будущих фичах (auto-restart, Finished-таймер, расширение CurrentEvent),
// держим без скобок-плейсхолдеров.
#![allow(dead_code)]

mod ansi;
mod app;
mod catalog;
mod queue;
mod runner;
mod state;
mod theme;
mod ui;
mod watcher;

use std::io::{self, stdout};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use chrono::Local;
use clap::Parser;
use crossterm::event::{Event, EventStream, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use futures::StreamExt;
use ratatui::backend::CrosstermBackend;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::Terminal;
use tokio::sync::mpsc;

use crate::ansi::LogParser;
use crate::app::{App, CheckDialog, CurrentEvent, Focus, RunnerStatus, SelectorItem};
use crate::catalog::CATALOG;
use crate::queue::{Phases, Step};
use crate::runner::{describe, spawn_step, RunnerEvent, Running};
use crate::theme as col;
use crate::watcher::{TimelineLine, WatcherEvent};

/// События от фоновой команды `./NN-test.sh -C`.
enum CheckLine {
    Text(String),
    Done,
}

#[derive(Parser, Debug)]
#[command(name = "chaos-md", version, about = "TUI for YDB chaos tests")]
struct Cli {
    /// Корень репозитория (где лежат NN-*.sh, env.sh, lib/, nemesis/).
    #[arg(long, value_name = "PATH")]
    root: Option<PathBuf>,

    /// Headless-режим: запустить выбранные тесты без TUI.
    #[arg(long)]
    headless: bool,

    /// CSV id тестов для headless (например: 04,05,11). По умолчанию — все.
    #[arg(long)]
    tests: Option<String>,

    /// Длительность фазы -t, секунды.
    #[arg(short = 't', long, default_value_t = 1200)]
    time_test: u32,

    /// Пауза между шагами, секунды.
    #[arg(short = 'p', long, default_value_t = 600)]
    time_wait: u32,

    /// Включить фазу -1 (node).
    #[arg(long, default_value_t = true)]
    node: bool,

    /// Включить фазу -4 (dc).
    #[arg(long, default_value_t = true)]
    dc: bool,

    /// Dry-run: тесты не выполняют ssh/scp, только показывают что бы запустилось.
    /// Используется для отладки UI и сценариев без реального стенда.
    #[arg(short = 'd', long)]
    dry_run: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let root = match cli.root.clone() {
        Some(p) => p,
        None => std::env::current_dir().context("getcwd")?,
    };
    let root = root
        .canonicalize()
        .with_context(|| format!("canonicalize {root:?}"))?;

    if cli.headless {
        return run_headless(&cli, &root).await;
    }
    run_tui(&root, cli.dry_run).await
}

// =============================================================================
// TUI
// =============================================================================

async fn run_tui(root: &PathBuf, dry_run: bool) -> Result<()> {
    enable_raw_mode()?;
    let mut out = stdout();
    execute!(out, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(out);
    let mut term = Terminal::new(backend)?;
    term.hide_cursor()?;

    let result = event_loop(&mut term, root, dry_run).await;

    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen)?;
    term.show_cursor()?;
    result
}

async fn event_loop<B: ratatui::backend::Backend>(
    term: &mut Terminal<B>,
    root: &PathBuf,
    dry_run: bool,
) -> Result<()> {
    let mut app = App::new(root.clone());
    app.dry_run = dry_run;
    let _ = state::load(root, &mut app);
    let mut log_parser = LogParser::new();

    let (wtx, mut wrx) = mpsc::unbounded_channel::<WatcherEvent>();
    let _watcher_handle = watcher::spawn(app.timeline_path.clone(), wtx)
        .context("starting timeline watcher")?;

    let mut current_running: Option<Running> = None;
    let mut current_runner_rx: Option<mpsc::UnboundedReceiver<RunnerEvent>> = None;
    let mut start_pending = false;
    let mut check_rx: Option<mpsc::UnboundedReceiver<CheckLine>> = None;

    let mut events = EventStream::new();
    let mut tick = tokio::time::interval(Duration::from_millis(50)); // 20 FPS для плавной анимации
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        if app.force_redraw {
            app.force_redraw = false;
            term.clear()?;
        }
        term.draw(|f| ui::draw(f, &app))?;

        if app.should_quit {
            if let Some(r) = &mut current_running {
                let _ = r.kill();
            }
            return Ok(());
        }

        // Если очередь готова и Idle — стартуем.
        if start_pending && matches!(app.runner, RunnerStatus::Idle) && !app.queue.is_empty() {
            start_pending = false;
            start_queue(&mut app, &mut current_running, &mut current_runner_rx, term)?;
        }

        // Запрос на открытие диалога Check.
        if let Some(test_idx) = app.pending_check.take() {
            open_check_dialog(&mut app, test_idx, &mut check_rx, root);
        }

        tokio::select! {
            biased;

            maybe_evt = events.next() => {
                if let Some(Ok(Event::Key(k))) = maybe_evt {
                    if k.kind == KeyEventKind::Press {
                        let request_start = on_key(&mut app, k);
                        if request_start {
                            app.queue = queue::build(&app.selected, app.phases, app.time_wait_s);
                            if !app.queue.is_empty() {
                                app.runner = RunnerStatus::Idle;
                                start_pending = true;
                            }
                        }
                    }
                }
            }

            Some(WatcherEvent::Line(tl)) = wrx.recv() => {
                push_timeline_event(&mut app, tl);
            }

            maybe_runner_evt = recv_runner(&mut current_runner_rx) => {
                let step_done = match maybe_runner_evt {
                    Some(re) => handle_runner_event(&mut app, &mut log_parser, re),
                    None => current_running.is_some(),
                };
                if step_done {
                    current_running = None;
                    current_runner_rx = None;
                    advance_queue(&mut app, &mut current_running, &mut current_runner_rx, term)?;
                }
            }

            maybe_check = recv_check(&mut check_rx) => {
                match maybe_check {
                    Some(CheckLine::Text(line)) => {
                        if let Some(d) = &mut app.check_dialog {
                            d.lines.push(line);
                        }
                    }
                    Some(CheckLine::Done) | None => {
                        if let Some(d) = &mut app.check_dialog {
                            d.loading = false;
                        }
                        check_rx = None;
                    }
                }
            }

            _ = tick.tick() => {
                if app.stop_requested && app.is_running() {
                    app.stop_requested = false;
                    if let Some(r) = &mut current_running {
                        let _ = r.kill();
                    }
                    current_running = None;
                    current_runner_rx = None;
                    app.runner = RunnerStatus::Idle;
                    app.finished_tests.clear();
                    app.finished_tests.resize(app.selected.len(), false);
                }
            }
        }
    }
}

/// Выбрать recv() из current_runner_rx, либо вечно ждать.
async fn recv_runner(
    rx: &mut Option<mpsc::UnboundedReceiver<RunnerEvent>>,
) -> Option<RunnerEvent> {
    match rx {
        Some(r) => r.recv().await,
        None => std::future::pending::<Option<RunnerEvent>>().await,
    }
}

async fn recv_check(rx: &mut Option<mpsc::UnboundedReceiver<CheckLine>>) -> Option<CheckLine> {
    match rx {
        Some(r) => r.recv().await,
        None => std::future::pending::<Option<CheckLine>>().await,
    }
}

// =============================================================================
// Ввод
// =============================================================================

/// Возвращает true, если по результату обработки нужно стартовать очередь.
fn on_key(app: &mut App, k: KeyEvent) -> bool {
    // Диалоги открыты — поглощаем все клавиши.
    if app.check_dialog.is_some() {
        on_key_dialog(app, k);
        return false;
    }
    if app.config_dialog_open {
        on_key_config_dialog(app, k);
        return false;
    }

    // Ctrl+C / q → выход (приоритет выше диалога).
    if (k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL))
        || k.code == KeyCode::Char('q')
    {
        if app.is_running() && !app.quit_pending {
            app.quit_pending = true;
            return false;
        }
        app.should_quit = true;
        return false;
    }
    if app.quit_pending {
        match k.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => app.should_quit = true,
            _ => app.quit_pending = false,
        }
        return false;
    }

    // 'c' (без модификаторов) → открыть Check для выделенного теста.
    if k.code == KeyCode::Char('c') && k.modifiers.is_empty() {
        if let SelectorItem::Test(idx) = app.current_selector_item() {
            app.pending_check = Some(idx);
        }
        return false;
    }

    // 'i' → открыть диалог конфигурации.
    if k.code == KeyCode::Char('i') && k.modifiers.is_empty() {
        app.config_dialog_open = true;
        return false;
    }

    // 'K' → очистка логов и таймлайна.
    if k.code == KeyCode::Char('K') && k.modifiers.is_empty() {
        app.log_lines.clear();
        app.log_current = None;
        app.timeline_lines.clear();
        return false;
    }

    // 'R' → полная перерисовка экрана.
    if k.code == KeyCode::Char('R') && k.modifiers.is_empty() {
        app.force_redraw = true;
        return false;
    }

    // Ctrl+R → то же.
    if k.code == KeyCode::Char('r') && k.modifiers.contains(KeyModifiers::CONTROL) {
        app.force_redraw = true;
        return false;
    }

    if k.code == KeyCode::Tab {
        if app.focus == Focus::Selector {
            if matches!(app.current_selector_item(), SelectorItem::Start) {
                app.focus = Focus::Log;
            } else {
                let start_idx = SelectorItem::all().len() - 1;
                app.selector_idx = start_idx;
            }
        } else {
            match app.focus {
                Focus::Log => { app.focus = Focus::Timeline; }
                Focus::Timeline => {
                    app.focus = Focus::Selector;
                    app.selector_idx = 0;
                }
                Focus::Selector => { app.focus = Focus::Log; }
            }
        }
        return false;
    }

    match app.focus {
        Focus::Selector => on_key_selector(app, k),
        Focus::Log => {
            on_key_scroll(&mut app.log_scroll, k);
            false
        }
        Focus::Timeline => {
            on_key_scroll(&mut app.timeline_scroll, k);
            false
        }
    }
}

fn on_key_dialog(app: &mut App, k: KeyEvent) {
    match k.code {
        KeyCode::Esc | KeyCode::Char('c') | KeyCode::Char('q') => {
            app.check_dialog = None;
        }
        KeyCode::Up => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = d.scroll.saturating_sub(1);
            }
        }
        KeyCode::Down => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = d.scroll.saturating_add(1);
            }
        }
        KeyCode::PageUp => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = d.scroll.saturating_sub(20);
            }
        }
        KeyCode::PageDown => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = d.scroll.saturating_add(20);
            }
        }
        KeyCode::Home => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = 0;
            }
        }
        KeyCode::End => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = usize::MAX / 2;
            }
        }
        _ => {}
    }
}

fn on_key_config_dialog(app: &mut App, k: KeyEvent) {
    match k.code {
        KeyCode::Esc | KeyCode::Char('i') | KeyCode::Char('q') => {
            app.config_dialog_open = false;
        }
        _ => {}
    }
}

fn on_key_selector(app: &mut App, k: KeyEvent) -> bool {
    match k.code {
        KeyCode::Up => app.selector_move(-1),
        KeyCode::Down => app.selector_move(1),
        KeyCode::Char(' ') => {
            if matches!(app.current_selector_item(), SelectorItem::Start) {
                if app.is_running() {
                    app.stop_requested = true;
                } else {
                    return true;
                }
            } else {
                toggle_current(app);
                let _ = state::save(app);
            }
        }
        KeyCode::Char('S') => {
            if app.is_running() {
                app.stop_requested = true;
            } else {
                return true;
            }
        }
        KeyCode::Enter => {
            if matches!(app.current_selector_item(), SelectorItem::Start) {
                return true;
            } else {
                toggle_current(app);
                let _ = state::save(app);
            }
        }
        KeyCode::Backspace => match app.current_selector_item() {
            SelectorItem::TimeTest => {
                app.time_test_s /= 10;
                let _ = state::save(app);
            }
            SelectorItem::TimeWait => {
                app.time_wait_s /= 10;
                let _ = state::save(app);
            }
            _ => {}
        },
        KeyCode::Char(c) if c.is_ascii_digit() => {
            let d = c as u32 - '0' as u32;
            let mut changed = false;
            match app.current_selector_item() {
                SelectorItem::TimeTest => {
                    let n = app.time_test_s.saturating_mul(10).saturating_add(d);
                    if n <= 100_000 {
                        app.time_test_s = n;
                        changed = true;
                    }
                }
                SelectorItem::TimeWait => {
                    let n = app.time_wait_s.saturating_mul(10).saturating_add(d);
                    if n <= 100_000 {
                        app.time_wait_s = n;
                        changed = true;
                    }
                }
                _ => {}
            }
            if changed {
                let _ = state::save(app);
            }
        }
        _ => {}
    }
    false
}

fn toggle_current(app: &mut App) {
    match app.current_selector_item() {
        SelectorItem::Test(idx) => app.selected[idx] = !app.selected[idx],
        SelectorItem::PhaseNode => app.phases.node = !app.phases.node,
        SelectorItem::PhaseDc => app.phases.dc = !app.phases.dc,
        SelectorItem::DryRun => app.dry_run = !app.dry_run,
        _ => {}
    }
}

fn on_key_scroll(scroll: &mut usize, k: KeyEvent) {
    match k.code {
        KeyCode::PageUp => *scroll = scroll.saturating_add(10),
        KeyCode::PageDown => *scroll = scroll.saturating_sub(10),
        KeyCode::Up => *scroll = scroll.saturating_add(1),
        KeyCode::Down => *scroll = scroll.saturating_sub(1),
        KeyCode::Home => *scroll = usize::MAX,
        KeyCode::End => *scroll = 0,
        _ => {}
    }
}

// =============================================================================
// Очередь
// =============================================================================

fn start_queue<B: ratatui::backend::Backend>(
    app: &mut App,
    current_running: &mut Option<Running>,
    current_runner_rx: &mut Option<mpsc::UnboundedReceiver<RunnerEvent>>,
    term: &mut Terminal<B>,
) -> Result<()> {
    if app.queue.is_empty() {
        return Ok(());
    }
    app.log_lines.clear();
    app.log_current = None;
    app.timeline_lines.clear();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: Local::now(),
    };
    spawn_current(app, current_running, current_runner_rx, term)
}

fn advance_queue<B: ratatui::backend::Backend>(
    app: &mut App,
    current_running: &mut Option<Running>,
    current_runner_rx: &mut Option<mpsc::UnboundedReceiver<RunnerEvent>>,
    term: &mut Terminal<B>,
) -> Result<()> {
    let (step_idx, next_idx) = match &app.runner {
        RunnerStatus::Running { step_idx, .. } => (*step_idx, step_idx + 1),
        _ => return Ok(()),
    };

    if let Some(Step::Run { test_idx, .. }) = app.queue.get(step_idx) {
        app.finished_tests[*test_idx] = true;
    }

    if next_idx >= app.queue.len() {
        app.runner = RunnerStatus::Finished {
            ok: true,
            at: Instant::now(),
        };
        app.finished_tests.clear();
        app.finished_tests.resize(app.selected.len(), false);
        return Ok(());
    }
    app.runner = RunnerStatus::Running {
        step_idx: next_idx,
        started_at: Instant::now(),
        started_wall: Local::now(),
    };

    let test_idx_to_select = app.queue.get(next_idx).and_then(|st| {
        match st {
            Step::Run { test_idx, .. } => Some(*test_idx),
            Step::Pause { after_test_idx, .. } => *after_test_idx,
            Step::Teardown { test_idx } => Some(*test_idx),
        }
    });

    if let Some(test_idx) = test_idx_to_select {
        let items = SelectorItem::all();
        for (i, item) in items.iter().enumerate() {
            if *item == SelectorItem::Test(test_idx) {
                app.selector_idx = i;
                break;
            }
        }
    }

    spawn_current(app, current_running, current_runner_rx, term)
}

fn spawn_current<B: ratatui::backend::Backend>(
    app: &mut App,
    current_running: &mut Option<Running>,
    current_runner_rx: &mut Option<mpsc::UnboundedReceiver<RunnerEvent>>,
    term: &mut Terminal<B>,
) -> Result<()> {
    let RunnerStatus::Running { step_idx, .. } = app.runner else {
        return Ok(());
    };
    let step: Step = app.queue[step_idx].clone();

    let size = term.size()?;
    let cols = size.width.saturating_sub(28).saturating_sub(24).max(40);
    let rows = size.height.saturating_sub(11).max(10);

    push_log_line(app, Line::raw(""));
    push_local_log(app, format!("¤ {}", describe(&step, app.time_test_s)));

    match spawn_step(&app.repo_root, &step, app.time_test_s, app.dry_run, cols, rows) {
        Ok((running, rx)) => {
            *current_running = Some(running);
            *current_runner_rx = Some(rx);
        }
        Err(e) => {
            push_local_log(app, format!("ОШИБКА spawn: {e}"));
            app.runner = RunnerStatus::Finished {
                ok: false,
                at: Instant::now(),
            };
        }
    }
    Ok(())
}

/// Возвращает true, если step завершён (Exited).
fn handle_runner_event(app: &mut App, parser: &mut LogParser, evt: RunnerEvent) -> bool {
    match evt {
        RunnerEvent::Bytes(b) => {
            let upd = parser.feed(&b);
            for line in upd.new_lines {
                push_log_line(app, line);
            }
            if let Some(ref cur) = upd.current_line {
                if cur.contains('⏱') && app.chaos_started_at.is_none() {
                    app.chaos_started_at = Some(Instant::now());
                }
            }
            app.log_current = upd.current_line;
            false
        }
        RunnerEvent::Exited { ok, code } => {
            push_local_log(
                app,
                format!(
                    "[exit code={}{}]",
                    code.map(|c| c.to_string())
                        .unwrap_or_else(|| "?".into()),
                    if ok { "" } else { ", FAIL" },
                ),
            );
            *parser = LogParser::new();
            app.log_current = None;
            app.chaos_started_at = None;
            true
        }
    }
}

fn push_log_line(app: &mut App, line: Line<'static>) {
    if app.log_lines.len() >= app.log_max {
        app.log_lines.pop_front();
    }
    app.log_lines.push_back(line);
}

fn push_local_log(app: &mut App, text: String) {
    let line = Line::from(Span::styled(
        text,
        Style::default()
            .fg(col::DIM)
            .add_modifier(Modifier::ITALIC),
    ));
    push_log_line(app, line);
}

fn push_timeline_event(app: &mut App, tl: TimelineLine) {
    use ratatui::style::Color;
    let color = match tl.kind.as_str() {
        "CHAOS_START" => Color::Green,
        "CHAOS_END" => Color::Cyan,
        "CHAOS_CANCEL" => Color::Red,
        _ => Color::White,
    };
    let line = Line::from(vec![
        Span::raw(
            tl.started_wall
                .map(|d| d.format("%H:%M:%S ").to_string())
                .unwrap_or_else(|| "?? ".to_string()),
        ),
        Span::styled(
            format!("{:14}", tl.kind),
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
        Span::raw(tl.details.clone()),
    ]);

    if app.timeline_lines.len() >= app.timeline_max {
        app.timeline_lines.pop_front();
    }
    app.timeline_lines.push_back(line);

    if tl.kind == "CHAOS_START" {
        let ev: CurrentEvent = tl.to_current_event();
        app.current_event = Some(ev);
    } else if tl.kind.starts_with("CHAOS_END") || tl.kind == "CHAOS_CANCEL" {
        app.current_event = None;
    }
}

// =============================================================================
// Check dialog
// =============================================================================

fn open_check_dialog(
    app: &mut App,
    test_idx: usize,
    check_rx: &mut Option<mpsc::UnboundedReceiver<CheckLine>>,
    root: &std::path::Path,
) {
    let entry = &CATALOG[test_idx];
    app.check_dialog = Some(CheckDialog {
        title: format!("Check: {} {}", entry.id, entry.title),
        lines: Vec::new(),
        scroll: 0,
        loading: true,
    });

    let (tx, rx) = mpsc::unbounded_channel::<CheckLine>();
    *check_rx = Some(rx);

    let file = format!("./{}", entry.file);
    let root = root.to_path_buf();

    tokio::task::spawn_blocking(move || {
        use std::process::{Command, Stdio};
        let out = Command::new("bash")
            .arg(&file)
            .arg("-C")
            .current_dir(&root)
            .env("TERM", "dumb")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        match out {
            Err(e) => {
                let _ = tx.send(CheckLine::Text(format!("Ошибка запуска: {e}")));
            }
            Ok(output) => {
                let combined = [output.stdout, b"\n--- stderr ---\n".to_vec(), output.stderr].concat();
                for line in String::from_utf8_lossy(&combined).lines() {
                    if tx.send(CheckLine::Text(line.to_string())).is_err() {
                        return;
                    }
                }
            }
        }
        let _ = tx.send(CheckLine::Done);
    });
}

// =============================================================================
// Headless
// =============================================================================

async fn run_headless(cli: &Cli, root: &PathBuf) -> Result<()> {
    use std::io::Write;
    let mut selected = vec![false; catalog::CATALOG.len()];
    if let Some(csv) = &cli.tests {
        for id in csv.split(',') {
            let id = id.trim();
            if let Some(i) = catalog::find_by_id(id) {
                selected[i] = true;
            } else {
                eprintln!("Неизвестный test id: {id}");
            }
        }
    } else {
        for s in selected.iter_mut() {
            *s = true;
        }
    }
    let phases = Phases {
        node: cli.node,
        dc: cli.dc,
        dc_alt: false,
    };
    let queue = queue::build(&selected, phases, cli.time_wait);

    println!("Очередь ({} шагов):", queue.len());
    for (i, st) in queue.iter().enumerate() {
        println!("  {}. {}", i + 1, describe(st, cli.time_test));
    }
    println!();

    for (i, st) in queue.iter().enumerate() {
        println!("=== [{}/{}] {} ===", i + 1, queue.len(), describe(st, cli.time_test));
        let _ = std::io::stdout().flush();
        let (mut running, mut rx) = spawn_step(root, st, cli.time_test, cli.dry_run, 120, 30)?;
        while let Some(evt) = rx.recv().await {
            match evt {
                RunnerEvent::Bytes(b) => {
                    std::io::stdout().write_all(&b).ok();
                }
                RunnerEvent::Exited { ok, code } => {
                    println!("[exit {:?} ok={ok}]", code);
                    break;
                }
            }
        }
        let _ = running.kill();
    }
    println!("Готово.");
    Ok(())
}

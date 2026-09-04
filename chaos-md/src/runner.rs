//! Запуск bash-тестов в PTY и стрим байтов в основной runtime через mpsc.
//!
//! Один вызов `spawn_step` запускает один Step::Run / Step::Teardown и
//! возвращает handle с каналом байтов и каналом завершения.

use std::io::Read;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use tokio::sync::mpsc;

use crate::catalog::CATALOG;
use crate::queue::Step;

#[derive(Debug)]
pub enum RunnerEvent {
    /// Байты, прочитанные из PTY.
    Bytes(Vec<u8>),
    /// Процесс завершился. ok = true если exit-код 0.
    Exited { ok: bool, code: Option<i32> },
}

/// Handle на запущенный процесс. Drop killit процесс.
pub struct Running {
    /// Сигнальный флаг — установить true, чтобы остановить чтение из PTY.
    pub stop: Arc<AtomicBool>,
    /// Master-half PTY (нужно держать живым, иначе reader получит EOF).
    _master: Box<dyn portable_pty::MasterPty + Send>,
    /// Child handle для kill при необходимости.
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

impl Running {
    pub fn kill(&mut self) -> Result<()> {
        self.stop.store(true, Ordering::SeqCst);
        let _ = self.child.kill();
        Ok(())
    }
}

/// Запустить один Step в PTY. Возвращает handle и приёмник событий.
///
/// Step::Run / Step::Teardown — exec bash-тест; Step::Pause запускает
/// фоновый sleep, отправляющий Exited по истечении.
pub fn spawn_step(
    repo_root: &Path,
    step: &Step,
    time_test_s: u32,
    dry_run: bool,
    cols: u16,
    rows: u16,
) -> Result<(Running, mpsc::UnboundedReceiver<RunnerEvent>)> {
    let (tx, rx) = mpsc::unbounded_channel();
    let (file, args) = build_command(step, time_test_s, dry_run)?;

    // Step::Pause не имеет файла — спавним отдельный «искусственный» процесс
    // (bash sleep N). Это даёт корректный exit и общий PTY-канал.
    let _ = file; // используется в build_command; держим единый путь

    let pty_system = native_pty_system();
    let pair = pty_system.openpty(PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    })?;

    // На Linux достаточно bash из PATH. На Windows системный bash.exe может
    // оказаться WSL launcher-ом, поэтому путь можно задать явно.
    let bash_bin =
        std::env::var("CHAOS_BASH_BIN").unwrap_or_else(|_| "bash".to_string());
    let mut cmd = CommandBuilder::new(bash_bin);
    cmd.cwd(repo_root);
    cmd.arg("-o");
    cmd.arg("pipefail");
    for a in &args {
        cmd.arg(a);
    }
    cmd.env("TERM", "xterm-256color");
    cmd.env("FORCE_COLOR", "1");
    cmd.env("COLORTERM", "truecolor");

    let child = pair.slave.spawn_command(cmd)?;
    drop(pair.slave);

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| anyhow!("PTY clone_reader: {e}"))?;

    let stop = Arc::new(AtomicBool::new(false));
    let stop_reader = stop.clone();
    let tx_reader = tx.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            if stop_reader.load(Ordering::SeqCst) {
                break;
            }
            match reader.read(&mut buf) {
                Ok(0) => break, // EOF
                Ok(n) => {
                    let _ = tx_reader.send(RunnerEvent::Bytes(buf[..n].to_vec()));
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    });

    // Watcher на child.wait в отдельном потоке.
    // portable_pty::Child::wait — блокирующий, нельзя дёргать в async.
    // Берём владение через mutex/option-замок, watcher потом thread-spawn.
    // Здесь упростим: не отдаём child за пределы, а спавним watcher,
    // используя try_wait в коротком цикле — этого достаточно.
    //
    // Поскольку Child нужен для kill в Running и для wait тут одновременно,
    // используем shared Mutex.
    use std::sync::Mutex;
    let child_mx: Arc<Mutex<Box<dyn portable_pty::Child + Send + Sync>>> =
        Arc::new(Mutex::new(child));
    let child_for_wait = child_mx.clone();
    let tx_wait = tx.clone();
    let stop_wait = stop.clone();
    std::thread::spawn(move || {
        loop {
            if stop_wait.load(Ordering::SeqCst) { break; }
            let result_opt = {
                let mut g = child_for_wait.lock().unwrap();
                g.try_wait().ok().flatten()
            };
            if let Some(status) = result_opt {
                let code = status.exit_code() as i32;
                let ok = code == 0;
                let _ = tx_wait.send(RunnerEvent::Exited { ok, code: Some(code) });
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    });

    // Поскольку child уже отдан в Mutex, для kill нам нужен отдельный
    // путь — заведём отдельный Mutex-аналог.
    // Простой выход: дублируем через Arc; но Box<dyn Child> не Clone.
    // Поэтому Running.child — это другой Arc<Mutex<...>>, выставляющий kill.
    let child_for_kill = child_mx;

    let running = Running {
        stop,
        _master: pair.master,
        child: ChildProxy(child_for_kill).into_box(),
    };

    Ok((running, rx))
}

/// Адаптер: Arc<Mutex<Box<dyn Child>>> → impl Child (для удобной упаковки в Running).
#[derive(Debug)]
struct ChildProxy(std::sync::Arc<std::sync::Mutex<Box<dyn portable_pty::Child + Send + Sync>>>);

impl ChildProxy {
    fn into_box(self) -> Box<dyn portable_pty::Child + Send + Sync> {
        Box::new(self)
    }
}

impl portable_pty::ChildKiller for ChildProxy {
    fn kill(&mut self) -> std::io::Result<()> {
        let mut g = self.0.lock().unwrap();
        g.kill()
    }
    fn clone_killer(&self) -> Box<dyn portable_pty::ChildKiller + Send + Sync> {
        Box::new(ChildProxy(self.0.clone()))
    }
}

impl portable_pty::Child for ChildProxy {
    fn try_wait(&mut self) -> std::io::Result<Option<portable_pty::ExitStatus>> {
        let mut g = self.0.lock().unwrap();
        g.try_wait()
    }
    fn wait(&mut self) -> std::io::Result<portable_pty::ExitStatus> {
        let mut g = self.0.lock().unwrap();
        g.wait()
    }
    fn process_id(&self) -> Option<u32> {
        let g = self.0.lock().unwrap();
        g.process_id()
    }
    #[cfg(windows)]
    fn as_raw_handle(&self) -> Option<std::os::windows::io::RawHandle> {
        let g = self.0.lock().unwrap();
        g.as_raw_handle()
    }
}

/// Сформировать (имя_теста, аргументы для bash) для Step.
/// Если dry_run=true — добавляет --dry-run в bash-вызов теста (Pause не трогаем).
fn build_command(step: &Step, time_test_s: u32, dry_run: bool) -> Result<(String, Vec<String>)> {
    match step {
        Step::Run { test_idx, scope } => {
            let entry = &CATALOG[*test_idx];
            let mut args = vec![format!("./{}", entry.file), scope.flag().to_string()];
            args.push("-t".to_string());
            args.push(time_test_s.to_string());
            if entry.nemesis == "blade" {
                args.push("-T".to_string());
                args.push(time_test_s.to_string());
            }
            if dry_run {
                args.push("--dry-run".to_string());
            }
            Ok((entry.file.to_string(), args))
        }
        Step::Teardown { test_idx } => {
            let entry = &CATALOG[*test_idx];
            let mut args = vec![format!("./{}", entry.file), "-D".to_string()];
            if dry_run {
                args.push("--dry-run".to_string());
            }
            Ok((entry.file.to_string(), args))
        }
        Step::Pause { seconds, .. } => {
            // bash -c "sleep N" — даёт нам корректный child + exit code.
            // Pause не нуждается в dry-run, ничего удалённого не делает.
            let args = vec!["-c".to_string(), format!("sleep {seconds}")];
            Ok(("pause".to_string(), args))
        }
    }
}

/// Описание текущего Step для UI.
pub fn describe(step: &Step, _time_test_s: u32) -> String {
    match step {
        Step::Run { test_idx, scope } => {
            let e = &CATALOG[*test_idx];
            format!("{} {} ({})", e.id, e.title, scope.label())
        }
        Step::Teardown { test_idx } => {
            let e = &CATALOG[*test_idx];
            format!("{} teardown", e.id)
        }
        Step::Pause { seconds, .. } => format!("pause {seconds}s"),
    }
}

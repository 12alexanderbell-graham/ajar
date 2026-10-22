//! Nocturnal's tray app. One engine thread owns every decision and every OS change; the main thread only draws the
//! tray menu and forwards clicks. Also `nocturnal-app watchdog`, run every minute by the OS scheduler.

#![cfg_attr(windows, windows_subsystem = "windows")]

use nocturnal::engine::{run_watchdog, Engine};
use nocturnal::icon::{self, TrayState};
use nocturnal::menu::{self, Action, Node, UiState};
use nocturnal::platform::{self, Platform};
use nocturnal::{ipc, procs, remote, state};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tray_icon::menu::{
    CheckMenuItem, IsMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu,
};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};

static TERMINATE: AtomicBool = AtomicBool::new(false);

enum UserEvent {
    Refresh,
    Menu(String),
    /// The tray icon was clicked (the menu is probably open).
    TrayClick,
}

/// How long after a click on the tray icon a menu rebuild is held back. Rebuilding replaces the menu and
/// closes it under the pointer; text and ticks are still updated in place meanwhile.
const MENU_OPEN_GRACE: Duration = Duration::from_secs(20);

enum Cmd {
    Action(Action),
    /// A command from the phone panel, answered on the channel. Dropped unanswered if it's still queued at
    /// the deadline: the relay thread has already told the phone Nocturnal is busy, so a retry mustn't run it twice.
    Remote(String, Value, Sender<Value>, Instant),
    RemoteStatus(Option<String>),
    /// A paired phone sent a valid command: (phone id, its device name if it sent one).
    PhoneSeen(String, Option<String>),
    Quit,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("watchdog") {
        let mut p = platform::native();
        let r = run_watchdog(&mut p, &state::dir(), false);
        println!("{r}");
        return;
    }
    let root = state::dir();
    let Some(_lock) = single_instance(&root) else {
        // Already running: nothing to do (the existing tray icon is the app).
        return;
    };
    install_signal_handlers();

    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let shared: Arc<Mutex<Option<UiState>>> = Arc::new(Mutex::new(None));
    let (tx, rx) = channel::<Cmd>();

    {
        let proxy = proxy.clone();
        MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
            let _ = proxy.send_event(UserEvent::Menu(e.id.0.clone()));
        }));
    }
    {
        let proxy = proxy.clone();
        TrayIconEvent::set_event_handler(Some(move |e: TrayIconEvent| {
            if matches!(e, TrayIconEvent::Click { .. }) {
                let _ = proxy.send_event(UserEvent::TrayClick);
            }
        }));
    }
    {
        let (shared, proxy, tx2, root) = (shared.clone(), proxy.clone(), tx.clone(), root.clone());
        std::thread::Builder::new()
            .name("nocturnal-engine".into())
            .spawn(move || engine_thread(root, rx, tx2, shared, proxy))
            .expect("start engine thread");
    }

    let mut tray: Option<TrayIcon> = None;
    let mut rendered: Option<Rendered> = None;
    let mut last_icon: Option<TrayState> = None;
    let mut menu_clicked: Option<Instant> = None;
    let mut deferred = false;
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        let event = match event {
            // A held-back rebuild comes due.
            Event::NewEvents(StartCause::ResumeTimeReached { .. }) if deferred => {
                Event::UserEvent(UserEvent::Refresh)
            }
            other => other,
        };
        match event {
            Event::UserEvent(UserEvent::TrayClick) => {
                menu_clicked = Some(Instant::now());
            }
            Event::NewEvents(StartCause::Init) => {
                let icon = tray_icon(TrayState::Idle);
                let built = Rendered::build(&[Node::Text {
                    id: "head".into(),
                    text: "Starting…".into(),
                    enabled: false,
                }]);
                tray = TrayIconBuilder::new()
                    .with_icon(icon)
                    .with_tooltip("Nocturnal")
                    .with_menu(Box::new(built.menu.clone()))
                    .with_menu_on_left_click(true)
                    .build()
                    .ok();
                rendered = Some(built);
                last_icon = Some(TrayState::Idle);
            }
            Event::UserEvent(UserEvent::Refresh) => {
                let Some(t) = &tray else { return };
                let Some(s) = shared.lock().ok().and_then(|g| g.clone()) else {
                    return;
                };
                let nodes = menu::build(&s);
                match &rendered {
                    Some(r) if r.shape == menu::shape(&nodes) => {
                        r.update(&nodes);
                        deferred = false;
                    }
                    Some(r) if menu_clicked.is_some_and(|at| at.elapsed() < MENU_OPEN_GRACE) => {
                        r.update(&nodes);
                        deferred = true;
                        *control_flow = ControlFlow::WaitUntil(
                            menu_clicked.unwrap_or_else(Instant::now) + MENU_OPEN_GRACE,
                        );
                    }
                    _ => {
                        let r = Rendered::build(&nodes);
                        t.set_menu(Some(Box::new(r.menu.clone())));
                        rendered = Some(r);
                        deferred = false;
                    }
                }
                if last_icon != Some(s.tray) {
                    let _ = t.set_icon(Some(tray_icon(s.tray)));
                    last_icon = Some(s.tray);
                }
                let _ = t.set_tooltip(Some(s.tooltip()));
            }
            Event::UserEvent(UserEvent::Menu(id)) => {
                menu_clicked = None; // choosing an item closes the menu
                if let Some(a) = menu::action(&id) {
                    match a {
                        Action::EditConfig => open_settings_file(&state::file("config.json")),
                        Action::OpenFolder => open_target(&state::dir().to_string_lossy()),
                        Action::Quit => {
                            let _ = tx.send(Cmd::Quit);
                        }
                        other => {
                            let _ = tx.send(Cmd::Action(other));
                        }
                    }
                }
            }
            _ => {}
        }
    });
}

fn tray_icon(s: TrayState) -> Icon {
    let size = 32;
    Icon::from_rgba(icon::tray(s, size), size, size).expect("valid icon")
}

/// The real menu items, kept so text and ticks can be updated in place (safe while the menu is open).
struct Rendered {
    menu: Menu,
    shape: String,
    texts: HashMap<String, MenuItem>,
    checks: HashMap<String, CheckMenuItem>,
    subs: HashMap<String, Submenu>,
}

impl Rendered {
    fn build(nodes: &[Node]) -> Rendered {
        let mut r = Rendered {
            menu: Menu::new(),
            shape: menu::shape(nodes),
            texts: HashMap::new(),
            checks: HashMap::new(),
            subs: HashMap::new(),
        };
        let items = r.make(nodes);
        for i in &items {
            let _ = r.menu.append(i.as_ref());
        }
        r
    }

    fn make(&mut self, nodes: &[Node]) -> Vec<Box<dyn IsMenuItem>> {
        let mut out: Vec<Box<dyn IsMenuItem>> = vec![];
        for n in nodes {
            match n {
                Node::Text { id, text, enabled } => {
                    let m = MenuItem::with_id(id.as_str(), text, *enabled, None);
                    self.texts.insert(id.clone(), m.clone());
                    out.push(Box::new(m));
                }
                Node::Check {
                    id,
                    text,
                    checked,
                    enabled,
                } => {
                    let m = CheckMenuItem::with_id(id.as_str(), text, *enabled, *checked, None);
                    self.checks.insert(id.clone(), m.clone());
                    out.push(Box::new(m));
                }
                Node::Sub { id, text, children } => {
                    let s = Submenu::with_id(id.as_str(), text, true);
                    for c in self.make(children) {
                        let _ = s.append(c.as_ref());
                    }
                    self.subs.insert(id.clone(), s.clone());
                    out.push(Box::new(s));
                }
                Node::Sep => out.push(Box::new(PredefinedMenuItem::separator())),
            }
        }
        out
    }

    fn update(&self, nodes: &[Node]) {
        for n in nodes {
            match n {
                Node::Text { id, text, enabled } => {
                    if let Some(m) = self.texts.get(id) {
                        if m.text() != *text {
                            m.set_text(text);
                        }
                        m.set_enabled(*enabled);
                    }
                }
                Node::Check {
                    id, text, checked, ..
                } => {
                    if let Some(m) = self.checks.get(id) {
                        if m.text() != *text {
                            m.set_text(text);
                        }
                        // The OS flips a check item when clicked; always re-assert what is actually in effect.
                        m.set_checked(*checked);
                    }
                }
                Node::Sub { id, text, children } => {
                    if let Some(s) = self.subs.get(id) {
                        if s.text() != *text {
                            s.set_text(text);
                        }
                    }
                    self.update(children);
                }
                Node::Sep => {}
            }
        }
    }
}

// MARK: engine thread

struct RemoteHandle {
    stop: Arc<AtomicBool>,
}

fn start_remote(root: &Path, tx: Sender<Cmd>) -> Option<RemoteHandle> {
    let settings = remote::Settings::load(root);
    if !settings.enabled || settings.usable().is_empty() {
        return None;
    }
    let stop = Arc::new(AtomicBool::new(false));
    let stop2 = stop.clone();
    let tx_status = tx.clone();
    let tx_seen = tx.clone();
    let cursor = root.join("remote-cursor");
    std::thread::Builder::new()
        .name("nocturnal-remote".into())
        .spawn(move || {
            remote::listen(
                settings,
                cursor,
                stop2,
                |cmd, args| {
                    let (rtx, rrx) = channel();
                    if tx
                        .send(Cmd::Remote(
                            cmd.to_string(),
                            args,
                            rtx,
                            Instant::now() + Duration::from_secs(10),
                        ))
                        .is_err()
                    {
                        return json!({ "ok": false, "error": "Nocturnal is quitting" });
                    }
                    // A little longer than the deadline, so a command started just before it can still answer.
                    rrx.recv_timeout(Duration::from_secs(15))
                        .unwrap_or_else(|_| json!({ "ok": false, "error": "Nocturnal is busy" }))
                },
                |err| {
                    let _ = tx_status.send(Cmd::RemoteStatus(err));
                },
                |id, name| {
                    let _ = tx_seen.send(Cmd::PhoneSeen(id.to_string(), name));
                },
            )
        })
        .ok()?;
    Some(RemoteHandle { stop })
}

fn engine_thread(
    root: PathBuf,
    rx: Receiver<Cmd>,
    tx: Sender<Cmd>,
    shared: Arc<Mutex<Option<UiState>>>,
    proxy: EventLoopProxy<UserEvent>,
) {
    let mut e = Engine::new(platform::native(), root.clone(), procs::snapshot());
    // First run: register the watchdog (it puts things back if Nocturnal ever dies while it has changed something).
    if !root.join("installed").exists() && e.platform.install_watchdog().is_ok() {
        state::touch(&root.join("installed"));
    }
    let mut remote = start_remote(&root, tx.clone());
    let mut last_tick = Instant::now() - Duration::from_secs(10);
    let mut wakes = e.wakes();
    let approve_paths = nocturnal::approve::Paths::new(&root);
    // First click on "Approve everything" arms a confirmation for 30 s; only the second click turns it on.
    let mut approve_armed: Option<Instant> = None;
    let mut last_ui: Option<UiState> = None;
    loop {
        let mut changed = false;
        match rx.recv_timeout(Duration::from_millis(250)) {
            Ok(Cmd::Quit) => quit(&mut e, remote.as_ref(), &approve_paths),
            Ok(Cmd::Action(Action::ApproveToggle)) => {
                if nocturnal::approve::is_on(&approve_paths) {
                    let msg = match nocturnal::approve::turn_off(&approve_paths) {
                        Ok(()) => "Off. Your previous Claude Code and Codex settings are back."
                            .to_string(),
                        Err(err) => err,
                    };
                    e.outbox.push(nocturnal::engine::Announcement {
                        title: "Approve everything".into(),
                        body: msg,
                    });
                } else {
                    approve_armed = Some(Instant::now());
                }
                changed = true;
            }
            Ok(Cmd::Action(Action::ApproveConfirm(ends))) => {
                if approve_armed
                    .take()
                    .is_some_and(|t| t.elapsed() < Duration::from_secs(30))
                {
                    let hours = (ends == nocturnal::approve::Ends::Time).then_some(8.0);
                    let msg = match nocturnal::approve::turn_on(&approve_paths, ends, hours, nocturnal::now()) {
                        Ok(()) => format!(
                            "On. New Claude Code and Codex sessions won't ask before acting; running ones keep their mode. {}.",
                            nocturnal::approve::ends_line(&approve_paths).unwrap_or_default()
                        ),
                        Err(err) => err,
                    };
                    e.outbox.push(nocturnal::engine::Announcement {
                        title: "Approve everything".into(),
                        body: msg,
                    });
                }
                changed = true;
            }
            Ok(Cmd::Action(a)) => {
                apply(&mut e, a, &root, &tx, &mut remote);
                changed = true;
            }
            Ok(Cmd::Remote(_, _, _, deadline)) if Instant::now() >= deadline => {}
            Ok(Cmd::Remote(cmd, args, reply, _)) => {
                let r = if remote::ALLOWED.contains(&cmd.as_str()) {
                    e.handle(&cmd, &args)
                } else {
                    json!({ "ok": false, "error": "not allowed" })
                };
                let _ = reply.send(remote::phone_reply(
                    &cmd,
                    &r,
                    e.panel_json(nocturnal::now()),
                ));
                changed = true;
            }
            Ok(Cmd::RemoteStatus(s)) => {
                e.remote_status = s;
                changed = true;
            }
            Ok(Cmd::PhoneSeen(id, name)) => {
                let mut s = remote::Settings::load(&root);
                if let Some(p) = s.phones.iter_mut().find(|p| p.id == id) {
                    let now = nocturnal::now();
                    // Saved at most once a minute unless the name changed: a phone polls every few seconds.
                    let renamed = name.as_ref().is_some_and(|n| *n != p.name);
                    let stale = p.last_seen.is_none_or(|t| now.saturating_sub(t) > 60);
                    if let Some(n) = name {
                        p.name = n;
                    }
                    p.last_seen = Some(now);
                    if renamed || stale {
                        s.save(&root);
                        changed = true;
                    }
                }
            }
            Err(_) => {}
        }
        if TERMINATE.load(Ordering::SeqCst) {
            quit(&mut e, remote.as_ref(), &approve_paths);
        }
        for (id, cmd, args) in ipc::take_requests(&root) {
            if cmd == "quit" {
                ipc::reply(&root, &id, &json!({ "ok": true }));
                quit(&mut e, remote.as_ref(), &approve_paths);
            }
            let r = e.handle(&cmd, &args);
            ipc::reply(&root, &id, &r);
            changed = true;
        }
        if last_tick.elapsed() >= Duration::from_secs(2) {
            last_tick = Instant::now();
            e.tick(nocturnal::now(), Some(procs::snapshot()));
            if e.wakes() != wakes {
                wakes = e.wakes();
                // Just woke: the relay connection is probably dead without knowing it. Start a fresh listener
                // now (it carries on from the saved cursor); the old one quits at its next line or timeout
                // without handling anything more.
                if remote.is_some() {
                    restart_remote(&root, &tx, &mut remote);
                }
            }
            if e.ticks().is_multiple_of(5) {
                check_approve(&mut e, &approve_paths);
            }
            deliver(&mut e);
            if e.ticks().is_multiple_of(30) {
                ipc::sweep_replies(&root);
            }
            changed = true;
        }
        if changed {
            let mut ui = UiState::from_engine(&e, nocturnal::now());
            let rs = remote::Settings::load(&root);
            ui.phone_on = rs.enabled && remote.is_some();
            ui.phones = rs
                .phones
                .iter()
                .map(|p| (p.id.clone(), p.name.clone(), p.last_seen))
                .collect();
            ui.auto_approve = nocturnal::approve::is_on(&approve_paths);
            ui.approve_line = nocturnal::approve::ends_line(&approve_paths);
            if approve_armed.is_some_and(|t| t.elapsed() >= Duration::from_secs(30)) {
                approve_armed = None;
            }
            ui.approve_confirm = approve_armed.is_some();
            if last_ui.as_ref() != Some(&ui) {
                if let Ok(mut g) = shared.lock() {
                    *g = Some(ui.clone());
                }
                last_ui = Some(ui);
                let _ = proxy.send_event(UserEvent::Refresh);
            }
        }
    }
}

/// "Approve everything" turns itself off when the work finishes or its time is up, and keeps retrying if
/// something couldn't be put back.
fn check_approve<P: Platform>(e: &mut Engine<P>, p: &nocturnal::approve::Paths) {
    if !nocturnal::approve::is_on(p) {
        return;
    }
    // Agent work only: Always, timers and terminal holds don't count as "the work".
    let working = e.work_reason(nocturnal::now()).is_some();
    if working {
        nocturnal::approve::mark_work(p);
    }
    let Some(why) = nocturnal::approve::expiry(p, working, nocturnal::now()) else {
        return;
    };
    let ok = nocturnal::approve::turn_off(p).is_ok();
    if why != "retry" || ok {
        e.outbox.push(nocturnal::engine::Announcement {
            title: "Approve everything is off".into(),
            body: if ok {
                format!("{why}, so Claude Code and Codex ask before acting again.")
            } else {
                "Couldn't put your Claude Code and Codex settings back yet; Nocturnal keeps trying."
                    .into()
            },
        });
    }
}

fn quit<P: Platform>(
    e: &mut Engine<P>,
    remote: Option<&RemoteHandle>,
    approve: &nocturnal::approve::Paths,
) -> ! {
    if let Some(r) = remote {
        r.stop.store(true, Ordering::SeqCst);
    }
    e.shutdown();
    // Nothing will be watching for the work to finish or the time to run out once Nocturnal has quit.
    nocturnal::approve::end_unwatched(approve);
    std::process::exit(0);
}

fn apply<P: Platform>(
    e: &mut Engine<P>,
    a: Action,
    root: &Path,
    tx: &Sender<Cmd>,
    remote: &mut Option<RemoteHandle>,
) {
    match a {
        Action::Mode(m) => e.set_mode(m),
        Action::StayFor(min) => e.stay_awake(Some(min)),
        Action::StayUntil(h) => {
            let now = nocturnal::now();
            e.stay_awake(Some(
                nocturnal::format::next_local_hour(now, h)
                    .saturating_sub(now)
                    .div_ceil(60),
            ));
        }
        Action::Preset(p) => e.update(|c| c.preset = p),
        Action::LowPower => e.update(|c| c.low_power_while_closed = !c.low_power_while_closed),
        Action::Floor(f) => e.update(|c| c.battery_floor = f),
        Action::OverrideFloor => e.override_floor(true),
        Action::Quiet(Some(q)) => e.update(|c| {
            c.sleep_when_done = true;
            c.quiet_minutes = q;
        }),
        Action::Quiet(None) => e.update(|c| c.sleep_when_done = false),
        Action::Notify => e.update(|c| c.notify_done = !c.notify_done),
        Action::OnlyOnPower => e.update(|c| c.only_on_power = !c.only_on_power),
        Action::HeatGuard => e.update(|c| c.heat_guard = !c.heat_guard),
        Action::ClaudeApp => e.update(|c| c.count_claude_app = !c.count_claude_app),
        Action::OpenAtLogin => e.update(|c| c.open_at_login = !c.open_at_login),
        Action::TrackOnly(id) => e.toggle_track_only(&id),
        Action::Watch(key) => e.toggle_watch_key(&key),
        Action::ReleaseHolds => {
            e.release_hold(None);
        }
        Action::SleepNow => e.sleep_now(),
        Action::Retry => e.retry_restore(),
        Action::NtfyOn => {
            let topic = menu::new_topic();
            e.update(|c| c.ntfy_topic = topic.clone());
            open_target(&format!("https://ntfy.sh/{topic}"));
        }
        Action::NtfyOpen => open_target(&format!("https://ntfy.sh/{}", e.cfg.ntfy_topic)),
        Action::NtfyOff => e.update(|c| c.ntfy_topic.clear()),
        Action::PhonePair => {
            let mut s = remote::Settings::load(root);
            if s.panel_url.is_empty() {
                s.panel_url = default_panel_url();
            }
            s.enabled = true;
            let Some(phone) = s.add_phone(nocturnal::now()) else {
                e.outbox.push(nocturnal::engine::Announcement {
                    title: "Phone control".into(),
                    body: format!(
                        "{} phones are paired; revoke one first.",
                        remote::MAX_PHONES
                    ),
                });
                return;
            };
            if !s.save(root) {
                e.outbox.push(nocturnal::engine::Announcement {
                    title: "Phone control".into(),
                    body: "Couldn't save the pairing key.".into(),
                });
                return;
            }
            restart_remote(root, tx, remote);
            show_pairing(root, &s, &phone);
        }
        Action::PhoneRevoke(id) => {
            let mut s = remote::Settings::load(root);
            s.phones.retain(|p| p.id != id);
            s.save(root);
            restart_remote(root, tx, remote);
        }
        Action::PhoneRevokeAll => {
            let mut s = remote::Settings::load(root);
            s.phones.clear();
            s.save(root);
            let _ = std::fs::remove_file(root.join("remote-cursor"));
            restart_remote(root, tx, remote);
        }
        Action::PhoneOn => {
            let mut s = remote::Settings::load(root);
            s.enabled = true;
            s.save(root);
            restart_remote(root, tx, remote);
        }
        Action::PhoneOff => {
            let mut s = remote::Settings::load(root);
            s.enabled = false;
            s.save(root);
            if let Some(r) = remote.take() {
                r.stop.store(true, Ordering::SeqCst);
            }
            e.remote_status = None;
        }
        Action::CheckIn(m) => e.update(|c| c.check_in_minutes = m),
        Action::WakeAt(h) => {
            let now = nocturnal::now();
            e.set_wake(Some(nocturnal::format::next_local_hour(now, h)), None);
        }
        Action::WakeOff => e.set_wake(None, None),
        Action::EditConfig
        | Action::OpenFolder
        | Action::Quit
        | Action::ApproveToggle
        | Action::ApproveConfirm(_) => {}
    }
}

/// Where the phone page is served from (nocturnal.tools/remote). To host it elsewhere, set `panelUrl` in remote.json.
fn default_panel_url() -> String {
    option_env!("NOCTURNAL_PANEL_URL")
        .unwrap_or("https://nocturnal.tools/remote/")
        .to_string()
}

/// Stops the phone listener and starts one for the phones paired now.
fn restart_remote(root: &Path, tx: &Sender<Cmd>, remote: &mut Option<RemoteHandle>) {
    if let Some(r) = remote.take() {
        r.stop.store(true, Ordering::SeqCst);
    }
    *remote = start_remote(root, tx.clone());
}

fn show_pairing(root: &Path, s: &remote::Settings, phone: &remote::Phone) {
    let page = root.join("phone.html");
    let html = match s.pairing_link(phone) {
        Some(link) => remote::pairing_page(&link),
        None => format!(
            "<!doctype html><meta charset=utf-8><title>Nocturnal phone control</title><body style=\"font:16px system-ui;max-width:520px;margin:40px auto;padding:0 16px\"><h1>One step left</h1><p>Nocturnal doesn't know the phone page's address. Add <code>\"panelUrl\": \"https://nocturnal.tools/remote/\"</code> (or your own copy of that page) to <code>{}</code> and choose Pair a Phone again.</p></body>",
            root.join("remote.json").display()
        ),
    };
    if state::write_atomic(&page, &html).is_ok() {
        open_target(&page.to_string_lossy());
    }
}

/// Shows notifications and pushes them to the phone (ntfy) off the engine thread.
fn deliver<P: Platform>(e: &mut Engine<P>) {
    let items = std::mem::take(&mut e.outbox);
    if items.is_empty() {
        return;
    }
    let topic = e.cfg.ntfy_topic.clone();
    for a in &items {
        e.platform.notify(&a.title, &a.body);
    }
    if !topic.is_empty() && nocturnal::config::valid_topic(&topic) {
        std::thread::spawn(move || {
            for a in items {
                let url = format!(
                    "https://ntfy.sh/{topic}?title={}",
                    nocturnal::format::url_encode(&a.title)
                );
                let _ = ureq::post(&url).send(a.body.as_str());
            }
        });
    }
}

// MARK: OS helpers

fn open_target(target: &str) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new("explorer.exe")
            .arg(target)
            .creation_flags(0x0800_0000)
            .spawn();
    }
    #[cfg(not(windows))]
    {
        let _ = std::process::Command::new("xdg-open").arg(target).spawn();
    }
}

fn open_settings_file(p: &Path) {
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("notepad.exe").arg(p).spawn();
    }
    #[cfg(not(windows))]
    {
        open_target(&p.to_string_lossy());
    }
}

/// One Nocturnal per user. The lock is held for the life of the process and released by the OS when it exits.
#[cfg(unix)]
fn single_instance(root: &Path) -> Option<std::fs::File> {
    use std::os::unix::io::AsRawFd;
    let f = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(root.join("app.lock"))
        .ok()?;
    let r = unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    (r == 0).then_some(f)
}

#[cfg(windows)]
fn single_instance(_root: &Path) -> Option<isize> {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
    use windows_sys::Win32::System::Threading::CreateMutexW;
    let name: Vec<u16> = "Local\\NocturnalTrayApp"
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let h = unsafe { CreateMutexW(std::ptr::null(), 1, name.as_ptr()) };
    if h.is_null() || unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        return None;
    }
    Some(h as isize)
}

#[cfg(unix)]
fn install_signal_handlers() {
    extern "C" fn on_signal(_: libc::c_int) {
        TERMINATE.store(true, Ordering::SeqCst);
    }
    unsafe {
        for s in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::signal(s, on_signal as *const () as libc::sighandler_t);
        }
    }
}

#[cfg(windows)]
fn install_signal_handlers() {}

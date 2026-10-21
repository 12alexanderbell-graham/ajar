//! What the tray menu shows, as plain data. The app turns this into real menu items; keeping it here means
//! every label and every rule about what appears when is covered by tests, and the menu can be updated in
//! place (text and ticks only) whenever its structure hasn't changed, which is safe even while it's open.

use crate::config::{Mode, Preset};
use crate::engine::Engine;
use crate::icon::TrayState;
use crate::platform::Platform;

#[derive(Clone, Debug, PartialEq)]
pub enum Node {
    Text { id: String, text: String, enabled: bool },
    Check { id: String, text: String, checked: bool, enabled: bool },
    Sub { id: String, text: String, children: Vec<Node> },
    Sep,
}

fn text(id: &str, t: impl Into<String>) -> Node {
    Node::Text { id: id.into(), text: t.into(), enabled: true }
}
fn info(id: &str, t: impl Into<String>) -> Node {
    Node::Text { id: id.into(), text: t.into(), enabled: false }
}
fn check(id: &str, t: impl Into<String>, checked: bool) -> Node {
    Node::Check { id: id.into(), text: t.into(), checked, enabled: true }
}
fn sub(id: &str, t: impl Into<String>, children: Vec<Node>) -> Node {
    Node::Sub { id: id.into(), text: t.into(), children }
}

#[derive(Clone, Debug, PartialEq)]
pub struct AgentRow {
    pub id: String,
    pub name: String,
    pub working: bool,
    pub idle_minutes: Option<u64>,
    pub project: Option<String>,
    pub keeps_awake: bool,
}

/// Everything the menu needs, copied out of the engine on its own thread.
#[derive(Clone, Debug, PartialEq)]
pub struct UiState {
    pub keeps: bool,
    /// Ajar is holding the laptop awake right now (offers Sleep Now).
    pub holding: bool,
    pub headline: String,
    pub detail: String,
    /// What the selected mode does, in one sentence.
    pub mode_line: String,
    /// "64% · about 6 h 05 min with the lid closed".
    pub battery: Option<String>,
    pub warning: Option<String>,
    pub tray: TrayState,
    pub agents: Vec<AgentRow>,
    pub holds: Vec<(String, String, Option<u64>)>,
    pub mode: Mode,
    pub on_until: Option<u64>,
    pub preset: Preset,
    pub low_power: bool,
    pub floor: u32,
    pub can_override_floor: bool,
    pub sleep_when_done: bool,
    pub quiet: u32,
    pub notify_done: bool,
    pub only_on_power: bool,
    pub heat_guard: bool,
    pub heat_available: bool,
    pub claude_app: bool,
    pub open_at_login: bool,
    pub ntfy_topic: String,
    pub recent: Vec<String>,
    /// (executable key, name, kept awake while it runs)
    pub watch: Vec<(String, String, bool)>,
    pub unrestored: Vec<String>,
    pub phone_on: bool,
    pub phone_status: Option<String>,
    pub snoozed: bool,
}

impl UiState {
    pub fn from_engine<P: Platform>(e: &Engine<P>, now: u64) -> UiState {
        let (keeps, headline, detail) = e.outcome();
        let wanted = e.blocked.is_some() || e.setup_error.is_some();
        let tray = if e.holding { TrayState::Awake } else if wanted && e.cfg.mode != Mode::Off { TrayState::Blocked } else { TrayState::Idle };
        let mut seen = std::collections::HashSet::new();
        let agents = e
            .watcher
            .sessions
            .iter()
            .filter(|s| seen.insert(s.kind.id.clone()))
            .map(|s| AgentRow {
                id: s.kind.id.clone(),
                name: s.kind.name.clone(),
                working: s.working(now),
                idle_minutes: (s.last_active > 0).then(|| now.saturating_sub(s.last_active) / 60),
                project: s.project.clone().filter(|p| !p.is_empty()),
                keeps_awake: !e.cfg.track_only.contains(&s.kind.id),
            })
            .collect();
        let recent = e
            .stats
            .sessions
            .iter()
            .rev()
            .take(5)
            .map(|r| {
                let mut s = format!("{} · {} closed", crate::format::when(r.date, now), crate::format::minutes(r.closed_minutes));
                if let (Some(a), Some(b)) = (r.start_percent, r.end_percent) {
                    if a >= b {
                        s.push_str(&format!(" · used {}%", a - b));
                    }
                }
                if r.slept {
                    s.push_str(" · then slept");
                }
                s
            })
            .collect();
        UiState {
            keeps,
            holding: e.holding,
            headline,
            detail: detail.trim_end_matches([' ', '·']).to_string(),
            mode_line: e.mode_line(),
            battery: e.battery_summary(),
            warning: [&e.hold_warning, &e.watchdog_warning, &e.lid_warning].into_iter().flatten().next().cloned(),
            tray,
            agents,
            holds: e.holds.iter().map(|h| (h.id.clone(), h.reason.clone(), h.until)).collect(),
            mode: e.cfg.mode,
            on_until: e.on_until(),
            preset: e.cfg.preset,
            low_power: e.cfg.low_power_while_closed,
            floor: e.cfg.battery_floor,
            can_override_floor: e.blocked_by_floor(),
            sleep_when_done: e.cfg.sleep_when_done,
            quiet: e.cfg.quiet_minutes,
            notify_done: e.cfg.notify_done,
            only_on_power: e.cfg.only_on_power,
            heat_guard: e.cfg.heat_guard,
            heat_available: e.platform.name() != "windows",
            claude_app: e.cfg.count_claude_app,
            open_at_login: e.cfg.open_at_login,
            ntfy_topic: e.cfg.ntfy_topic.clone(),
            recent,
            watch: e.watch_candidates(),
            unrestored: e.unrestored(),
            phone_on: false,
            phone_status: e.remote_status.clone(),
            snoozed: e.snoozed,
        }
    }

    pub fn tooltip(&self) -> String {
        format!("Ajar · {} · {}", self.headline, self.detail)
    }
}

/// Wraps a long note into menu-width lines.
fn wrap(s: &str, width: usize) -> Vec<String> {
    let mut lines = vec![];
    let mut cur = String::new();
    for w in s.split_whitespace() {
        if !cur.is_empty() && cur.chars().count() + 1 + w.chars().count() > width {
            lines.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(w);
    }
    if !cur.is_empty() {
        lines.push(cur);
    }
    lines
}

/// One plain screen, the same as the Mac's: what closing the lid does and why, the three modes with a sentence
/// saying what the chosen one means, one battery line, then everything else tucked into two submenus.
pub fn build(s: &UiState) -> Vec<Node> {
    let mut m = vec![info("head", &s.headline), info("detail", &s.detail), Node::Sep];

    m.extend([
        check("mode:auto", Mode::Auto.label(), s.mode == Mode::Auto),
        check("mode:on", Mode::On.label(), s.mode == Mode::On),
        check("mode:off", Mode::Off.label(), s.mode == Mode::Off),
        info("modeline", &s.mode_line),
        sub(
            "always",
            "Always for…",
            vec![
                text("for:60", "For 1 hour"),
                text("for:180", "For 3 hours"),
                Node::Sep,
                text("until:7", "Until 07:00"),
                text("until:8", "Until 08:00"),
                text("until:9", "Until 09:00"),
            ],
        ),
    ]);

    if let Some(b) = &s.battery {
        m.push(info("battery", b.clone()));
    }
    if s.holding {
        m.push(text("sleepnow", "Sleep Now"));
    }
    if s.snoozed {
        m.push(info("snoozed", "Sleeping when the lid closes, until it opens again"));
    }
    if let Some(w) = &s.warning {
        for (i, line) in wrap(w, 58).into_iter().enumerate() {
            m.push(info(&format!("warn:{i}"), line));
        }
    }
    if !s.unrestored.is_empty() {
        m.push(info("unrestored", format!("Couldn't put back: {}", s.unrestored.join(", "))));
        m.push(text("retry", "Try again"));
    }
    m.push(Node::Sep);
    m.push(sub("apps", "Apps and Agents", apps_menu(s)));
    m.push(sub("settings", "Settings", settings_menu(s)));
    m.push(Node::Sep);
    m.push(text("quit", "Quit Ajar"));
    dedupe_ids(&mut m);
    m
}

/// Agents, holds, other apps that keep it awake, what happens to apps with the lid closed, and when to sleep.
fn apps_menu(s: &UiState) -> Vec<Node> {
    let mut m = vec![];
    if s.agents.is_empty() {
        m.push(info("noagents", "No agents running"));
    }
    for a in &s.agents {
        let state = if a.working {
            "working".to_string()
        } else {
            match a.idle_minutes {
                Some(0) => "idle".into(),
                Some(min) => format!("idle {}", crate::format::minutes(min as f64)),
                None => "idle".into(),
            }
        };
        let mut label = format!("{} · {state}", a.name);
        if !a.keeps_awake {
            label.push_str(" · tracked only");
        }
        let mut children = vec![check(&format!("track:{}", a.id), "Keeps the laptop awake", a.keeps_awake)];
        if let Some(p) = &a.project {
            children.push(info(&format!("proj:{}", a.id), format!("In {p}")));
        }
        m.push(sub(&format!("agent:{}", a.id), label, children));
    }
    for (id, reason, until) in &s.holds {
        let t = match until {
            Some(u) => format!("{reason} · until {}", crate::format::clock(*u)),
            None => reason.clone(),
        };
        m.push(info(&format!("hold:{id}"), t));
    }
    if !s.holds.is_empty() {
        m.push(text("release", if s.holds.len() == 1 { "End this hold" } else { "End all holds" }));
    }
    m.push(Node::Sep);

    let mut while_items: Vec<Node> = vec![info("while:help", "Stays awake while any of these is busy")];
    if s.watch.is_empty() {
        while_items.push(info("while:none", "Busy apps show up here to pick from"));
    }
    for (key, name, on) in &s.watch {
        while_items.push(check(&format!("watch:{key}"), name.clone(), *on));
    }
    let n_on = s.watch.iter().filter(|w| w.2).count();
    m.push(sub("while", if n_on == 0 { "Also While These Run".to_string() } else { format!("Also While These Run: {n_on}") }, while_items));

    m.push(sub(
        "closed",
        format!("While Closed: {}", s.preset.label()),
        vec![
            check("preset:longest", "Max Battery: pause chat and music, slow browsers", s.preset == Preset::Longest),
            check("preset:balanced", "Balanced: slow browsers, chat and music", s.preset == Preset::Balanced),
            check("preset:speed", "Full Speed: leave every app alone", s.preset == Preset::Speed),
            Node::Sep,
            check("lowpower", "Switch to power saver while closed", s.low_power),
            text("editconfig", "Per-app rules… (appRules in the settings file)"),
        ],
    ));

    let quiets = [2u32, 5, 10, 30];
    let mut quiet_items: Vec<Node> = quiets
        .iter()
        .map(|q| check(&format!("quiet:{q}"), format!("{q} min after work stops"), s.sleep_when_done && s.quiet == *q))
        .collect();
    if s.sleep_when_done && !quiets.contains(&s.quiet) {
        quiet_items.insert(0, check(&format!("quiet:{}", s.quiet), format!("{} min after work stops", s.quiet), true));
    }
    quiet_items.push(check("quiet:never", "Not while an agent is open", !s.sleep_when_done));
    let quiet_label = if s.sleep_when_done { format!("Sleep: {} min after work stops", s.quiet) } else { "Sleep: when agents close".to_string() };
    m.push(sub("quiet", quiet_label, quiet_items));
    m
}

/// Battery limit, preferences, phone control and alerts, files, and recent sessions.
fn settings_menu(s: &UiState) -> Vec<Node> {
    let floors = [0u32, 10, 15, 20, 30, 50];
    let mut floor_items: Vec<Node> = floors
        .iter()
        .map(|f| check(&format!("floor:{f}"), if *f == 0 { "No limit".to_string() } else { format!("Stop at {f}%") }, s.floor == *f))
        .collect();
    if !floors.contains(&s.floor) {
        floor_items.insert(0, check(&format!("floor:{}", s.floor), format!("Stop at {}%", s.floor), true));
    }
    if s.can_override_floor {
        floor_items.push(Node::Sep);
        floor_items.push(text("override", "Keep going below the limit this time"));
    }
    let floor_label = if s.floor == 0 { "Battery Limit: none".to_string() } else { format!("Battery Limit: {}%", s.floor) };
    let mut settings = vec![sub("floor", floor_label, floor_items), Node::Sep];

    settings.push(check("notify", "Notify when an agent goes idle", s.notify_done));
    settings.push(check("onlyac", "Only stay awake on the charger", s.only_on_power));
    if s.heat_available {
        settings.push(check("heat", "Heat guard: sleep if it gets too hot", s.heat_guard));
    }
    settings.push(check("claudeapp", "Count the Claude app as an agent", s.claude_app));
    settings.push(check("login", "Open at login", s.open_at_login));
    settings.push(Node::Sep);
    if s.ntfy_topic.is_empty() {
        settings.push(text("ntfy:on", "Phone alerts (ntfy)…"));
    } else {
        settings.push(text("ntfy:open", format!("Phone alerts: {}", s.ntfy_topic)));
        settings.push(text("ntfy:off", "Turn off phone alerts"));
    }
    if s.phone_on {
        settings.push(text("phone:show", "Phone control: on (show QR code)"));
        if let Some(st) = &s.phone_status {
            settings.push(info("phone:status", st.clone()));
        }
        settings.push(text("phone:off", "Turn off phone control"));
        settings.push(text("phone:newkey", "Unpair all phones (new QR code)"));
    } else {
        settings.push(text("phone:on", "Phone control…"));
    }
    settings.push(Node::Sep);
    settings.push(text("editconfig", "Edit settings file…"));
    settings.push(text("openfolder", "Open Ajar folder"));
    if !s.recent.is_empty() {
        settings.push(sub("recent", "Recent", s.recent.iter().enumerate().map(|(i, r)| info(&format!("recent:{i}"), r)).collect()));
    }
    settings
}

/// Two items may legitimately trigger the same action (the settings file link appears twice); give later
/// copies a unique id with a `#n` suffix the app strips.
fn dedupe_ids(nodes: &mut [Node]) {
    fn walk(nodes: &mut [Node], seen: &mut std::collections::HashMap<String, usize>) {
        for n in nodes {
            let id = match n {
                Node::Text { id, .. } | Node::Check { id, .. } | Node::Sub { id, .. } => id,
                Node::Sep => continue,
            };
            let count = seen.entry(id.clone()).or_insert(0);
            *count += 1;
            if *count > 1 {
                *id = format!("{id}#{count}");
            }
            if let Node::Sub { children, .. } = n {
                walk(children, seen);
            }
        }
    }
    walk(nodes, &mut std::collections::HashMap::new());
}

/// The menu's shape (ids and kinds, not labels or ticks). Same shape = update in place.
pub fn shape(nodes: &[Node]) -> String {
    let mut s = String::new();
    for n in nodes {
        match n {
            Node::Text { id, .. } => s.push_str(&format!("t:{id};")),
            Node::Check { id, .. } => s.push_str(&format!("c:{id};")),
            Node::Sub { id, children, .. } => s.push_str(&format!("s:{id}[{}];", shape(children))),
            Node::Sep => s.push_str("-;"),
        }
    }
    s
}

/// What a click means. `None` for informational items.
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    Mode(Mode),
    StayFor(u64),
    StayUntil(u32),
    Preset(Preset),
    LowPower,
    Floor(u32),
    OverrideFloor,
    Quiet(Option<u32>),
    Notify,
    OnlyOnPower,
    HeatGuard,
    ClaudeApp,
    OpenAtLogin,
    TrackOnly(String),
    ReleaseHolds,
    NtfyOn,
    Watch(String),
    SleepNow,
    Retry,
    PhoneOn,
    PhoneShow,
    PhoneOff,
    PhoneNewKey,
    NtfyOpen,
    NtfyOff,
    EditConfig,
    OpenFolder,
    Quit,
}

pub fn action(id: &str) -> Option<Action> {
    let id = id.split('#').next().unwrap_or(id);
    let (k, v) = id.split_once(':').unwrap_or((id, ""));
    Some(match (k, v) {
        ("mode", m) => Action::Mode(Mode::parse(m)?),
        ("for", m) => Action::StayFor(m.parse().ok()?),
        ("until", h) => Action::StayUntil(h.parse().ok().filter(|h: &u32| *h < 24)?),
        ("preset", p) => Action::Preset(Preset::parse(p)?),
        ("lowpower", _) => Action::LowPower,
        ("floor", f) => Action::Floor(f.parse::<u32>().ok()?.min(80)),
        ("override", _) => Action::OverrideFloor,
        ("quiet", "never") => Action::Quiet(None),
        ("quiet", q) => Action::Quiet(Some(q.parse::<u32>().ok()?.clamp(1, 240))),
        ("notify", _) => Action::Notify,
        ("onlyac", _) => Action::OnlyOnPower,
        ("heat", _) => Action::HeatGuard,
        ("claudeapp", _) => Action::ClaudeApp,
        ("login", _) => Action::OpenAtLogin,
        ("track", a) if !a.is_empty() => Action::TrackOnly(a.to_string()),
        ("release", _) => Action::ReleaseHolds,
        ("ntfy", "on") => Action::NtfyOn,
        ("watch", k) if !k.is_empty() && k.len() <= 64 => Action::Watch(k.to_string()),
        ("sleepnow", _) => Action::SleepNow,
        ("retry", _) => Action::Retry,
        ("phone", "on") => Action::PhoneOn,
        ("phone", "show") => Action::PhoneShow,
        ("phone", "off") => Action::PhoneOff,
        ("phone", "newkey") => Action::PhoneNewKey,
        ("ntfy", "open") => Action::NtfyOpen,
        ("ntfy", "off") => Action::NtfyOff,
        ("editconfig", _) => Action::EditConfig,
        ("openfolder", _) => Action::OpenFolder,
        ("quit", _) => Action::Quit,
        _ => return None,
    })
}

/// A topic nobody can guess (ntfy topics are public by name).
pub fn new_topic() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut out = String::from("ajar-");
    let alphabet = b"abcdefghijkmnpqrstuvwxyz23456789";
    for round in 0..2u64 {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u64(crate::now() ^ round);
        h.write_u32(std::process::id());
        let mut x = h.finish();
        for _ in 0..6 {
            out.push(alphabet[(x % alphabet.len() as u64) as usize] as char);
            x /= alphabet.len() as u64;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> UiState {
        UiState {
            keeps: true,
            holding: true,
            headline: "Close the lid: it keeps working".into(),
            detail: "Claude Code is working".into(),
            mode_line: "Stays awake while your AI agents work, then sleeps.".into(),
            battery: Some("64% · about 6 h 05 min with the lid closed".into()),
            warning: None,
            tray: TrayState::Awake,
            agents: vec![AgentRow { id: "claude-code".into(), name: "Claude Code".into(), working: true, idle_minutes: Some(0), project: Some("ajar".into()), keeps_awake: true }],
            holds: vec![],
            mode: Mode::Auto,
            on_until: None,
            preset: Preset::Balanced,
            low_power: true,
            floor: 15,
            can_override_floor: false,
            sleep_when_done: true,
            quiet: 5,
            notify_done: true,
            only_on_power: false,
            heat_guard: true,
            heat_available: true,
            claude_app: true,
            open_at_login: false,
            ntfy_topic: String::new(),
            recent: vec![],
            watch: vec![("blender".into(), "blender".into(), true), ("ffmpeg".into(), "ffmpeg".into(), false)],
            unrestored: vec![],
            phone_on: true,
            phone_status: Some("Connected".into()),
            snoozed: false,
        }
    }

    fn ids(nodes: &[Node], out: &mut Vec<String>) {
        for n in nodes {
            match n {
                Node::Text { id, .. } | Node::Check { id, .. } => out.push(id.clone()),
                Node::Sub { id, children, .. } => {
                    out.push(id.clone());
                    ids(children, out);
                }
                Node::Sep => {}
            }
        }
    }

    #[test]
    fn every_clickable_item_maps_to_an_action_and_ids_are_unique() {
        let mut s = state();
        s.holds = vec![("ab12".into(), "Tests".into(), None)];
        s.can_override_floor = true;
        s.ntfy_topic = "ajar-x".into();
        s.recent = vec!["Today 10:00 · 20 min closed".into()];
        let m = build(&s);
        let mut all = vec![];
        ids(&m, &mut all);
        let unique: std::collections::HashSet<_> = all.iter().collect();
        assert_eq!(unique.len(), all.len(), "duplicate menu ids: {all:?}");
        fn clickable(nodes: &[Node], out: &mut Vec<String>) {
            for n in nodes {
                match n {
                    Node::Text { id, enabled: true, .. } | Node::Check { id, enabled: true, .. } => out.push(id.clone()),
                    Node::Sub { children, .. } => clickable(children, out),
                    _ => {}
                }
            }
        }
        let mut c = vec![];
        clickable(&m, &mut c);
        for id in c {
            assert!(action(&id).is_some(), "{id} does nothing");
        }
    }

    #[test]
    fn text_and_tick_changes_keep_the_shape() {
        let a = state();
        let mut b = state();
        b.detail = "Nothing is working right now".into();
        b.agents[0].working = false;
        b.agents[0].idle_minutes = Some(3);
        b.preset = Preset::Longest;
        b.floor = 20;
        assert_eq!(shape(&build(&a)), shape(&build(&b)));
        let mut c = state();
        c.agents.clear();
        assert_ne!(shape(&build(&a)), shape(&build(&c)));
    }

    #[test]
    fn odd_floor_from_the_settings_file_is_still_shown_ticked() {
        let mut s = state();
        s.floor = 25;
        fn find(nodes: &[Node], want: &str) -> Option<Vec<Node>> {
            nodes.iter().find_map(|n| match n {
                Node::Sub { id, children, .. } if id == want => Some(children.clone()),
                Node::Sub { children, .. } => find(children, want),
                _ => None,
            })
        }
        let floor = find(&build(&s), "floor");
        assert!(floor.unwrap().iter().any(|n| matches!(n, Node::Check { id, checked: true, .. } if id == "floor:25")));
    }

    #[test]
    fn heat_guard_hidden_where_there_is_no_sensor() {
        let mut s = state();
        s.heat_available = false;
        let mut all = vec![];
        ids(&build(&s), &mut all);
        assert!(!all.contains(&"heat".to_string()));
    }

    #[test]
    fn actions_reject_garbage() {
        assert_eq!(action("until:25"), None);
        assert_eq!(action("floor:x"), None);
        assert_eq!(action("mode:sideways"), None);
        assert_eq!(action("track:"), None);
        assert_eq!(action("editconfig#2"), Some(Action::EditConfig));
        assert_eq!(action("floor:99"), Some(Action::Floor(80)));
    }

    #[test]
    fn long_warnings_wrap() {
        let lines = wrap("KDE may still sleep when the lid closes. In System Settings › Power Management, set it to Do nothing.", 40);
        assert!(lines.len() >= 3 && lines.iter().all(|l| l.chars().count() <= 40), "{lines:?}");
    }

    #[test]
    fn topics_are_long_and_safe() {
        let t = new_topic();
        assert!(t.len() == 17 && crate::config::valid_topic(&t), "{t}");
        assert_ne!(new_topic(), new_topic());
    }
}

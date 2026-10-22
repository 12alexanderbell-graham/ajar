//! Settings, stored as `config.json` in Nocturnal's folder. Same key names as the macOS app, so a person (or their
//! Claude) learns one format. Every key is optional when written by hand; a missing or wrong-typed key keeps its
//! default instead of the whole file being rejected.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Off,
    Auto,
    On,
}

impl Mode {
    pub fn label(self) -> &'static str {
        match self {
            Mode::Off => "Off",
            Mode::Auto => "When Busy",
            Mode::On => "Always",
        }
    }
    pub fn parse(s: &str) -> Option<Mode> {
        match s.trim().to_lowercase().replace([' ', '-'], "_").as_str() {
            "off" => Some(Mode::Off),
            "auto" | "when_busy" | "busy" => Some(Mode::Auto),
            "on" | "always" | "always_on" => Some(Mode::On),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Preset {
    Longest,
    Balanced,
    Speed,
}

impl Preset {
    pub fn label(self) -> &'static str {
        match self {
            Preset::Longest => "Max Battery",
            Preset::Balanced => "Balanced",
            Preset::Speed => "Full Speed",
        }
    }
    pub fn parse(s: &str) -> Option<Preset> {
        match s.trim().to_lowercase().replace([' ', '-'], "_").as_str() {
            "longest" | "max_battery" | "max" | "battery" => Some(Preset::Longest),
            "balanced" => Some(Preset::Balanced),
            "speed" | "full_speed" | "full" => Some(Preset::Speed),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AppRule {
    Leave,
    Slow,
    Pause,
}

impl AppRule {
    pub fn as_str(self) -> &'static str {
        match self {
            AppRule::Leave => "leave",
            AppRule::Slow => "slow",
            AppRule::Pause => "pause",
        }
    }
    pub fn parse(s: &str) -> Option<AppRule> {
        match s.trim().to_lowercase().as_str() {
            "leave" => Some(AppRule::Leave),
            "slow" => Some(AppRule::Slow),
            "pause" => Some(AppRule::Pause),
            _ => None,
        }
    }
}

/// An app or command the person added to "keeps the laptop awake". `id` is the executable name (lowercase,
/// without `.exe`) so it matches on any install path.
#[derive(Clone, PartialEq, Eq, Debug, Serialize)]
pub struct WatchedApp {
    pub id: String,
    pub name: String,
}

#[derive(Clone, PartialEq, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomAgent {
    pub name: String,
    pub executables: Vec<String>,
    /// CPU % of one core for the whole process tree, below which it counts as idle.
    pub idle_cpu: Option<f64>,
}

#[derive(Clone, PartialEq, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub mode: Mode,
    pub preset: Preset,
    pub low_power_while_closed: bool,
    pub sleep_when_done: bool,
    pub quiet_minutes: u32,
    pub battery_floor: u32,
    pub heat_guard: bool,
    pub only_on_power: bool,
    pub count_claude_app: bool,
    pub watched_apps: Vec<WatchedApp>,
    /// Executable name (lowercase, no `.exe`) → what happens to it while the lid is closed.
    pub app_rules: BTreeMap<String, AppRule>,
    pub custom_agents: Vec<CustomAgent>,
    pub notify_done: bool,
    pub ntfy_topic: String,
    pub track_only: Vec<String>,
    pub open_at_login: bool,
    /// End of a timed "Always" (Unix seconds). Kept in the same file as `mode` so the two can never disagree
    /// after a crash: a timed Always can't turn into a forever Always.
    pub always_until: Option<u64>,
    /// The mode to go back to when a timed Always ends.
    pub mode_before_always: Option<Mode>,
    /// While asleep with the lid shut, wake every this many minutes (0, 15, 30, 60) for about 25 seconds to pick
    /// up a wake sent from the phone. 0 = off.
    pub check_in_minutes: u32,
    /// A one-off scheduled wake (Unix seconds); the laptop wakes then and stays awake `wake_for_minutes`.
    pub wake_at: Option<u64>,
    pub wake_for_minutes: u32,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            mode: Mode::Auto,
            preset: Preset::Balanced,
            low_power_while_closed: true,
            sleep_when_done: true,
            quiet_minutes: 5,
            battery_floor: 15,
            heat_guard: true,
            only_on_power: false,
            count_claude_app: true,
            watched_apps: vec![],
            app_rules: BTreeMap::new(),
            custom_agents: vec![],
            notify_done: true,
            ntfy_topic: String::new(),
            track_only: vec![],
            open_at_login: false,
            always_until: None,
            mode_before_always: None,
            check_in_minutes: 0,
            wake_at: None,
            wake_for_minutes: 30,
        }
    }
}

/// Executable name as Nocturnal compares it: file name only, lowercase, `.exe` removed.
pub fn exe_key(name: &str) -> String {
    let base = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(name)
        .to_lowercase();
    base.strip_suffix(".exe")
        .map(str::to_string)
        .unwrap_or(base)
}

/// Topic names are public on ntfy.sh; only letters, digits, - and _ are allowed.
pub fn valid_topic(t: &str) -> bool {
    !t.is_empty()
        && t.len() <= 64
        && t.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

impl Config {
    /// Lenient decode: each key on its own, falling back to the default for anything missing or malformed.
    pub fn from_value(v: &Value) -> Config {
        let d = Config::default();
        let b = |k: &str, def: bool| v.get(k).and_then(Value::as_bool).unwrap_or(def);
        let u = |k: &str, def: u32, lo: u32, hi: u32| {
            v.get(k)
                .and_then(Value::as_f64)
                .filter(|x| x.is_finite())
                .map(|x| (x.max(0.0) as u32).clamp(lo, hi))
                .unwrap_or(def)
        };
        let s = |k: &str| v.get(k).and_then(Value::as_str);
        let strings = |k: &str| -> Option<Vec<String>> {
            v.get(k)?.as_array().map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(str::to_string))
                    .collect()
            })
        };
        Config {
            mode: s("mode").and_then(Mode::parse).unwrap_or(d.mode),
            preset: s("preset").and_then(Preset::parse).unwrap_or(d.preset),
            low_power_while_closed: b("lowPowerWhileClosed", d.low_power_while_closed),
            sleep_when_done: b("sleepWhenDone", d.sleep_when_done),
            quiet_minutes: u("quietMinutes", d.quiet_minutes, 1, 240),
            battery_floor: u("batteryFloor", d.battery_floor, 0, 80),
            heat_guard: b("heatGuard", d.heat_guard),
            only_on_power: b("onlyOnPower", d.only_on_power),
            count_claude_app: b("countClaudeApp", d.count_claude_app),
            watched_apps: v
                .get("watchedApps")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|w| {
                            let id = exe_key(w.get("id")?.as_str()?);
                            if id.is_empty() {
                                return None;
                            }
                            let name = w
                                .get("name")
                                .and_then(Value::as_str)
                                .unwrap_or(&id)
                                .to_string();
                            Some(WatchedApp { id, name })
                        })
                        .collect()
                })
                .unwrap_or_default(),
            app_rules: v
                .get("appRules")
                .and_then(Value::as_object)
                .map(|o| {
                    o.iter()
                        .filter_map(|(k, r)| Some((exe_key(k), AppRule::parse(r.as_str()?)?)))
                        .collect()
                })
                .unwrap_or_default(),
            custom_agents: v
                .get("customAgents")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|c| {
                            let name = c
                                .get("name")?
                                .as_str()?
                                .chars()
                                .take(64)
                                .collect::<String>();
                            let executables: Vec<String> = c
                                .get("executables")?
                                .as_array()?
                                .iter()
                                .filter_map(|e| e.as_str().map(exe_key))
                                .filter(|e| !e.is_empty())
                                .collect();
                            if name.is_empty() || executables.is_empty() {
                                return None;
                            }
                            let idle_cpu = c
                                .get("idleCpu")
                                .and_then(Value::as_f64)
                                .filter(|x| x.is_finite() && *x >= 0.0);
                            Some(CustomAgent {
                                name,
                                executables,
                                idle_cpu,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default(),
            notify_done: b("notifyDone", d.notify_done),
            ntfy_topic: s("ntfyTopic")
                .filter(|t| t.is_empty() || valid_topic(t))
                .unwrap_or("")
                .to_string(),
            track_only: strings("trackOnly").unwrap_or_default(),
            open_at_login: b("openAtLogin", d.open_at_login),
            always_until: v
                .get("alwaysUntil")
                .and_then(Value::as_f64)
                .filter(|x| x.is_finite() && *x > 0.0)
                .map(|x| x as u64),
            mode_before_always: s("modeBeforeAlways")
                .and_then(Mode::parse)
                .filter(|m| *m != Mode::On),
            check_in_minutes: Some(u("checkInMinutes", d.check_in_minutes, 0, 60))
                .filter(|m| crate::wake::CHECK_IN_CHOICES.contains(m))
                .unwrap_or(0),
            wake_at: v
                .get("wakeAt")
                .and_then(Value::as_f64)
                .filter(|x| x.is_finite() && *x > 0.0)
                .map(|x| x as u64),
            wake_for_minutes: u("wakeForMinutes", d.wake_for_minutes, 5, 24 * 60),
        }
    }

    pub fn parse(text: &str) -> Option<Config> {
        serde_json::from_str::<Value>(text)
            .ok()
            .filter(Value::is_object)
            .map(|v| Config::from_value(&v))
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".into())
    }

    /// What closing the lid does to an app under the current preset and rules.
    pub fn rule_for(&self, exe: &str, preset: Preset) -> AppRule {
        let key = exe_key(exe);
        let listed = |list: &[&str]| list.contains(&key.as_str());
        let rule = self.app_rules.get(&key).copied().unwrap_or(match preset {
            Preset::Speed => AppRule::Leave,
            Preset::Balanced => {
                if listed(SLOW_BY_DEFAULT) || listed(PAUSE_SUGGESTIONS) || listed(NEVER_PAUSE) {
                    AppRule::Slow
                } else {
                    AppRule::Leave
                }
            }
            // Music or a call in headphones may be going on with the lid shut.
            Preset::Longest if listed(MEDIA_AND_CALLS) => AppRule::Leave,
            Preset::Longest if listed(PAUSE_SUGGESTIONS) || listed(PAUSE_ON_MAX) => AppRule::Pause,
            Preset::Longest if listed(SLOW_BY_DEFAULT) || listed(NEVER_PAUSE) => AppRule::Slow,
            Preset::Longest => AppRule::Leave,
        });
        if rule == AppRule::Pause && listed(NEVER_PAUSE) {
            AppRule::Slow
        } else {
            rule
        }
    }
}

/// Apps the presets slow down. Unlike macOS (which can tell a user app from a system service by its bundle),
/// Windows and Linux presets only touch apps on these lists, so nothing in the desktop shell is ever slowed
/// or frozen by accident. Anything else can still be given a rule by name.
pub const SLOW_BY_DEFAULT: &[&str] = &[
    "chrome",
    "msedge",
    "firefox",
    "brave",
    "opera",
    "vivaldi",
    "chromium",
    "chromium-browser",
    "google-chrome",
    "thunderbird",
    "outlook",
    "olk",
    "winword",
    "excel",
    "powerpnt",
    "onenote",
    "obsidian",
    "notion",
    "figma",
    "figma-linux",
    "steam",
    "steamwebhelper",
    "epicgameslauncher",
    "dropbox",
    "onedrive",
    "googledrivefs",
    "spotify",
    "vlc",
    "music.ui",
    "teams",
    "ms-teams",
    "zoom",
    "skype",
];

/// Mail, documents, launchers and sync clients: paused (frozen until the lid opens) under Max Battery; they catch
/// up when it opens. Browsers stay slowed rather than paused because an agent may be driving one.
pub const PAUSE_ON_MAX: &[&str] = &[
    "thunderbird",
    "outlook",
    "olk",
    "winword",
    "excel",
    "powerpnt",
    "onenote",
    "obsidian",
    "notion",
    "figma",
    "figma-linux",
    "steam",
    "steamwebhelper",
    "epicgameslauncher",
    "dropbox",
    "onedrive",
    "googledrivefs",
];

/// Left running even on Max Battery.
pub const MEDIA_AND_CALLS: &[&str] = &[
    "spotify", "vlc", "music.ui", "teams", "ms-teams", "zoom", "skype",
];

/// Terminals and code editors: slowed with the lid shut, never paused, whatever the preset or a per-app rule says.
/// A frozen terminal stops reading its output, so a command running in it (an agent's or not) stalls as soon as
/// the output buffer fills; editors run terminals, language servers and agents of their own.
pub const NEVER_PAUSE: &[&str] = &[
    // Windows
    "windowsterminal",
    "wt",
    "openconsole",
    "conhost",
    "mintty",
    "tabby",
    "hyper",
    "warp",
    // Linux
    "gnome-terminal",
    "gnome-terminal-server",
    "kgx",
    "ptyxis",
    "ptyxis-agent",
    "konsole",
    "yakuake",
    "xfce4-terminal",
    "mate-terminal",
    "lxterminal",
    "qterminal",
    "tilix",
    "terminator",
    "terminology",
    "guake",
    "foot",
    "footclient",
    "xterm",
    "urxvt",
    "rxvt",
    "st",
    "sakura",
    "blackbox",
    "warp-terminal",
    // Both
    "alacritty",
    "kitty",
    "wezterm",
    "wezterm-gui",
    "ghostty",
    "rio",
    // Code editors
    "code",
    "code-insiders",
    "codium",
    "cursor",
    "windsurf",
    "zed",
    "zed-editor",
    "zeditor",
    "sublime_text",
    "devenv",
    "emacs",
    "gvim",
    "neovide",
    "kate",
    // JetBrains IDEs (Windows launchers end in 64; Linux launchers have the plain name)
    "idea",
    "idea64",
    "pycharm",
    "pycharm64",
    "webstorm",
    "webstorm64",
    "clion",
    "clion64",
    "goland",
    "goland64",
    "rider",
    "rider64",
    "rustrover",
    "rustrover64",
    "phpstorm",
    "phpstorm64",
    "rubymine",
    "rubymine64",
    "datagrip",
    "datagrip64",
    "studio",
    "studio64",
    "fleet",
];

/// Messaging apps: slowed by Balanced, paused by Max Battery. They reconnect and catch up when resumed.
pub const PAUSE_SUGGESTIONS: &[&str] = &[
    "slack",
    "discord",
    "whatsapp",
    "telegram",
    "telegram-desktop",
    "signal",
    "signal-desktop",
    "element",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_and_wrong_keys_keep_defaults() {
        let c = Config::parse(
            r#"{"mode":"always","quietMinutes":"ten","batteryFloor":-5,"heatGuard":3}"#,
        )
        .unwrap();
        assert_eq!(c.mode, Mode::On);
        assert_eq!(c.quiet_minutes, 5);
        assert_eq!(c.battery_floor, 0);
        assert!(c.heat_guard);
    }

    #[test]
    fn clamps_and_rejects_bad_values() {
        let c = Config::parse(r#"{"quietMinutes":1e9,"batteryFloor":999,"ntfyTopic":"../etc"}"#)
            .unwrap();
        assert_eq!(c.quiet_minutes, 240);
        assert_eq!(c.battery_floor, 80);
        assert_eq!(c.ntfy_topic, "");
    }

    #[test]
    fn non_object_is_rejected_not_defaulted() {
        assert!(Config::parse("[1,2]").is_none());
        assert!(Config::parse("not json").is_none());
    }

    #[test]
    fn round_trips_through_json() {
        let mut c = Config::default();
        c.app_rules.insert("chrome".into(), AppRule::Pause);
        c.watched_apps.push(WatchedApp {
            id: "blender".into(),
            name: "Blender".into(),
        });
        let back = Config::parse(&c.to_json()).unwrap();
        assert_eq!(back, c);
    }

    #[test]
    fn exe_keys_ignore_path_case_and_extension() {
        assert_eq!(
            exe_key(r"C:\Program Files\Google\Chrome\Application\Chrome.EXE"),
            "chrome"
        );
        assert_eq!(exe_key("/usr/bin/firefox"), "firefox");
    }

    #[test]
    fn presets_only_touch_listed_apps() {
        let c = Config::default();
        assert_eq!(c.rule_for("gnome-shell", Preset::Longest), AppRule::Leave);
        assert_eq!(c.rule_for("explorer.exe", Preset::Longest), AppRule::Leave);
        assert_eq!(c.rule_for("Slack.exe", Preset::Longest), AppRule::Pause);
        assert_eq!(c.rule_for("slack", Preset::Balanced), AppRule::Slow);
        assert_eq!(
            c.rule_for("Spotify.exe", Preset::Longest),
            AppRule::Leave,
            "music may be playing"
        );
        assert_eq!(
            c.rule_for("zoom", Preset::Longest),
            AppRule::Leave,
            "a call may be going on"
        );
        assert_eq!(c.rule_for("WINWORD.EXE", Preset::Longest), AppRule::Pause);
        assert_eq!(
            c.rule_for("chrome", Preset::Longest),
            AppRule::Slow,
            "an agent may be driving the browser"
        );
        assert_eq!(c.rule_for("chrome", Preset::Speed), AppRule::Leave);
    }

    #[test]
    fn terminals_and_editors_are_slowed_but_never_paused() {
        let mut c = Config::default();
        for exe in [
            r"C:\Program Files\WindowsApps\Microsoft.WindowsTerminal\WindowsTerminal.exe",
            "/usr/libexec/gnome-terminal-server",
            "konsole",
            "wezterm-gui",
            "Code.exe",
            "cursor",
            "zed-editor",
            "idea64.exe",
        ] {
            for preset in [Preset::Balanced, Preset::Longest] {
                assert_eq!(
                    c.rule_for(exe, preset),
                    AppRule::Slow,
                    "{exe} on {preset:?}"
                );
            }
            assert_eq!(c.rule_for(exe, Preset::Speed), AppRule::Leave, "{exe}");
        }
        c.app_rules.insert("alacritty".into(), AppRule::Pause);
        c.app_rules.insert("code".into(), AppRule::Leave);
        assert_eq!(
            c.rule_for("alacritty", Preset::Longest),
            AppRule::Slow,
            "a pause rule is applied as a slow-down"
        );
        assert_eq!(c.rule_for("code", Preset::Longest), AppRule::Leave);
    }

    #[test]
    fn explicit_rule_wins_over_preset() {
        let mut c = Config::default();
        c.app_rules.insert("chrome".into(), AppRule::Pause);
        assert_eq!(c.rule_for("Chrome.exe", Preset::Speed), AppRule::Pause);
    }
}

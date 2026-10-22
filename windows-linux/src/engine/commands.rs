//! The command surface: every request from the CLI, MCP, the phone and the menu, and the JSON replies.

use super::*;

impl<P: Platform> Engine<P> {
    pub fn handle(&mut self, cmd: &str, a: &Value) -> Value {
        let s = |k: &str| a.get(k).and_then(Value::as_str).map(str::to_string);
        let num = |k: &str, cap: f64| -> Option<f64> {
            let v = a.get(k)?;
            let n = v
                .as_f64()
                .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))?;
            (n.is_finite() && n >= 0.0).then(|| n.min(cap))
        };
        let boolean = |k: &str| -> Option<bool> {
            let v = a.get(k)?;
            v.as_bool()
                .or_else(|| match v.as_str()?.to_lowercase().as_str() {
                    "on" | "true" | "yes" | "1" => Some(true),
                    "off" | "false" | "no" | "0" => Some(false),
                    _ => None,
                })
        };
        let fail = |m: String| json!({ "ok": false, "error": m });
        match cmd {
            "status" => self.status_json(),
            "energy" => json!({ "ok": true, "apps": self.energy_json(15) }),
            "mode" => {
                let Some(m) = s("mode").as_deref().and_then(Mode::parse) else {
                    return fail("mode must be off, auto (when busy) or always".into());
                };
                if m == Mode::On {
                    // "until_hour": the next time this laptop's clock reads that hour (the phone may be in
                    // another time zone).
                    let until = num("until_hour", 23.0).map(|h| {
                        let now = crate::now();
                        crate::format::next_local_hour(now, h as u32)
                            .saturating_sub(now)
                            .div_ceil(60)
                    });
                    let minutes = until
                        .or_else(|| num("minutes", 7.0 * 24.0 * 60.0).map(|m| m.max(1.0) as u64));
                    self.stay_awake(minutes);
                } else {
                    self.set_mode(m);
                }
                self.ok()
            }
            "hold" => {
                let pid = match a.get("pid") {
                    None | Some(Value::Null) => None,
                    Some(_) => match num("pid", u32::MAX as f64)
                        .map(|p| p as u32)
                        .filter(|p| *p > 1)
                    {
                        Some(p) => Some(p),
                        None => return fail("pid must be a running process id".into()),
                    },
                };
                let reason = s("reason").unwrap_or_else(|| "Asked to stay awake".into());
                let held = self.add_hold(&reason, num("minutes", 7.0 * 24.0 * 60.0), pid);
                self.hold_reply(held)
            }
            "wake" => {
                // From the phone while asleep (picked up at the next check-in), or any time: stay awake a while.
                // One that waited at the relay and arrives with the lid open is stale: someone opened the laptop
                // in the meantime, and a surprise hour awake after they close it again would be wrong.
                if !self.lid_closed && num("_age", f64::MAX).unwrap_or(0.0) > 300.0 {
                    let mut r = self.ok();
                    r["skipped"] = json!("already awake");
                    return r;
                }
                let minutes = num("minutes", 24.0 * 60.0)
                    .map(|m| m.max(5.0))
                    .unwrap_or(60.0);
                let reason = s("reason").unwrap_or_else(|| "Woken from your phone".into());
                let held = self.add_hold(&reason, Some(minutes), None);
                self.hold_reply(held)
            }
            "wake_at" => {
                // "07:00" (the next time the clock shows it), "off", or Unix seconds; optional minutes awake after.
                let t = s("time")
                    .or_else(|| a.get("time").and_then(Value::as_u64).map(|n| n.to_string()))
                    .unwrap_or_default();
                if ["off", "none", "cancel"].contains(&t.to_lowercase().as_str()) {
                    self.set_wake(None, None);
                    let mut r = self.ok();
                    r["wakeAt"] = Value::Null;
                    return r;
                }
                let now = crate::now();
                let Some(at) = crate::format::parse_wake_time(&t, now) else {
                    return fail("time: HH:MM (24-hour), off, or Unix seconds".into());
                };
                self.set_wake(Some(at), num("minutes", 24.0 * 60.0).map(|m| m as u32));
                let mut r = self.ok();
                r["wakeAt"] = json!(crate::format::clock(at));
                r
            }
            "release" => {
                // One hold by id, or all of them only when asked in so many words (`nocturnal release` with no id).
                if s("id").is_none() && boolean("all") != Some(true) {
                    return fail("needs id (see nocturnal status), or all: true".into());
                }
                let n = self.release_hold(s("id").as_deref());
                let mut r = self.ok();
                r["released"] = json!(n);
                r
            }
            "release_own" => {
                // MCP: an agent may only end holds its own session made.
                let (Some(id), Some(pid)) =
                    (s("id"), num("pid", u32::MAX as f64).map(|p| p as u32))
                else {
                    return fail("needs id and pid".into());
                };
                let n = self.end_holds_where(|h| h.id == id && h.pid == Some(pid));
                if n == 0 {
                    return fail(format!("no hold {id} made by this session"));
                }
                let mut r = self.ok();
                r["released"] = json!(n);
                r
            }
            "release_pid" => {
                let Some(pid) = num("pid", u32::MAX as f64).map(|p| p as u32) else {
                    return fail("needs pid".into());
                };
                let n = self.end_holds_where(|h| h.pid == Some(pid));
                let mut r = self.ok();
                r["released"] = json!(n);
                r
            }
            "panel" => self.panel_json(crate::now()),
            "track" => {
                let Some(id) = s("agent") else {
                    return fail("needs agent".into());
                };
                if !self.watcher.sessions.iter().any(|x| x.kind.id == id)
                    && !self.cfg.track_only.contains(&id)
                {
                    return fail(format!("no agent {id:?} is running"));
                }
                match boolean("keeps") {
                    Some(keeps) => self.set_keeps(&id, keeps),
                    None => self.toggle_track_only(&id), // older phone pages only toggle
                }
                self.ok()
            }
            "sleep_now" => {
                self.sleep_now();
                self.ok()
            }
            "preset" => {
                let Some(p) = s("preset").as_deref().and_then(Preset::parse) else {
                    return fail("preset must be max_battery, balanced or full_speed".into());
                };
                self.update(|c| c.preset = p);
                self.ok()
            }
            "rule" => {
                let (Some(app), Some(rule)) = (s("app"), s("rule")) else {
                    return fail("needs app and rule".into());
                };
                let key = exe_key(app.trim());
                if key.is_empty() || key.len() > 64 {
                    return fail("app must be an executable name like chrome or spotify".into());
                }
                let reset = matches!(rule.trim().to_lowercase().as_str(), "default" | "reset");
                if reset {
                    self.update(|c| {
                        c.app_rules.remove(&key);
                    });
                } else {
                    let Some(r) = AppRule::parse(&rule) else {
                        return fail("rule must be leave, slow, pause or default".into());
                    };
                    if SYSTEM_NEVER.contains(&key.as_str()) {
                        return fail(format!(
                            "{key} is part of the system and is never slowed or paused"
                        ));
                    }
                    self.update(|c| {
                        c.app_rules.insert(key.clone(), r);
                    });
                }
                let now_rule = self.cfg.rule_for(&key, self.cfg.preset).as_str();
                let mut out = self.ok();
                out["app"] = json!(key);
                out["rule"] = json!(if reset {
                    format!("{now_rule} (preset default)")
                } else {
                    now_rule.to_string()
                });
                out
            }
            "watch" => {
                let Some(q) = s("app")
                    .map(|x| x.trim().to_string())
                    .filter(|x| !x.is_empty())
                else {
                    return fail("needs app".into());
                };
                let key = exe_key(&q);
                if key.is_empty() || key.len() > 64 {
                    return fail("app must be an executable name".into());
                }
                let remove = boolean("remove") == Some(true);
                // The phone sends the id: keep the display name already known for it.
                let name = self
                    .watch_candidates()
                    .into_iter()
                    .find(|c| c.0 == key)
                    .map_or(q, |c| c.1);
                self.update(|c| {
                    c.watched_apps.retain(|w| w.id != key);
                    if !remove {
                        c.watched_apps.push(crate::config::WatchedApp {
                            id: key.clone(),
                            name: name.clone(),
                        });
                    }
                });
                let mut out = self.ok();
                out["watch_list"] = json!(self
                    .cfg
                    .watched_apps
                    .iter()
                    .map(|w| w.name.clone())
                    .collect::<Vec<_>>());
                out
            }
            "agent" => {
                let (Some(name), Some(exe)) = (s("name"), s("executable")) else {
                    return fail("needs name and executable".into());
                };
                let name: String = name.chars().take(64).collect();
                let remove = boolean("remove") == Some(true);
                let idle = num("idle_cpu", 400.0);
                self.update(|c| {
                    c.custom_agents.retain(|x| x.name != name);
                    if !remove {
                        c.custom_agents.push(crate::config::CustomAgent {
                            name: name.clone(),
                            executables: vec![exe_key(&exe)],
                            idle_cpu: idle,
                        });
                    }
                });
                self.ok()
            }
            "schema" => crate::ai::describe(&self.cfg, &self.path("config.json")),
            "power" => self.power_json(),
            // The phone's Measure button. Its page only shows it when the panel says `canMeasure`, which this
            // edition never sends.
            "power_test" => fail("Measuring savings is Mac-only for now".into()),
            "set" => {
                let Some(key) = s("key") else {
                    return fail("needs key".into());
                };
                let k = key.replace('-', "_");
                // mode and preset have their own commands; accept them here too so one call can change any setting.
                if k == "mode" || k == "preset" {
                    let mut args = json!({});
                    args[&k] = a.get("value").cloned().unwrap_or(Value::Null);
                    return self.handle(&k, &args);
                }
                let mut bad: Option<&str> = None;
                let v_num = num("value", 1e6);
                let v_bool = boolean("value");
                let v_str = s("value");
                self.update(|c| match k.as_str() {
                    // Like the heat guard: commands can raise the battery limit but only the menu can lower it.
                    "battery_floor" => match v_num {
                        Some(n) if (n as u32).min(80) >= c.battery_floor => c.battery_floor = (n as u32).min(80),
                        Some(_) => bad = Some("to be lowered from the Nocturnal menu (it can only be raised from here)"),
                        None => bad = Some("a number (0 = never stop for battery)"),
                    },
                    "quiet_minutes" => match v_num { Some(n) => c.quiet_minutes = (n as u32).clamp(1, 240), None => bad = Some("a number of minutes") },
                    "sleep_when_done" => match v_bool { Some(b) => c.sleep_when_done = b, None => bad = Some("on/off") },
                    "low_power" => match v_bool { Some(b) => c.low_power_while_closed = b, None => bad = Some("on/off") },
                    // The heat guard protects a laptop in a bag; only the person can turn it off (in the tray menu).
                    "heat_guard" => match v_bool { Some(true) => c.heat_guard = true, Some(false) => bad = Some("to be turned off from the Nocturnal menu (it can only be turned on from here)"), None => bad = Some("on/off") },
                    "only_on_power" => match v_bool { Some(b) if b || !c.only_on_power => c.only_on_power = b, Some(_) => bad = Some("to be turned off from the Nocturnal menu (it can only be turned on from here)"), None => bad = Some("on/off") },
                    "claude_app" => match v_bool { Some(b) => c.count_claude_app = b, None => bad = Some("on/off") },
                    "notify_done" => match v_bool { Some(b) => c.notify_done = b, None => bad = Some("on/off") },
                    "check_in_minutes" => match v_num.map(|n| n as u32).filter(|n| crate::wake::CHECK_IN_CHOICES.contains(n)) {
                        Some(n) => c.check_in_minutes = n,
                        None => bad = Some("0, 15, 30 or 60"),
                    },
                    // Alerts go wherever this topic points, so only the menu sets it; commands may turn it off.
                    "ntfy_topic" => match v_str { Some(t) if t.is_empty() => c.ntfy_topic = t, _ => bad = Some("to be set from the Nocturnal menu (commands can only turn it off with an empty value)") },
                    _ => bad = Some("a known key"),
                });
                if let Some(b) = bad {
                    let keys: Vec<&str> = crate::ai::SETTINGS.iter().map(|s| s.key).collect();
                    return fail(format!(
                        "{key} needs {b}. Keys: {} (nocturnal settings explains each)",
                        keys.join(", ")
                    ));
                }
                self.ok()
            }
            "override_floor" => {
                // Running the battery below the person's limit is their call, from the menu; commands can only
                // turn the override back off.
                if boolean("on").unwrap_or(true) {
                    return fail(
                        "Going below the battery limit can only be allowed from the Nocturnal menu"
                            .into(),
                    );
                }
                self.override_floor(false);
                let mut r = self.ok();
                r["below_floor_allowed"] = json!(self.floor_override);
                r
            }
            "config" => {
                json!({ "ok": true, "path": self.path("config.json").to_string_lossy(), "config": serde_json::to_value(&self.cfg).unwrap_or(Value::Null) })
            }
            _ => fail(format!("Unknown command {cmd}")),
        }
    }

    pub(super) fn ok(&self) -> Value {
        let (_, head, detail) = self.outcome();
        json!({ "ok": true, "status": format!("{head} · {detail}") })
    }

    fn hold_reply(&self, held: Result<Hold, String>) -> Value {
        match held {
            Ok(h) => {
                let mut r = self.ok();
                r["hold"] = serde_json::to_value(&h).unwrap_or(Value::Null);
                r
            }
            Err(e) => json!({ "ok": false, "error": e }),
        }
    }

    pub fn status_json(&self) -> Value {
        let now = crate::now();
        let (keeps, head, detail) = self.outcome();
        let mut d = json!({
            "ok": true,
            "status": format!("{head} · {detail}"),
            "keeping_awake": self.holding,
            "will_stay_awake_closed": keeps,
            "mode": self.cfg.mode,
            "preset": self.cfg.preset,
            "lid_closed": self.lid_closed,
            "has_lid": self.has_lid,
            "platform": self.platform.name(),
            "holds": self.holds,
            "watch_list": self.cfg.watched_apps.iter().map(|w| w.name.clone()).collect::<Vec<_>>(),
            "watching": self.watcher.sessions.iter().map(|s| json!({
                "name": s.kind.name,
                "working": s.working(now),
                "cpu_percent": (s.cpu * 10.0).round() / 10.0,
                "idle_minutes": if s.last_active == 0 { -1 } else { (now.saturating_sub(s.last_active) / 60) as i64 },
                "keeps_awake": !self.cfg.track_only.contains(&s.kind.id),
                "project": s.project.clone().unwrap_or_default(),
            })).collect::<Vec<_>>(),
            "apps_using_cpu": self.energy_json(8),
        });
        if let Some(b) = &self.battery {
            d["battery"] = json!({ "percent": b.percent, "watts": (b.watts * 10.0).round() / 10.0, "on_power": b.on_ac, "charging": b.charging });
            if b.on_battery() {
                if let Some(h) = self.hours_left(self.closed_watts()) {
                    d["hours_left_closed"] = json!((h * 10.0).round() / 10.0);
                }
            }
        }
        if let Some(b) = &self.blocked {
            d["blocked_by"] = json!(b);
        }
        if let Some(e) = &self.setup_error {
            d["setup_error"] = json!(e);
        }
        if let Some(w) = &self.lid_warning {
            d["warning"] = json!(w);
        }
        d
    }

    /// What's using power and which setting would cut it, in a shape an AI agent can act on directly.
    pub fn power_json(&self) -> Value {
        let r1 = |x: Option<f64>| x.map(|v| (v * 10.0).round() / 10.0);
        let watts = self
            .battery
            .as_ref()
            .filter(|b| b.discharging())
            .map(|b| b.watts);
        let kept = self.protected_names();
        let busy: Vec<String> = self
            .watcher
            .cpu_by_app
            .iter()
            .filter(|(name, cpu)| *cpu > 10.0 && !kept.contains(name.as_str()))
            .take(6)
            .map(|(name, cpu)| {
                format!(
                    "{name} {cpu:.0}% cpu ({})",
                    self.cfg.rule_for(name, self.cfg.preset).as_str()
                )
            })
            .collect();
        let preset = match self.cfg.preset {
            Preset::Longest => "max_battery",
            Preset::Balanced => "balanced",
            Preset::Speed => "full_speed",
        };
        json!({
            "ok": true,
            "system_watts": r1(watts),
            "measured": watts.is_some(),
            "source": if watts.is_some() { "battery discharge" } else { "unknown on the charger (the battery reports power only while discharging)" },
            "lid_closed": self.lid_closed,
            "keeping_awake": self.holding,
            "learned_open_watts": r1(self.open_draw),
            "learned_closed_watts": r1(self.closed_draw),
            "suspects": [
                { "id": "apps", "active": !busy.is_empty(), "title": if busy.is_empty() { "No other app is busy".to_string() } else { format!("Busy apps: {}", busy.join(", ")) },
                  "setting": "preset", "value": preset, "suggested_value": "max_battery", "per_app": "nocturnal rule <app> pause" },
                { "id": "low_power", "active": !self.cfg.low_power_while_closed, "title": if self.cfg.low_power_while_closed { "Power saver turns on with the lid closed" } else { "Power saver stays off with the lid closed" },
                  "setting": "low_power", "value": self.cfg.low_power_while_closed, "suggested_value": "on" },
            ],
        })
    }

    pub(super) fn energy_json(&self, limit: usize) -> Value {
        let kept = self.protected_names();
        json!(self.watcher.cpu_by_app.iter().take(limit).map(|(name, cpu)| {
            json!({
                "name": name,
                "cpu_percent": (cpu * 10.0).round() / 10.0,
                "while_closed": if kept.contains(name.as_str()) { "kept (Nocturnal is keeping it awake)" } else { self.cfg.rule_for(name, self.cfg.preset).as_str() },
            })
        }).collect::<Vec<_>>())
    }
}

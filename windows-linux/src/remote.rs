//! Phone control from anywhere, with ntfy.sh as a relay that can't read anything.
//!
//! Pairing: Nocturnal makes a random 256-bit key and shows it as a QR code (a link to the phone panel with the key
//! after `#`, which browsers never send to any server). Both sides derive two unguessable topic names from the
//! key, one for commands and one for replies, and encrypt every message with AES-256-GCM (the topic name is
//! bound in as associated data). Each command carries a timestamp and a random id; Nocturnal drops anything older
//! than 5 minutes, from the future, or already seen, so a captured message can't be replayed.
//!
//! The relay sees only random-looking topic names and ciphertext. Nocturnal only publishes when the phone asks,
//! so a day of normal use is a handful of messages (ntfy.sh's free tier allows a few hundred per day).
//!
//! What the phone may do is a fixed list (`ALLOWED`); like agents and the settings file, it can't loosen the
//! battery limit or turn off the heat guard.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const DEFAULT_SERVER: &str = "https://ntfy.sh";
/// Commands the phone panel may send.
/// `power_test` (the phone's Measure button) is accepted only to answer that it's Mac-only.
pub const ALLOWED: &[&str] = &[
    "panel",
    "mode",
    "preset",
    "watch",
    "track",
    "sleep_now",
    "set",
    "schema",
    "power",
    "power_test",
    "wake",
    "wake_at",
];
const MAX_AGE: u64 = 300;

/// A "wake" sent while the laptop slept waits at the relay until its next check-in; everything else is dropped
/// after 5 minutes (the phone stopped waiting).
fn max_age(cmd: &str) -> u64 {
    if cmd == "wake" {
        crate::wake::WAKE_MAX_AGE
    } else {
        MAX_AGE
    }
}
const TOO_OLD: &str = "too old";
const REPLAYED: &str = "already handled";

/// One paired phone, with its own key: revoking it leaves the others working.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Phone {
    pub id: String,
    pub name: String,
    /// Base64url, 32 bytes.
    pub key: String,
    pub added: u64,
    #[serde(default)]
    pub last_seen: Option<u64>,
}

impl Phone {
    pub fn key_bytes(&self) -> Option<[u8; 32]> {
        parse_key(&self.key)
    }
}

/// More than this and the subscription URL gets long; nobody pairs this many phones.
pub const MAX_PHONES: usize = 10;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub enabled: bool,
    pub phones: Vec<Phone>,
    pub server: String,
    /// Where the phone panel page lives; the QR code links here with the key after `#`.
    pub panel_url: String,
    /// The single shared key of older versions; moved into `phones` on load.
    pub key: String,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            enabled: false,
            phones: vec![],
            server: DEFAULT_SERVER.into(),
            panel_url: String::new(),
            key: String::new(),
        }
    }
}

impl Settings {
    pub fn load(root: &Path) -> Settings {
        let mut s: Settings =
            crate::state::load_json(&root.join("remote.json")).unwrap_or_default();
        if s.phones.is_empty() && parse_key(&s.key).is_some() {
            s.phones.push(Phone {
                id: new_id(),
                name: "Phone".into(),
                key: s.key.clone(),
                added: crate::now(),
                last_seen: None,
            });
        }
        s.key.clear();
        s
    }
    /// Saved owner-only: whoever has a key can control the laptop.
    pub fn save(&self, root: &Path) -> bool {
        let p = root.join("remote.json");
        let ok = crate::state::save_json(&p, self);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600));
        }
        ok
    }
    pub fn usable(&self) -> Vec<&Phone> {
        self.phones
            .iter()
            .filter(|p| p.key_bytes().is_some())
            .collect()
    }
    /// A new phone with its own key, or None when `MAX_PHONES` are paired already.
    pub fn add_phone(&mut self, now: u64) -> Option<Phone> {
        if self.phones.len() >= MAX_PHONES {
            return None;
        }
        let p = Phone {
            id: new_id(),
            name: "New phone".into(),
            key: new_key(),
            added: now,
            last_seen: None,
        };
        self.phones.push(p.clone());
        Some(p)
    }
    /// The link inside a phone's QR code.
    pub fn pairing_link(&self, phone: &Phone) -> Option<String> {
        if self.panel_url.is_empty() || phone.key_bytes().is_none() {
            return None;
        }
        let server = if self.server == DEFAULT_SERVER {
            String::new()
        } else {
            format!("&s={}", crate::format::url_encode(&self.server))
        };
        Some(format!("{}#k={}{server}", self.panel_url, phone.key))
    }
}

pub fn new_id() -> String {
    let mut b = [0u8; 4];
    getrandom::fill(&mut b).expect("the operating system's random number generator failed");
    hex(&b)
}

/// The device name a phone sends with its commands, cleaned for display.
pub fn device_name(v: &Value) -> Option<String> {
    let t: String = v
        .as_str()?
        .chars()
        .filter(|c| !c.is_control())
        .take(40)
        .collect();
    let t = t.trim().to_string();
    (!t.is_empty()).then_some(t)
}

pub fn new_key() -> String {
    let mut k = [0u8; 32];
    getrandom::fill(&mut k).expect("the operating system's random number generator failed");
    B64.encode(k)
}

pub fn parse_key(s: &str) -> Option<[u8; 32]> {
    B64.decode(s.trim()).ok()?.try_into().ok()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// (command topic, reply topic).
pub fn topics(key: &[u8; 32]) -> (String, String) {
    let t = |label: &[u8]| {
        let mut h = Sha256::new();
        h.update(label);
        h.update(key);
        format!("nocturnal-{}", &hex(&h.finalize())[..24])
    };
    (t(b"nocturnal/cmd/v1"), t(b"nocturnal/reply/v1"))
}

pub fn seal(key: &[u8; 32], topic: &str, plaintext: &str) -> String {
    let cipher = Aes256Gcm::new_from_slice(key).expect("32-byte key");
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).expect("random nonce");
    let ct = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext.as_bytes(),
                aad: topic.as_bytes(),
            },
        )
        .expect("encrypt");
    let mut out = nonce.to_vec();
    out.extend(ct);
    B64.encode(out)
}

pub fn open(key: &[u8; 32], topic: &str, message: &str) -> Option<String> {
    let raw = B64.decode(message.trim()).ok()?;
    if raw.len() < 12 + 16 || raw.len() > 64 * 1024 {
        return None;
    }
    let cipher = Aes256Gcm::new_from_slice(key).ok()?;
    let pt = cipher
        .decrypt(
            Nonce::from_slice(&raw[..12]),
            Payload {
                msg: &raw[12..],
                aad: topic.as_bytes(),
            },
        )
        .ok()?;
    String::from_utf8(pt).ok()
}

/// Rejects stale, future-dated, replayed and too-frequent commands.
#[derive(Default)]
pub struct Guard {
    seen: VecDeque<(String, u64)>,
    recent: VecDeque<u64>,
}

impl Guard {
    /// The ids seen, one "id<TAB>time" per line, so a restart still refuses a replay.
    pub fn seen_text(&self) -> String {
        self.seen
            .iter()
            .map(|(id, at)| format!("{id}\t{at}\n"))
            .collect()
    }

    /// Adds ids saved by `seen_text` (from an earlier run) that aren't known yet.
    pub fn load_seen(&mut self, text: &str) {
        for line in text.lines() {
            let mut parts = line.split('\t');
            if let (Some(id), Some(at)) = (
                parts.next(),
                parts.next().and_then(|a| a.parse::<u64>().ok()),
            ) {
                if !id.is_empty() && id.len() <= 64 && !self.seen.iter().any(|(s, _)| s == id) {
                    self.seen.push_back((id.to_string(), at));
                }
            }
        }
    }

    pub fn check(&mut self, t: u64, id: &str, now: u64) -> Result<(), &'static str> {
        self.check_aged(t, id, now, MAX_AGE)
    }

    pub fn check_aged(
        &mut self,
        t: u64,
        id: &str,
        now: u64,
        max_age: u64,
    ) -> Result<(), &'static str> {
        if t + max_age < now {
            return Err(TOO_OLD);
        }
        if id.is_empty() || id.len() > 64 {
            return Err("bad id");
        }
        if t > now + 60 {
            return Err("from the future (check the phone's clock)");
        }
        // Ids are remembered as long as any command can still be accepted, so none runs twice.
        while self
            .seen
            .front()
            .is_some_and(|(_, at)| at + crate::wake::WAKE_MAX_AGE + 60 < now)
        {
            self.seen.pop_front();
        }
        if self.seen.iter().any(|(s, _)| s == id) {
            return Err(REPLAYED);
        }
        while self.recent.front().is_some_and(|at| at + 60 < now) {
            self.recent.pop_front();
        }
        if self.recent.len() >= 30 {
            return Err("too many commands, wait a minute");
        }
        self.seen.push_back((id.to_string(), now));
        self.recent.push_back(now);
        Ok(())
    }
}

/// Why a relayed message wasn't run.
#[derive(Debug, PartialEq)]
pub enum Rejected {
    /// Gets no reply: garbage on the topic (nothing to tell a stranger), a command too old for the phone to
    /// still be waiting (a burst of them after a restart would only burn the relay's quota), or a replay (the
    /// phone already has, or is getting, the real reply under that id).
    Silent(String),
    /// From the phone but refused (clock, rate limit, not allowed): the reply carries the command's id so the
    /// phone can match it.
    Refused { re: String, error: String },
}

impl Rejected {
    pub fn error(&self) -> &str {
        match self {
            Rejected::Silent(e) | Rejected::Refused { error: e, .. } => e,
        }
    }
}

/// Decrypts and validates one relayed command. Returns (id, command, args).
pub fn decode_command(
    key: &[u8; 32],
    topic: &str,
    message: &str,
    guard: &mut Guard,
    now: u64,
) -> Result<(String, String, Value), Rejected> {
    let text = open(key, topic, message).ok_or_else(|| {
        Rejected::Silent("couldn't decrypt (wrong key, or not from your phone)".into())
    })?;
    let v: Value = serde_json::from_str(&text).map_err(|_| Rejected::Silent("not JSON".into()))?;
    // Read before any check, so even a refusal can name the command it answers.
    let id = v["n"].as_str().unwrap_or("").to_string();
    let refuse = |error: &str| Rejected::Refused {
        re: id.clone(),
        error: error.to_string(),
    };
    let t = v["t"].as_u64().ok_or_else(|| refuse("no timestamp"))?;
    match guard.check_aged(t, &id, now, max_age(v["cmd"].as_str().unwrap_or(""))) {
        Err(e @ (TOO_OLD | REPLAYED)) => return Err(Rejected::Silent(e.into())),
        Err(e) => return Err(refuse(e)),
        Ok(()) => {}
    }
    let cmd = v["cmd"].as_str().unwrap_or("").to_string();
    if !ALLOWED.contains(&cmd.as_str()) {
        return Err(refuse(&format!("{cmd:?} isn't allowed from the phone")));
    }
    let mut args = v
        .get("args")
        .cloned()
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));
    if cmd == "wake" {
        // How long it waited at the relay: an old wake is only for a laptop that's still shut and asleep.
        args["_age"] = json!(now.saturating_sub(t));
    }
    Ok((id, cmd, args))
}

/// What to publish for one relayed message (before its timestamp is added), or None for no reply at all.
pub fn reply_to(
    key: &[u8; 32],
    topic: &str,
    message: &str,
    guard: &mut Guard,
    now: u64,
    run: impl FnOnce(&str, Value) -> Value,
) -> Option<Value> {
    match decode_command(key, topic, message, guard, now) {
        Ok((n, cmd, args)) => {
            let mut r = run(&cmd, args);
            r["re"] = json!(n);
            Some(r)
        }
        Err(Rejected::Silent(_)) => None,
        Err(Rejected::Refused { re, error }) => {
            let mut r = json!({ "ok": false, "error": error });
            if !re.is_empty() && re.len() <= 64 {
                r["re"] = json!(re);
            }
            Some(r)
        }
    }
}

/// Shared by every listener this process starts, so one restarted after a wake (while the old one is still
/// winding down) can't run a command the old one already ran.
static GUARD: Mutex<Guard> = Mutex::new(Guard {
    seen: VecDeque::new(),
    recent: VecDeque::new(),
});

/// Whether a subscription answered with ntfy's JSON stream (and not, say, a Wi-Fi sign-in page).
fn is_json_stream(content_type: &str) -> bool {
    let ct = content_type.to_ascii_lowercase();
    ct.starts_with("application/")
        && ct
            .split(';')
            .next()
            .is_some_and(|m| m.trim().ends_with("json"))
}

/// Waits `secs` seconds, checking `stop` every second. False if stopped.
fn pause(secs: u64, stop: &AtomicBool) -> bool {
    for _ in 0..secs {
        if stop.load(Ordering::SeqCst) {
            return false;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    !stop.load(Ordering::SeqCst)
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_connect(Some(Duration::from_secs(15)))
        // The stream is reopened every 90 seconds (from the last message id, so nothing is missed); this also
        // notices a connection that died silently (after a sleep or a network change) within that time. ntfy
        // sends a keepalive every 45 seconds.
        .timeout_recv_body(Some(Duration::from_secs(90)))
        .tls_config(
            ureq::tls::TlsConfig::builder()
                .root_certs(ureq::tls::RootCerts::PlatformVerifier)
                .build(),
        )
        .build()
        .new_agent()
}

/// Publishes one encrypted message.
/// ntfy.sh turns messages over 4096 bytes into file attachments, which the phone page can't read as a reply.
/// A sealed message is about 4/3 of the plaintext plus 38 bytes, so replies are kept under this many bytes.
pub const MAX_REPLY: usize = 2800;

/// The reply the phone gets: the command's outcome (not its full result, which for `panel` is the panel
/// itself) plus the panel, trimmed to fit in one ntfy message.
pub fn phone_reply(cmd: &str, result: &Value, panel: Value) -> Value {
    let mut r = json!({});
    for k in ["ok", "error", "next"] {
        if let Some(v) = result.get(k) {
            r[k] = v.clone();
        }
    }
    if cmd == "schema" {
        // The phone's Settings page: values and choices only (its labels live in the page), no panel.
        let keep = ["key", "type", "allowed", "category", "value"];
        let list: Vec<Value> = result["settings"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|s| {
                        Value::Object(
                            s.as_object()
                                .map(|o| {
                                    o.iter()
                                        .filter(|(k, _)| keep.contains(&k.as_str()))
                                        .map(|(k, v)| (k.clone(), v.clone()))
                                        .collect()
                                })
                                .unwrap_or_default(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        r["settings"] = Value::Array(list);
        return r;
    }
    r["panel"] = panel;
    let size = |r: &Value| r.to_string().len();
    if size(&r) > MAX_REPLY {
        // Offered apps first (the ones already kept awake stay), then the agent list, then the holds.
        if let Some(w) = r["panel"]["watch"].as_array_mut() {
            w.retain(|a| a["on"].as_bool() == Some(true));
        }
    }
    if size(&r) > MAX_REPLY {
        if let Some(a) = r["panel"]["agents"].as_array_mut() {
            a.truncate(4);
        }
        if let Some(o) = r["panel"].as_object_mut() {
            o.remove("holds");
        }
    }
    r
}

pub fn publish(server: &str, key: &[u8; 32], topic: &str, body: &Value) -> Result<(), String> {
    let sealed = seal(key, topic, &body.to_string());
    agent()
        .post(&format!("{}/{topic}", server.trim_end_matches('/')))
        .header("Cache", "yes")
        .send(sealed)
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Listens for every paired phone's commands until `stop` is set: one subscription for all their command topics;
/// each message is opened with the key of the phone whose topic it came on and answered on that phone's reply
/// topic. `run` executes one allowed command and returns the reply; `on_seen` gets (phone id, device name) for
/// each valid command. `cursor` stores the relay's time of the last message handled, so a restart picks up where
/// it left off (the replay guard drops anything from that same second already run). With no cursor, only new
/// messages are read.
pub fn listen(
    settings: Settings,
    cursor: std::path::PathBuf,
    stop: Arc<AtomicBool>,
    mut run: impl FnMut(&str, Value) -> Value,
    mut on_error: impl FnMut(Option<String>),
    mut on_seen: impl FnMut(&str, Option<String>),
) {
    let phones: Vec<(String, [u8; 32], String, String)> = settings
        .usable()
        .into_iter()
        .map(|p| {
            let k = p.key_bytes().unwrap_or([0; 32]);
            let (c, r) = topics(&k);
            (p.id.clone(), k, c, r)
        })
        .collect();
    if phones.is_empty() {
        return;
    }
    let topic_list = phones
        .iter()
        .map(|p| p.2.as_str())
        .collect::<Vec<_>>()
        .join(",");
    let server = settings.server.trim_end_matches('/').to_string();
    let mut since: Option<String> = crate::state::read(&cursor)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s.len() <= 12 && s.chars().all(|c| c.is_ascii_digit()));
    let seen_file = cursor.with_file_name("remote-seen");
    if let Some(text) = crate::state::read(&seen_file) {
        GUARD
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .load_seen(&text);
    }
    let mut backoff = 5u64;
    while !stop.load(Ordering::SeqCst) {
        let url = match &since {
            Some(t) => format!("{server}/{topic_list}/json?since={t}"),
            None => format!("{server}/{topic_list}/json"),
        };
        // A stream that ends without one real event (a sign-in page or proxy answering for the relay) is
        // retried with the same backoff as a failed connection, not in a tight loop.
        let mut delivered = false;
        match agent().get(&url).call() {
            Ok(resp)
                if !is_json_stream(
                    resp.headers()
                        .get("content-type")
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or(""),
                ) =>
            {
                on_error(Some(format!("{server} didn't answer like a relay (a Wi-Fi sign-in page or proxy in the way?)")));
            }
            Ok(resp) => {
                use std::io::BufRead;
                let reader = std::io::BufReader::new(resp.into_body().into_reader());
                for line in reader.lines() {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    let Ok(line) = line else { break };
                    let Ok(ev) = serde_json::from_str::<Value>(&line) else {
                        continue;
                    };
                    if ev["event"] == "open" || ev["event"] == "message" {
                        if !delivered {
                            on_error(None);
                        }
                        delivered = true;
                        backoff = 5;
                    }
                    if ev["event"] != "message" {
                        continue;
                    }
                    if let Some(t) = ev["time"].as_u64().filter(|t| *t > 0) {
                        since = Some(t.to_string());
                        let _ = std::fs::write(&cursor, t.to_string());
                    }
                    let Some((id, key, cmd_topic, reply_topic)) = phones
                        .iter()
                        .find(|p| ev["topic"].as_str() == Some(p.2.as_str()))
                    else {
                        continue;
                    };
                    let now = crate::now();
                    let message = ev["message"].as_str().unwrap_or("");
                    let mut guard = GUARD.lock().unwrap_or_else(|e| e.into_inner());
                    let mut ran = false;
                    let reply = reply_to(key, cmd_topic, message, &mut guard, now, |cmd, args| {
                        ran = true;
                        run(cmd, args)
                    });
                    let _ = std::fs::write(&seen_file, guard.seen_text());
                    drop(guard);
                    if ran {
                        let dev = open(key, cmd_topic, message)
                            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                            .and_then(|v| device_name(&v["dev"]));
                        on_seen(id, dev);
                    }
                    let Some(mut body) = reply else {
                        continue;
                    };
                    body["t"] = json!(now);
                    if let Err(e) = publish(&server, key, reply_topic, &body) {
                        on_error(Some(format!("Couldn't reach {server}: {e}")));
                    }
                }
            }
            Err(e) => {
                on_error(Some(format!("Couldn't reach {server}: {e}")));
            }
        }
        if !delivered {
            if !pause(backoff, &stop) {
                return;
            }
            backoff = (backoff * 2).min(120);
        }
    }
}

/// An SVG QR code for the pairing link.
pub fn qr_svg(link: &str) -> Option<String> {
    let code =
        qrcode::QrCode::with_error_correction_level(link.as_bytes(), qrcode::EcLevel::M).ok()?;
    Some(
        code.render::<qrcode::render::svg::Color>()
            .min_dimensions(280, 280)
            .quiet_zone(true)
            .build(),
    )
}

/// The local page the tray menu opens: QR code, the link, and what it does.
pub fn pairing_page(link: &str) -> String {
    let qr = qr_svg(link).unwrap_or_default();
    let esc = |s: &str| {
        s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('"', "&quot;")
    };
    format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nocturnal phone control</title>
<style>
:root{{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--sub:#6e6e73}}
@media (prefers-color-scheme:dark){{:root{{--bg:#000;--card:#1c1c1e;--text:#f5f5f7;--sub:#98989d}}}}
body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,"Segoe UI",system-ui,sans-serif;display:flex;justify-content:center}}
main{{max-width:420px;margin:40px 16px;background:var(--card);border-radius:18px;padding:28px;text-align:center}}
h1{{font-size:22px;margin:0 0 6px}} p{{color:var(--sub);margin:6px 0}} svg{{width:260px;height:260px;margin:18px auto;display:block;background:#fff;border-radius:12px}}
code{{display:block;word-break:break-all;font-size:11px;color:var(--sub);margin-top:14px}}
</style></head><body><main>
<h1>Control Nocturnal from your phone</h1>
<p>Scan with the phone's camera, then add the page to your home screen.</p>
{qr}
<p>Works from anywhere with internet. Messages are end-to-end encrypted; the key never leaves the link.</p>
<p>Anyone with this code can control this laptop. Revoke this phone in Nocturnal's menu to cancel it.</p>
<code>{}</code>
</main></body></html>"#,
        esc(link)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open_round_trip_and_topic_binding() {
        let key = parse_key(&new_key()).unwrap();
        let (c, r) = topics(&key);
        assert!(c.starts_with("nocturnal-") && c.len() == "nocturnal-".len() + 24 && c != r);
        let m = seal(&key, &c, "{\"cmd\":\"panel\"}");
        assert_eq!(open(&key, &c, &m).as_deref(), Some("{\"cmd\":\"panel\"}"));
        assert!(
            open(&key, &r, &m).is_none(),
            "a message moved to the other topic doesn't open"
        );
        let other = parse_key(&new_key()).unwrap();
        assert!(open(&other, &c, &m).is_none(), "wrong key doesn't open");
        let mut tampered = B64.decode(&m).unwrap();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert!(
            open(&key, &c, &B64.encode(tampered)).is_none(),
            "tampering is detected"
        );
        assert!(open(&key, &c, "not base64!!").is_none());
    }

    #[test]
    fn replays_stale_and_floods_are_rejected() {
        let key = parse_key(&new_key()).unwrap();
        let (c, _) = topics(&key);
        let now = 1_000_000;
        let mut g = Guard::default();
        let msg = |t: u64, n: &str, cmd: &str| {
            seal(&key, &c, &json!({ "t": t, "n": n, "cmd": cmd }).to_string())
        };
        assert!(decode_command(&key, &c, &msg(now, "a1", "panel"), &mut g, now).is_ok());
        assert!(
            decode_command(&key, &c, &msg(now, "a1", "panel"), &mut g, now)
                .unwrap_err()
                .error()
                .contains("already"),
            "replay"
        );
        assert!(
            decode_command(&key, &c, &msg(now - 600, "a2", "panel"), &mut g, now).is_err(),
            "stale"
        );
        assert!(
            decode_command(&key, &c, &msg(now + 600, "a3", "panel"), &mut g, now).is_err(),
            "future"
        );
        assert!(
            decode_command(&key, &c, &msg(now, "a4", "override_floor"), &mut g, now)
                .unwrap_err()
                .error()
                .contains("allowed")
        );
        for i in 0..40 {
            let r = decode_command(&key, &c, &msg(now, &format!("f{i}"), "panel"), &mut g, now);
            if i >= 28 {
                assert!(r.is_err(), "flood limited by {i}");
            }
        }
    }

    #[test]
    fn refusals_name_the_command_but_stale_and_garbage_get_no_reply() {
        let key = parse_key(&new_key()).unwrap();
        let (c, _) = topics(&key);
        let now = 1_000_000;
        let mut g = Guard::default();
        let msg = |t: u64, n: &str, cmd: &str| {
            seal(&key, &c, &json!({ "t": t, "n": n, "cmd": cmd }).to_string())
        };
        let ran = |cmd: &str, _: Value| json!({ "ok": true, "ran": cmd });
        let r = reply_to(&key, &c, &msg(now, "b1", "panel"), &mut g, now, ran).unwrap();
        assert_eq!(
            (r["re"].as_str(), r["ran"].as_str()),
            (Some("b1"), Some("panel"))
        );
        // Refused by the guard or the allow list: the phone can match the error to what it sent.
        let future = reply_to(&key, &c, &msg(now + 600, "b2", "panel"), &mut g, now, ran).unwrap();
        assert_eq!(
            (future["ok"].as_bool(), future["re"].as_str()),
            (Some(false), Some("b2"))
        );
        assert!(future["error"].as_str().unwrap().contains("clock"));
        let banned = reply_to(
            &key,
            &c,
            &msg(now, "b3", "override_floor"),
            &mut g,
            now,
            ran,
        )
        .unwrap();
        assert_eq!(
            (banned["ok"].as_bool(), banned["re"].as_str()),
            (Some(false), Some("b3"))
        );
        for i in 0..40 {
            if let Some(r) = reply_to(
                &key,
                &c,
                &msg(now, &format!("r{i}"), "panel"),
                &mut g,
                now,
                ran,
            ) {
                if r["ok"] == false {
                    assert_eq!(
                        r["re"].as_str(),
                        Some(format!("r{i}").as_str()),
                        "rate limit names the command"
                    );
                }
            }
        }
        // No reply: too old (the phone stopped waiting), a replay, garbage.
        let mut g = Guard::default();
        assert!(
            reply_to(
                &key,
                &c,
                &msg(now - MAX_AGE - 1, "s1", "panel"),
                &mut g,
                now,
                ran
            )
            .is_none(),
            "stale"
        );
        assert!(
            reply_to(
                &key,
                &c,
                &msg(now - MAX_AGE - 1, "", "panel"),
                &mut g,
                now,
                ran
            )
            .is_none(),
            "stale even with a bad id"
        );
        assert!(reply_to(&key, &c, &msg(now, "s2", "panel"), &mut g, now, ran).is_some());
        assert!(
            reply_to(&key, &c, &msg(now, "s2", "panel"), &mut g, now, ran).is_none(),
            "replay"
        );
        assert!(reply_to(&key, &c, "garbage", &mut g, now, ran).is_none());
        // The Measure button is answered (by the engine), not refused here.
        assert!(decode_command(&key, &c, &msg(now, "p1", "power_test"), &mut g, now).is_ok());
    }

    #[test]
    fn only_a_json_stream_counts_as_the_relay() {
        assert!(is_json_stream("application/x-ndjson; charset=utf-8"));
        assert!(is_json_stream("application/json"));
        assert!(!is_json_stream("text/html; charset=utf-8"));
        assert!(!is_json_stream(""));
    }

    #[test]
    fn pairing_link_and_qr() {
        let mut s = Settings {
            enabled: true,
            panel_url: "https://example.org/panel".into(),
            ..Default::default()
        };
        let phone = s.add_phone(1).unwrap();
        let link = s.pairing_link(&phone).unwrap();
        assert!(link.starts_with("https://example.org/panel#k=") && !link.contains("&s="));
        assert!(link.ends_with(&phone.key));
        assert!(qr_svg(&link).unwrap().contains("<svg"));
        assert!(Settings {
            panel_url: String::new(),
            ..s.clone()
        }
        .pairing_link(&phone)
        .is_none());
    }

    #[test]
    fn each_phone_has_its_own_key_and_old_settings_carry_over() {
        let mut s = Settings::default();
        let a = s.add_phone(1).unwrap();
        let b = s.add_phone(2).unwrap();
        assert_ne!(a.key, b.key);
        assert_ne!(
            topics(&a.key_bytes().unwrap()),
            topics(&b.key_bytes().unwrap())
        );
        for i in 2..MAX_PHONES {
            assert!(s.add_phone(i as u64).is_some());
        }
        assert!(s.add_phone(99).is_none(), "at most MAX_PHONES");
        // A remote.json from before per-phone keys: its key becomes one paired phone.
        let root =
            std::env::temp_dir().join(format!("nocturnal-remote-migrate-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&root);
        let old = new_key();
        std::fs::write(
            root.join("remote.json"),
            format!(r#"{{"enabled":true,"key":"{old}","server":"https://ntfy.sh","panelUrl":""}}"#),
        )
        .unwrap();
        let loaded = Settings::load(&root);
        assert_eq!(loaded.phones.len(), 1);
        assert_eq!(loaded.phones[0].key, old);
        assert!(loaded.key.is_empty());
        assert_eq!(
            device_name(&json!("  Alexander's iPhone\n")),
            Some("Alexander's iPhone".into())
        );
        assert_eq!(device_name(&json!("")), None);
    }

    #[test]
    fn phone_reply_fits_one_ntfy_message() {
        let key = parse_key(&new_key()).unwrap();
        let (_, rep) = topics(&key);
        let watch: Vec<Value> = (0..40).map(|i| json!({ "id": format!("/Applications/Some Long Application Name {i}.app"), "name": format!("Some Long Application Name {i}"), "on": i < 2 })).collect();
        let agents: Vec<Value> = (0..12).map(|i| json!({ "id": format!("agent{i}"), "name": format!("Agent number {i}"), "working": true, "keeps": true, "instances": 1 })).collect();
        let holds = vec!["Asked to stay awake"; 20];
        let panel = json!({ "headline": "Keeps working", "watch": watch, "agents": agents, "holds": holds });
        let result = json!({ "ok": true, "headline": "dup", "watch": panel["watch"].clone() });
        let r = phone_reply("panel", &result, panel);
        assert!(
            r.get("headline").is_none(),
            "the command's full result isn't repeated"
        );
        assert_eq!(
            r["panel"]["watch"].as_array().unwrap().len(),
            2,
            "apps already kept awake stay"
        );
        let mut msg = r.clone();
        msg["re"] = json!("0123456789abcdef");
        msg["t"] = json!(1_800_000_000u64);
        assert!(seal(&key, &rep, &msg.to_string()).len() < 4096);
    }

    #[test]
    fn phone_settings_reply_is_small() {
        let c = crate::config::Config::default();
        let full = crate::ai::describe(&c, std::path::Path::new("/tmp/config.json"));
        let r = phone_reply("schema", &full, json!({}));
        assert!(r.get("panel").is_none());
        let first = &r["settings"][0];
        assert!(
            first.get("key").is_some()
                && first.get("value").is_some()
                && first.get("description").is_none()
        );
        assert!(r.to_string().len() < MAX_REPLY);
    }
}

#[cfg(test)]
mod seen_tests {
    use super::*;

    #[test]
    fn replay_ids_survive_a_restart() {
        let mut g = Guard::default();
        let now = 1_000_000;
        assert!(g.check(now, "abc", now).is_ok());
        let saved = g.seen_text();
        let mut fresh = Guard::default();
        fresh.load_seen(&saved);
        assert_eq!(fresh.check(now, "abc", now + 5), Err(REPLAYED));
        fresh.load_seen("garbage\nno-tab\n\tx\n");
        assert!(fresh.check(now, "new", now + 5).is_ok());
    }
}

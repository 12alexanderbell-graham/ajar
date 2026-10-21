//! Phone control from anywhere, with ntfy.sh as a relay that can't read anything.
//!
//! Pairing: Ajar makes a random 256-bit key and shows it as a QR code (a link to the phone panel with the key
//! after `#`, which browsers never send to any server). Both sides derive two unguessable topic names from the
//! key, one for commands and one for replies, and encrypt every message with AES-256-GCM (the topic name is
//! bound in as associated data). Each command carries a timestamp and a random id; Ajar drops anything older
//! than 5 minutes, from the future, or already seen, so a captured message can't be replayed.
//!
//! The relay sees only random-looking topic names and ciphertext. Ajar only publishes when the phone asks,
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
use std::sync::Arc;
use std::time::Duration;

pub const DEFAULT_SERVER: &str = "https://ntfy.sh";
/// Commands the phone panel may send.
pub const ALLOWED: &[&str] = &["panel", "mode", "release", "preset", "watch", "track", "sleep_now", "set", "schema", "power"];
const MAX_AGE: u64 = 300;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub enabled: bool,
    /// Base64url, 32 bytes. Empty until pairing.
    pub key: String,
    pub server: String,
    /// Where the phone panel page lives; the QR code links here with the key after `#`.
    pub panel_url: String,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { enabled: false, key: String::new(), server: DEFAULT_SERVER.into(), panel_url: String::new() }
    }
}

impl Settings {
    pub fn load(root: &Path) -> Settings {
        crate::state::load_json(&root.join("remote.json")).unwrap_or_default()
    }
    /// Saved owner-only: whoever has the key can control the laptop.
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
    pub fn key_bytes(&self) -> Option<[u8; 32]> {
        parse_key(&self.key)
    }
    /// The link inside the QR code.
    pub fn pairing_link(&self) -> Option<String> {
        if self.panel_url.is_empty() || self.key_bytes().is_none() {
            return None;
        }
        let server = if self.server == DEFAULT_SERVER { String::new() } else { format!("&s={}", crate::format::url_encode(&self.server)) };
        Some(format!("{}#k={}{server}", self.panel_url, self.key))
    }
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
        format!("ajar-{}", &hex(&h.finalize())[..24])
    };
    (t(b"ajar/cmd/v1"), t(b"ajar/reply/v1"))
}

pub fn seal(key: &[u8; 32], topic: &str, plaintext: &str) -> String {
    let cipher = Aes256Gcm::new_from_slice(key).expect("32-byte key");
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).expect("random nonce");
    let ct = cipher.encrypt(Nonce::from_slice(&nonce), Payload { msg: plaintext.as_bytes(), aad: topic.as_bytes() }).expect("encrypt");
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
    let pt = cipher.decrypt(Nonce::from_slice(&raw[..12]), Payload { msg: &raw[12..], aad: topic.as_bytes() }).ok()?;
    String::from_utf8(pt).ok()
}

/// Rejects stale, future-dated, replayed and too-frequent commands.
#[derive(Default)]
pub struct Guard {
    seen: VecDeque<(String, u64)>,
    recent: VecDeque<u64>,
}

impl Guard {
    pub fn check(&mut self, t: u64, id: &str, now: u64) -> Result<(), &'static str> {
        if id.is_empty() || id.len() > 64 {
            return Err("bad id");
        }
        if t + MAX_AGE < now || t > now + 60 {
            return Err("too old or from the future (check the phone's clock)");
        }
        while self.seen.front().is_some_and(|(_, at)| at + MAX_AGE + 60 < now) {
            self.seen.pop_front();
        }
        if self.seen.iter().any(|(s, _)| s == id) {
            return Err("already handled");
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

/// Decrypts and validates one relayed command. Returns (id, command, args).
pub fn decode_command(key: &[u8; 32], topic: &str, message: &str, guard: &mut Guard, now: u64) -> Result<(String, String, Value), String> {
    let text = open(key, topic, message).ok_or("couldn't decrypt (wrong key, or not from your phone)")?;
    let v: Value = serde_json::from_str(&text).map_err(|_| "not JSON")?;
    let id = v["n"].as_str().unwrap_or("").to_string();
    let t = v["t"].as_u64().ok_or("no timestamp")?;
    guard.check(t, &id, now).map_err(str::to_string)?;
    let cmd = v["cmd"].as_str().unwrap_or("").to_string();
    if !ALLOWED.contains(&cmd.as_str()) {
        return Err(format!("{cmd:?} isn't allowed from the phone"));
    }
    let args = v.get("args").cloned().filter(Value::is_object).unwrap_or_else(|| json!({}));
    Ok((id, cmd, args))
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_connect(Some(Duration::from_secs(15)))
        // The stream is reopened every 5 minutes (from the last message id, so nothing is missed); this also
        // notices a connection that died silently.
        .timeout_recv_body(Some(Duration::from_secs(300)))
        .tls_config(ureq::tls::TlsConfig::builder().root_certs(ureq::tls::RootCerts::PlatformVerifier).build())
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
        let list: Vec<Value> = result["settings"].as_array().map(|a| {
            a.iter().map(|s| Value::Object(s.as_object().map(|o| o.iter().filter(|(k, _)| keep.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect()).unwrap_or_default())).collect()
        }).unwrap_or_default();
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

/// Listens for phone commands until `stop` is set. `run` executes one allowed command and returns the reply.
/// `cursor` stores the id of the last message handled, so a restart picks up exactly where it left off and
/// never runs the same command twice. With no cursor yet, only new messages are read.
pub fn listen(settings: Settings, cursor: std::path::PathBuf, stop: Arc<AtomicBool>, mut run: impl FnMut(&str, Value) -> Value, mut on_error: impl FnMut(Option<String>)) {
    let Some(key) = settings.key_bytes() else { return };
    let (cmd_topic, reply_topic) = topics(&key);
    let server = settings.server.trim_end_matches('/').to_string();
    let valid_id = |s: &str| !s.is_empty() && s.len() <= 32 && s.chars().all(|c| c.is_ascii_alphanumeric());
    let mut since: Option<String> = crate::state::read(&cursor).map(|s| s.trim().to_string()).filter(|s| valid_id(s));
    let mut guard = Guard::default();
    let mut backoff = 5u64;
    while !stop.load(Ordering::SeqCst) {
        let url = match &since {
            Some(id) => format!("{server}/{cmd_topic}/json?since={id}"),
            None => format!("{server}/{cmd_topic}/json"),
        };
        match agent().get(&url).call() {
            Ok(resp) => {
                on_error(None);
                backoff = 5;
                use std::io::BufRead;
                let reader = std::io::BufReader::new(resp.into_body().into_reader());
                for line in reader.lines() {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    let Ok(line) = line else { break };
                    let Ok(ev) = serde_json::from_str::<Value>(&line) else { continue };
                    if ev["event"] != "message" {
                        continue;
                    }
                    if let Some(id) = ev["id"].as_str().filter(|id| valid_id(id)) {
                        since = Some(id.to_string());
                        let _ = std::fs::write(&cursor, id);
                    }
                    let now = crate::now();
                    let reply = match decode_command(&key, &cmd_topic, ev["message"].as_str().unwrap_or(""), &mut guard, now) {
                        Ok((n, cmd, args)) => {
                            let mut r = run(&cmd, args);
                            r["re"] = json!(n);
                            r
                        }
                        // Garbage on the topic gets no reply (nothing to tell a stranger); bad clocks and
                        // rate limits from the real phone do.
                        Err(e) if e.contains("decrypt") || e.contains("JSON") => continue,
                        Err(e) => json!({ "ok": false, "error": e }),
                    };
                    let mut body = reply;
                    body["t"] = json!(now);
                    if let Err(e) = publish(&server, &key, &reply_topic, &body) {
                        on_error(Some(format!("Couldn't reach {server}: {e}")));
                    }
                }
            }
            Err(e) => {
                on_error(Some(format!("Couldn't reach {server}: {e}")));
                for _ in 0..backoff {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    std::thread::sleep(Duration::from_secs(1));
                }
                backoff = (backoff * 2).min(120);
            }
        }
    }
}

/// An SVG QR code for the pairing link.
pub fn qr_svg(link: &str) -> Option<String> {
    let code = qrcode::QrCode::with_error_correction_level(link.as_bytes(), qrcode::EcLevel::M).ok()?;
    Some(code.render::<qrcode::render::svg::Color>().min_dimensions(280, 280).quiet_zone(true).build())
}

/// The local page the tray menu opens: QR code, the link, and what it does.
pub fn pairing_page(link: &str) -> String {
    let qr = qr_svg(link).unwrap_or_default();
    let esc = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('"', "&quot;");
    format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ajar phone control</title>
<style>
:root{{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--sub:#6e6e73;--amber:#f2a12c}}
@media (prefers-color-scheme:dark){{:root{{--bg:#000;--card:#1c1c1e;--text:#f5f5f7;--sub:#98989d}}}}
body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,"Segoe UI",system-ui,sans-serif;display:flex;justify-content:center}}
main{{max-width:420px;margin:40px 16px;background:var(--card);border-radius:18px;padding:28px;text-align:center}}
h1{{font-size:22px;margin:0 0 6px}} p{{color:var(--sub);margin:6px 0}} svg{{width:260px;height:260px;margin:18px auto;display:block;background:#fff;border-radius:12px}}
code{{display:block;word-break:break-all;font-size:11px;color:var(--sub);margin-top:14px}}
</style></head><body><main>
<h1>Control Ajar from your phone</h1>
<p>Scan with the phone's camera, then add the page to your home screen.</p>
{qr}
<p>Works from anywhere with internet. Messages are end-to-end encrypted; the key never leaves the link.</p>
<p>Anyone with this code can control this laptop. Turn phone control off in Ajar's menu to cancel it.</p>
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
        assert!(c.starts_with("ajar-") && c.len() == 29 && c != r);
        let m = seal(&key, &c, "{\"cmd\":\"panel\"}");
        assert_eq!(open(&key, &c, &m).as_deref(), Some("{\"cmd\":\"panel\"}"));
        assert!(open(&key, &r, &m).is_none(), "a message moved to the other topic doesn't open");
        let other = parse_key(&new_key()).unwrap();
        assert!(open(&other, &c, &m).is_none(), "wrong key doesn't open");
        let mut tampered = B64.decode(&m).unwrap();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert!(open(&key, &c, &B64.encode(tampered)).is_none(), "tampering is detected");
        assert!(open(&key, &c, "not base64!!").is_none());
    }

    #[test]
    fn replays_stale_and_floods_are_rejected() {
        let key = parse_key(&new_key()).unwrap();
        let (c, _) = topics(&key);
        let now = 1_000_000;
        let mut g = Guard::default();
        let msg = |t: u64, n: &str, cmd: &str| seal(&key, &c, &json!({ "t": t, "n": n, "cmd": cmd }).to_string());
        assert!(decode_command(&key, &c, &msg(now, "a1", "panel"), &mut g, now).is_ok());
        assert!(decode_command(&key, &c, &msg(now, "a1", "panel"), &mut g, now).unwrap_err().contains("already"), "replay");
        assert!(decode_command(&key, &c, &msg(now - 600, "a2", "panel"), &mut g, now).is_err(), "stale");
        assert!(decode_command(&key, &c, &msg(now + 600, "a3", "panel"), &mut g, now).is_err(), "future");
        assert!(decode_command(&key, &c, &msg(now, "a4", "override_floor"), &mut g, now).unwrap_err().contains("allowed"));
        for i in 0..40 {
            let r = decode_command(&key, &c, &msg(now, &format!("f{i}"), "panel"), &mut g, now);
            if i >= 28 {
                assert!(r.is_err(), "flood limited by {i}");
            }
        }
    }

    #[test]
    fn pairing_link_and_qr() {
        let s = Settings { enabled: true, key: new_key(), server: DEFAULT_SERVER.into(), panel_url: "https://example.org/panel".into() };
        let link = s.pairing_link().unwrap();
        assert!(link.starts_with("https://example.org/panel#k=") && !link.contains("&s="));
        assert!(qr_svg(&link).unwrap().contains("<svg"));
        assert!(Settings { panel_url: String::new(), ..s }.pairing_link().is_none());
    }

    #[test]
    fn phone_reply_fits_one_ntfy_message() {
        let key = parse_key(&new_key()).unwrap();
        let (_, rep) = topics(&key);
        let watch: Vec<Value> = (0..40).map(|i| json!({ "id": format!("/Applications/Some Long Application Name {i}.app"), "name": format!("Some Long Application Name {i}"), "on": i < 2 })).collect();
        let agents: Vec<Value> = (0..12).map(|i| json!({ "id": format!("agent{i}"), "name": format!("Agent number {i}"), "working": true, "keeps": true, "instances": 1 })).collect();
        let holds = vec!["Asked to stay awake"; 20];
        let panel = json!({ "headline": "Close the lid: keeps working", "watch": watch, "agents": agents, "holds": holds });
        let result = json!({ "ok": true, "headline": "dup", "watch": panel["watch"].clone() });
        let r = phone_reply("panel", &result, panel);
        assert!(r.get("headline").is_none(), "the command's full result isn't repeated");
        assert_eq!(r["panel"]["watch"].as_array().unwrap().len(), 2, "apps already kept awake stay");
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
        assert!(first.get("key").is_some() && first.get("value").is_some() && first.get("description").is_none());
        assert!(r.to_string().len() < MAX_REPLY);
    }
}

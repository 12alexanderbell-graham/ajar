//! How the `nocturnal` command and the MCP server talk to the running app: a request file dropped into
//! `requests/`, answered in `replies/`. Plain files keep it identical on Windows and Linux, need no open port,
//! and are protected by the folder's permissions (owner-only on Linux, the user profile on Windows).

use serde_json::{json, Value};
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

const MAX_REQUEST_BYTES: u64 = 64 * 1024;
const STALE_SECS: u64 = 60;

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 40 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

fn new_id() -> String {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:x}-{:x}", t, std::process::id())
}

/// The app's heartbeat is recent: someone is there to answer.
pub fn app_running(root: &Path) -> bool {
    crate::state::age_of(&root.join("alive")).is_some_and(|a| a < 15)
}

/// Client side: send a command and wait for the answer.
pub fn call(root: &Path, cmd: &str, args: Value, timeout: Duration) -> Result<Value, String> {
    if !app_running(root) {
        return Err(
            "Nocturnal isn't running. Start the Nocturnal app first (it lives in the system tray).".into(),
        );
    }
    let req = root.join("requests");
    let rep = root.join("replies");
    crate::state::ensure_private_dir(&req);
    crate::state::ensure_private_dir(&rep);
    let id = new_id();
    let body = json!({ "cmd": cmd, "args": args }).to_string();
    let tmp = req.join(format!("{id}.tmp"));
    fs::write(&tmp, body).map_err(|e| format!("couldn't write the request: {e}"))?;
    fs::rename(&tmp, req.join(format!("{id}.json")))
        .map_err(|e| format!("couldn't send the request: {e}"))?;
    let reply = rep.join(format!("{id}.json"));
    let start = Instant::now();
    while start.elapsed() < timeout {
        if let Some(text) = crate::state::read(&reply) {
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                crate::state::remove(&reply);
                return Ok(v);
            }
        }
        std::thread::sleep(Duration::from_millis(40));
    }
    crate::state::remove(&req.join(format!("{id}.json")));
    Err(
        "Nocturnal didn't answer in time. It may be busy or stuck; try again, or restart the app."
            .into(),
    )
}

/// Server side: take every waiting request (oldest first). Junk, oversized and stale files are dropped.
pub fn take_requests(root: &Path) -> Vec<(String, String, Value)> {
    let req = root.join("requests");
    let Ok(entries) = fs::read_dir(&req) else {
        return vec![];
    };
    let mut found = vec![];
    for e in entries.flatten() {
        let path = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        let Some(id) = name.strip_suffix(".json") else {
            // Leftover temp files from a client that died mid-write.
            if name.ends_with(".tmp") && age(&path) > STALE_SECS {
                crate::state::remove(&path);
            }
            continue;
        };
        let meta = e.metadata().ok();
        let ok_size = meta
            .as_ref()
            .is_some_and(|m| m.is_file() && m.len() <= MAX_REQUEST_BYTES);
        let id = id.to_string();
        let text = if ok_size && valid_id(&id) && age(&path) <= STALE_SECS {
            crate::state::read(&path)
        } else {
            None
        };
        crate::state::remove(&path);
        let Some(v) = text.and_then(|t| serde_json::from_str::<Value>(&t).ok()) else {
            continue;
        };
        let cmd = v
            .get("cmd")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let args = v
            .get("args")
            .cloned()
            .filter(Value::is_object)
            .unwrap_or_else(|| json!({}));
        let modified = meta.and_then(|m| m.modified().ok());
        found.push((modified, id, cmd, args));
    }
    found.sort_by_key(|x| x.0);
    found
        .into_iter()
        .map(|(_, id, cmd, args)| (id, cmd, args))
        .collect()
}

pub fn reply(root: &Path, id: &str, v: &Value) {
    if !valid_id(id) {
        return;
    }
    let rep = root.join("replies");
    crate::state::ensure_private_dir(&rep);
    let _ = crate::state::write_atomic(&rep.join(format!("{id}.json")), &v.to_string());
}

/// Replies nobody collected (the client gave up) are removed after a minute.
pub fn sweep_replies(root: &Path) {
    let Ok(entries) = fs::read_dir(root.join("replies")) else {
        return;
    };
    for e in entries.flatten() {
        if age(&e.path()) > STALE_SECS {
            crate::state::remove(&e.path());
        }
    }
}

fn age(p: &Path) -> u64 {
    fs::metadata(p)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|m| m.elapsed().ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("nocturnal-ipc-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(d.join("requests")).unwrap();
        d
    }

    #[test]
    fn round_trip_through_files() {
        let root = tmp("rt");
        crate::state::touch(&root.join("alive"));
        let r2 = root.clone();
        let server = std::thread::spawn(move || {
            for _ in 0..100 {
                let reqs = take_requests(&r2);
                if let Some((id, cmd, args)) = reqs.into_iter().next() {
                    reply(&r2, &id, &json!({ "ok": true, "echo": cmd, "args": args }));
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        let v = call(&root, "status", json!({ "x": 1 }), Duration::from_secs(3)).unwrap();
        server.join().unwrap();
        assert_eq!(v["echo"], "status");
        assert_eq!(v["args"]["x"], 1);
        assert!(
            fs::read_dir(root.join("replies")).unwrap().next().is_none(),
            "reply file is cleaned up"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn junk_is_dropped_not_executed() {
        let root = tmp("junk");
        let req = root.join("requests");
        fs::write(req.join("ok1.json"), r#"{"cmd":"status"}"#).unwrap();
        fs::write(req.join("bad.json"), "not json").unwrap();
        fs::write(req.join("../escape.json"), r#"{"cmd":"status"}"#).ok();
        fs::write(req.join("has space.json"), r#"{"cmd":"status"}"#).unwrap();
        fs::write(req.join("big.json"), "x".repeat(70_000)).unwrap();
        fs::write(req.join("args.json"), r#"{"cmd":"mode","args":[1,2]}"#).unwrap();
        let got = take_requests(&root);
        let ids: Vec<&str> = got.iter().map(|g| g.0.as_str()).collect();
        assert!(ids.contains(&"ok1"));
        assert!(ids.contains(&"args"));
        assert_eq!(got.len(), 2, "{ids:?}");
        assert!(
            got.iter().find(|g| g.0 == "args").unwrap().2.is_object(),
            "non-object args become {{}}"
        );
        assert!(
            fs::read_dir(&req).unwrap().next().is_none(),
            "everything is consumed"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn call_fails_fast_when_app_is_not_running() {
        let root = tmp("down");
        let t = Instant::now();
        assert!(call(&root, "status", json!({}), Duration::from_secs(5)).is_err());
        assert!(t.elapsed() < Duration::from_millis(500));
        let _ = fs::remove_dir_all(&root);
    }
}

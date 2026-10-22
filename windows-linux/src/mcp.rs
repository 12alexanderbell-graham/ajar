//! MCP server (`nocturnal mcp`), so Claude Code, Codex, Gemini CLI or any MCP client can ask Nocturnal to stay awake,
//! check the battery, or change a rule. JSON-RPC 2.0 over stdin/stdout, one message per line.
//!
//! Holds made through MCP are tied to this server process: when the agent session ends (and with it this
//! server), the hold ends too, so a crashed agent never keeps a laptop awake in a bag.

use serde_json::{json, Value};
use std::io::{BufRead, Write};

pub const PROTOCOL: &str = "2025-06-18";

fn tool(name: &str, description: &str, props: Value, required: &[&str]) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": { "type": "object", "properties": props, "required": required, "additionalProperties": false },
    })
}

pub fn tools() -> Value {
    json!([
        tool("status", "What Nocturnal is doing: whether closing the lid keeps the machine working, battery %, hours left with the lid closed, which agents it sees and whether they're working, and the apps using the most CPU.", json!({}), &[]),
        tool("stay_awake", "Keep the machine awake, including with the lid closed, until released, for a number of minutes, or until this session ends. Use before long unattended work.", json!({
            "reason": { "type": "string", "description": "Shown in the tray menu, e.g. 'Running the test suite'" },
            "minutes": { "type": "number", "description": "Optional limit (max 10080 = 7 days)" },
        }), &[]),
        tool("release", "End a stay_awake hold this session made (by id), or all of this session's holds when no id is given.", json!({
            "id": { "type": "string" },
        }), &[]),
        tool("set_mode", "off = never keep awake; auto (When Busy) = only while an agent is working; always = until turned off or for a number of minutes.", json!({
            "mode": { "type": "string", "enum": ["off", "auto", "always"] },
            "minutes": { "type": "number" },
        }), &["mode"]),
        tool("set_preset", "How hard to save battery while the lid is closed.", json!({
            "preset": { "type": "string", "enum": ["max_battery", "balanced", "full_speed"] },
        }), &["preset"]),
        tool("set_app_rule", "What happens to an app while the lid is closed: leave it, slow it, pause it (frozen until the lid opens), or default (back to the preset).", json!({
            "app": { "type": "string", "description": "Executable name, e.g. chrome, spotify, slack" },
            "rule": { "type": "string", "enum": ["leave", "slow", "pause", "default"] },
        }), &["app", "rule"]),
        tool("watch_app", "Make an app keep the machine awake while it's busy (e.g. blender, ffmpeg), or stop watching it.", json!({
            "app": { "type": "string" },
            "remove": { "type": "boolean" },
        }), &["app"]),
        tool("energy", "Apps using the most CPU right now and what happens to each while the lid is closed.", json!({}), &[]),
        tool("settings", "List every Nocturnal setting with its current value, allowed values, what it does and any safety rule. Read this before changing settings.", json!({}), &[]),
        tool("set_setting", "Change one setting (see settings for every key and what it does). Safety settings can only be made stricter from here: battery_floor can only go up and heat_guard can only be turned on.", json!({
            "key": { "type": "string", "enum": crate::ai::SETTINGS.iter().map(|s| s.key).collect::<Vec<_>>() },
            "value": { "description": "Number, on/off, or text" },
        }), &["key", "value"]),
        tool("power", "Power use right now and what is using it, with the setting that would cut each (busy apps, preset, power saver), plus what the laptop learned it draws open and closed.", json!({}), &[]),
        tool("setup_prompt", "The recommended steps for setting Nocturnal up with the person. Use when asked to set up or tune Nocturnal.", json!({}), &[]),
    ])
}

/// Maps a tool call to an Nocturnal command and its arguments.
pub fn to_command(name: &str, args: &Value, server_pid: u32) -> Option<(&'static str, Value)> {
    let mut a = args.clone();
    if !a.is_object() {
        a = json!({});
    }
    Some(match name {
        "status" => ("status", a),
        "energy" => ("energy", a),
        "stay_awake" => {
            if a.get("reason")
                .and_then(Value::as_str)
                .is_none_or(|r| r.trim().is_empty())
            {
                a["reason"] = json!("Asked by an agent");
            }
            a["pid"] = json!(server_pid);
            ("hold", a)
        }
        // An agent ends only its own holds: one by id, or all of this session's. Never the person's or other
        // agents' (calling release() with no arguments is common).
        "release" => match a.get("id").and_then(Value::as_str).map(str::to_string) {
            Some(id) => ("release_own", json!({ "id": id, "pid": server_pid })),
            None => ("release_pid", json!({ "pid": server_pid })),
        },
        "set_mode" => ("mode", a),
        "set_preset" => ("preset", a),
        "set_app_rule" => ("rule", a),
        "watch_app" => ("watch", a),
        "set_setting" => ("set", a),
        "settings" => ("schema", a),
        "power" => ("power", a),
        _ => return None,
    })
}

/// One JSON-RPC message in, at most one out. `run` executes an Nocturnal command.
pub fn handle(
    msg: &Value,
    server_pid: u32,
    run: &mut dyn FnMut(&str, Value) -> Result<Value, String>,
) -> Option<Value> {
    let id = msg.get("id").cloned();
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
    // Notifications (no id) never get a reply.
    let id = id?;
    let result = match method {
        "initialize" => {
            let asked = msg
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or(PROTOCOL);
            json!({
                "protocolVersion": asked,
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "nocturnal", "version": env!("CARGO_PKG_VERSION") },
                "instructions": "Nocturnal keeps this laptop awake with the lid closed while you work. Call stay_awake before long unattended work and release when done; check status for battery and hours left. To tune it: settings lists every setting, power shows what's using power and which setting fixes it. If asked to set Nocturnal up, follow setup_prompt.",
            })
        }
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tools() }),
        "tools/call" => {
            let name = msg
                .pointer("/params/name")
                .and_then(Value::as_str)
                .unwrap_or("");
            let args = msg
                .pointer("/params/arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            if name == "setup_prompt" {
                return Some(
                    json!({ "jsonrpc": "2.0", "id": id, "result": { "content": [{ "type": "text", "text": crate::ai::SETUP_PROMPT }], "isError": false } }),
                );
            }
            match to_command(name, &args, server_pid) {
                None => {
                    return Some(
                        json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32602, "message": format!("Unknown tool {name}") } }),
                    )
                }
                Some((cmd, a)) => match run(cmd, a) {
                    Ok(v) => {
                        let failed = v.get("ok") == Some(&json!(false));
                        json!({ "content": [{ "type": "text", "text": serde_json::to_string_pretty(&v).unwrap_or_default() }], "isError": failed })
                    }
                    Err(e) => {
                        json!({ "content": [{ "type": "text", "text": e }], "isError": true })
                    }
                },
            }
        }
        _ => {
            return Some(
                json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": format!("Method not found: {method}") } }),
            )
        }
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

/// Runs until stdin closes.
pub fn serve(root: &std::path::Path) {
    let pid = std::process::id();
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    let mut run = |cmd: &str, args: Value| {
        crate::ipc::call(root, cmd, args, std::time::Duration::from_secs(10))
    };
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(Value::Array(batch)) => {
                let replies: Vec<Value> = batch
                    .iter()
                    .filter_map(|m| handle(m, pid, &mut run))
                    .collect();
                (!replies.is_empty()).then_some(Value::Array(replies))
            }
            Ok(msg) => handle(&msg, pid, &mut run),
            Err(_) => Some(
                json!({ "jsonrpc": "2.0", "id": null, "error": { "code": -32700, "message": "Parse error" } }),
            ),
        };
        if let Some(r) = reply {
            if writeln!(out, "{r}").and_then(|_| out.flush()).is_err() {
                break;
            }
        }
    }
    // Session over: drop any hold this server made (the app also notices the pid is gone).
    let _ = crate::ipc::call(
        root,
        "release_pid",
        json!({ "pid": pid }),
        std::time::Duration::from_secs(2),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialize_and_list() {
        let mut run = |_: &str, _: Value| Ok(json!({}));
        let r = handle(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}), 9, &mut run).unwrap();
        assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
        let r = handle(
            &json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
            9,
            &mut run,
        )
        .unwrap();
        assert!(r["result"]["tools"].as_array().unwrap().len() >= 9);
        assert!(handle(
            &json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
            9,
            &mut run
        )
        .is_none());
    }

    #[test]
    fn stay_awake_is_tied_to_the_server_process() {
        let mut seen = None;
        let mut run = |cmd: &str, a: Value| {
            seen = Some((cmd.to_string(), a));
            Ok(json!({"ok": true}))
        };
        let r = handle(&json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"stay_awake","arguments":{"minutes":30}}}), 4242, &mut run).unwrap();
        assert_eq!(r["result"]["isError"], false);
        let (cmd, a) = seen.unwrap();
        assert_eq!(cmd, "hold");
        assert_eq!(a["pid"], 4242);
        assert_eq!(a["reason"], "Asked by an agent");
    }

    #[test]
    fn release_only_covers_this_session() {
        assert_eq!(
            to_command("release", &json!({}), 77).unwrap(),
            ("release_pid", json!({ "pid": 77 }))
        );
        assert_eq!(
            to_command("release", &json!({ "id": "ab" }), 77).unwrap(),
            ("release_own", json!({ "id": "ab", "pid": 77 }))
        );
    }

    #[test]
    fn errors_are_reported_not_thrown() {
        let mut run = |_: &str, _: Value| Err("Nocturnal isn't running".to_string());
        let r = handle(
            &json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"status"}}),
            1,
            &mut run,
        )
        .unwrap();
        assert_eq!(r["result"]["isError"], true);
        let r = handle(
            &json!({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rm_rf"}}),
            1,
            &mut run,
        )
        .unwrap();
        assert_eq!(r["error"]["code"], -32602);
        let r = handle(
            &json!({"jsonrpc":"2.0","id":6,"method":"nope"}),
            1,
            &mut run,
        )
        .unwrap();
        assert_eq!(r["error"]["code"], -32601);
    }
}

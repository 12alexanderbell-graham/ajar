#!/usr/bin/env bash
# End-to-end test of the real Linux build against a fake logind + power-profiles-daemon (examples/fake_logind.rs)
# and a fake sysfs tree. Runs the real tray app under Xvfb, drives it with the real `nocturnal` CLI, and checks what
# actually happened to processes, inhibitor locks, suspend calls and the power profile.
set -u
cd "$(dirname "$0")/.."
BIN=${BIN:-target/debug}
T=$(mktemp -d /tmp/nocturnal-e2e.XXXX)
export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config NOCTURNAL_SYSFS_ROOT=$T/sys
mkdir -p "$HOME" "$NOCTURNAL_SYSFS_ROOT"
PASS=0; FAIL=0
ok()   { echo "  ok   $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

# Fake hardware: a laptop chassis, one battery at 80% discharging 8 W, a cool CPU.
S=$NOCTURNAL_SYSFS_ROOT
mkdir -p $S/class/dmi/id $S/class/power_supply/BAT0 $S/class/power_supply/AC $S/class/thermal/thermal_zone0
echo 10 > $S/class/dmi/id/chassis_type
echo Battery > $S/class/power_supply/BAT0/type; echo Discharging > $S/class/power_supply/BAT0/status
echo 80 > $S/class/power_supply/BAT0/capacity; echo 8000000 > $S/class/power_supply/BAT0/power_now
echo 60000000 > $S/class/power_supply/BAT0/energy_full; echo 48000000 > $S/class/power_supply/BAT0/energy_now
echo Mains > $S/class/power_supply/AC/type; echo 0 > $S/class/power_supply/AC/online
echo x86_pkg_temp > $S/class/thermal/thermal_zone0/type; echo 50000 > $S/class/thermal/thermal_zone0/temp

# Private buses: one plays the system bus (logind), one the session bus.
SYS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>$T/sys.pid)
SES=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>$T/ses.pid)
export DBUS_SYSTEM_BUS_ADDRESS=$SYS DBUS_SESSION_BUS_ADDRESS=$SES
${FAKE:-target/debug/examples/fake_logind} 2>$T/logind.log & LOGIND=$!
sleep 0.5
fake() { busctl --address="$SYS" call test.Fake /test test.Fake "$@"; }
state() { fake State | awk '{print $2, $3, $4, $5}'; }   # lid inhibitors suspends "profile"

Xvfb :77 -screen 0 1280x800x24 >/dev/null 2>&1 & XV=$!
export DISPLAY=:77
sleep 0.5
stalonetray --geometry 4x1+1100+0 --icon-size 32 -bg '#ececec' >/dev/null 2>&1 & TRAY=$!
sleep 0.5

cleanup() { kill $APP $LOGIND $XV $TRAY $SLACK 2>/dev/null; kill $(cat $T/sys.pid $T/ses.pid) 2>/dev/null; }
trap cleanup EXIT

start_app() { $BIN/nocturnal-app >$T/app.log 2>&1 & APP=$!; for _ in $(seq 50); do $BIN/nocturnal status >/dev/null 2>&1 && return; sleep 0.2; done; }
start_app
echo "1. Startup"
check "app answers the CLI" "$BIN/nocturnal status --json | grep -q '\"ok\": true'"
check "sees a laptop with a lid" "$BIN/nocturnal status --json | grep -q '\"has_lid\": true'"
check "reads the fake battery (80%)" "$BIN/nocturnal status --json | grep -q '\"percent\": 80'"
check "second copy refuses to start" "timeout 3 $BIN/nocturnal-app; [ \$? -eq 0 ]"

# A stand-in for Slack: a copy of `sleep` named slack, detached so it isn't inside this test's own process
# tree (this test may itself run under an AI agent, whose whole tree Nocturnal rightly never touches).
cp "$(command -v sleep)" $T/slack; setsid -f $T/slack 600; sleep 0.3; SLACK=$(pgrep -f "$T/slack" | head -1)
# If the test runs under an agent, Nocturnal sees it working; keep it out of the decisions.
$BIN/nocturnal status --json | grep -q '"Claude Code"' && echo "  (running under Claude Code: marking it track-only for the test)"
python3 - "$XDG_CONFIG_HOME/nocturnal/config.json" <<'PY'
import json,sys,os,time
p=sys.argv[1]; c=json.load(open(p)); c["trackOnly"]=["claude-code","claude-app","codex","gemini"]
open(p,"w").write(json.dumps(c)); t=time.time()+3; os.utime(p,(t,t))
PY
sleep 11
nice_of() { awk '{print $19}' /proc/$1/stat; }
stopped() { awk '{print $3}' /proc/$1/stat | grep -q T; }

echo "2. Always on, lid closed"
$BIN/nocturnal on 30 >/dev/null
check "holds one logind inhibitor" "[ \"\$(state | cut -d' ' -f2)\" = 1 ]"
fake SetLid b true; sleep 3
check "notices the lid closing" "$BIN/nocturnal status --json | grep -q '\"lid_closed\": true'"
check "power profile switched to power-saver" "state | grep -q power-saver"
check "Balanced slows Slack (nice 19)" "[ \"\$(nice_of $SLACK)\" = 19 ]"
$BIN/nocturnal preset max_battery >/dev/null; sleep 3
check "Max Battery pauses Slack" "stopped $SLACK"
check "journal records it on disk" "grep -q slack $XDG_CONFIG_HOME/nocturnal/touched.json"

echo "3. Turning off with the lid closed"
$BIN/nocturnal off >/dev/null; sleep 2
check "inhibitor released" "[ \"\$(state | cut -d' ' -f2)\" = 0 ]"
check "asked logind to suspend once" "[ \"\$(state | cut -d' ' -f3)\" = 1 ]"
check "Slack resumed" "! stopped $SLACK"
check "Slack priority restored" "[ \"\$(nice_of $SLACK)\" = 0 ]"
check "power profile restored" "state | grep -q balanced"
check "journal emptied" "[ ! -e $XDG_CONFIG_HOME/nocturnal/touched.json ]"
fake SetLid b false; sleep 3

echo "4. Crash while holding with Slack paused"
$BIN/nocturnal on >/dev/null; fake SetLid b true; sleep 3
check "Slack paused again" "stopped $SLACK"
kill -9 $APP; wait $APP 2>/dev/null; sleep 0.5
check "kernel dropped the inhibitor with the process" "[ \"\$(state | cut -d' ' -f2)\" = 0 ]"
check "watchdog cleans up a dead app at once" "[ \"\$($BIN/nocturnal-app watchdog)\" = restored ]"
check "watchdog resumed Slack" "! stopped $SLACK"
check "watchdog restored power profile" "state | grep -q balanced"

echo "5. Crash, then the app restarts before the watchdog"
start_app; sleep 3
check "holds again after restart (Always survived)" "[ \"\$(state | cut -d' ' -f2)\" = 1 ]"
check "Slack paused by the new app" "stopped $SLACK"
kill -9 $APP; wait $APP 2>/dev/null
start_app; sleep 1
check "startup recovery happened then rules re-applied" "stopped $SLACK"
fake SetLid b false; sleep 3
check "lid open: Slack resumed" "! stopped $SLACK"
$BIN/nocturnal auto >/dev/null

echo "6. nocturnal run"
( $BIN/nocturnal run -- sleep 4 ) & RUN=$!
sleep 1.5
check "holding while the command runs" "$BIN/nocturnal status --json | grep -q '\"keeping_awake\": true'"
wait $RUN; RC=$?
sleep 2.5
check "exit code passed through" "[ $RC = 0 ]"
check "released after it ends" "$BIN/nocturnal status --json | grep -q '\"keeping_awake\": false'"
$BIN/nocturnal run -- sh -c 'exit 7'; check "non-zero exit code passed through" "[ \$? = 7 ]"

echo "7. Safety can't be loosened from outside the menu"
check "CLI can't turn off the heat guard" "! $BIN/nocturnal set heat_guard off >/dev/null"
check "CLI can't lower the battery limit" "! $BIN/nocturnal set battery_floor 5 >/dev/null"
python3 - "$XDG_CONFIG_HOME/nocturnal/config.json" <<'PY'
import json,sys,os,time
p=sys.argv[1]; c=json.load(open(p)); c["heatGuard"]=False; c["batteryFloor"]=0; c["preset"]="speed"
open(p,"w").write(json.dumps(c)); t=time.time()+5; os.utime(p,(t,t))
PY
sleep 12
check "hand edit can't turn off the heat guard" "$BIN/nocturnal config --json | grep -q '\"heatGuard\": true'"
check "hand edit can't lower the battery limit" "$BIN/nocturnal config --json | grep -q '\"batteryFloor\": 15'"
check "the harmless part of the edit applied" "$BIN/nocturnal config --json | grep -q '\"preset\": \"speed\"'"

echo "7b. Waking up and approvals"
check "check-in interval can be set" "$BIN/nocturnal check-in 30 >/dev/null && $BIN/nocturnal config --json | grep -q '\"checkInMinutes\": 30'"
check "a bad check-in interval is refused" "! $BIN/nocturnal check-in 7 >/dev/null"
check "wake-at sets a scheduled wake" "$BIN/nocturnal wake-at 07:00 >/dev/null && $BIN/nocturnal config --json | grep -q '\"wakeAt\": [0-9]'"
check "wake-at off clears it" "$BIN/nocturnal wake-at off >/dev/null && $BIN/nocturnal config --json | grep -q '\"wakeAt\": null'"
check "approve everything can't be turned on from the CLI" "! $BIN/nocturnal set auto_approve on >/dev/null 2>&1 && [ ! -e \"$XDG_CONFIG_HOME/nocturnal/auto-approve.json\" ]"
$BIN/nocturnal check-in 0 >/dev/null

echo "8. MCP"
OUT=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"stay_awake","arguments":{"reason":"MCP test"}}}' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status"}}' | $BIN/nocturnal mcp)
check "MCP initialize answers" "echo \"\$OUT\" | grep -q protocolVersion"
check "MCP stay_awake made a hold" "echo \"\$OUT\" | grep -q 'MCP test'"
sleep 3
check "hold ended with the MCP session" "! $BIN/nocturnal status --json | grep -q 'MCP test'"

echo "8b. AI layer"
check "settings lists every key with values" "$BIN/nocturnal settings --json | grep -q '\"key\": \"battery_floor\"'"
check "settings human output explains keys" "$BIN/nocturnal settings | grep -q 'Sleep when the battery reaches'"
check "set accepts preset through the same call" "$BIN/nocturnal set preset balanced >/dev/null && $BIN/nocturnal settings --json | grep -A3 '\"key\": \"preset\"' | grep -q balanced"
check "power report answers with suspects" "$BIN/nocturnal power --json | grep -q '\"suspects\"'"
check "unknown key lists the real keys" "$BIN/nocturnal set nonsense 1 2>&1 | grep -q 'pause\\|quiet_minutes'"
OUT2=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"settings"}}' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"setup_prompt"}}' | $BIN/nocturnal mcp)
check "MCP lists settings, power and setup_prompt" "echo \"\$OUT2\" | grep -q '\"name\":\"power\"' && echo \"\$OUT2\" | grep -q setup_prompt"
check "MCP settings returns the schema" "echo \"\$OUT2\" | grep -q 'battery_floor'"
check "MCP setup prompt says never lower the limit" "echo \"\$OUT2\" | grep -q 'Never turn off the heat guard'"
mkdir -p $T/fakehome/.codex; echo '{"mcpServers":{"other":{"command":"x"}}}' > $T/fakehome/.claude.json
check "connect adds Nocturnal to Claude Code and Codex" "HOME=$T/fakehome $BIN/nocturnal connect >/dev/null && grep -q '\"nocturnal\"' $T/fakehome/.claude.json && grep -q 'other' $T/fakehome/.claude.json && grep -q 'mcp_servers.nocturnal' $T/fakehome/.codex/config.toml"

echo "9. Junk in the command inbox"
printf 'garbage' > $XDG_CONFIG_HOME/nocturnal/requests/x1.json
head -c 100000 /dev/zero > $XDG_CONFIG_HOME/nocturnal/requests/x2.json
sleep 1
check "app still alive after junk" "kill -0 $APP"
check "junk consumed" "[ -z \"\$(ls $XDG_CONFIG_HOME/nocturnal/requests)\" ]"

echo "10. Tray"
sleep 1
import -window root $T/screen.png 2>/dev/null && ok "screenshot taken"
cp $T/screen.png /tmp/nocturnal-e2e-screen.png 2>/dev/null

echo "11. Rescue and uninstall"
$BIN/nocturnal on >/dev/null; fake SetLid b true; sleep 3
$BIN/nocturnal rescue >$T/rescue.log; RC=$?
check "rescue succeeded" "[ $RC = 0 ]"
check "rescue stopped the app" "! kill -0 $APP 2>/dev/null"
check "rescue resumed Slack" "! stopped $SLACK"
check "rescue released the lock" "[ \"\$(state | cut -d' ' -f2)\" = 0 ]"
fake SetLid b false

echo
echo "passed $PASS, failed $FAIL"
[ $FAIL = 0 ]

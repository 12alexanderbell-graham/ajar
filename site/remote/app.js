"use strict";
// Nocturnal's phone page. Same protocol as the computer (Remote.swift on the Mac, remote.rs on Windows and Linux)
// and the iPhone app: each paired phone has its own 256-bit key; two topic names are derived from it; every message
// is AES-256-GCM sealed with its topic name as associated data and relayed by ntfy, which can't read it. The key is
// the only secret and never leaves this phone.

// ---------- Small helpers ----------

const $ = id => document.getElementById(id);
const enc = new TextEncoder(), dec = new TextDecoder();
const b64u = {
  enc: b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""),
  dec: s => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), c => c.charCodeAt(0)),
};
const hex = b => [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, "0")).join("");
const sleep = ms => new Promise(r => setTimeout(r, ms));
const store = {
  get: k => { try { return localStorage.getItem(k); } catch (_) { return null; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch (_) {} },
  del: k => { try { localStorage.removeItem(k); } catch (_) {} },
};
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const standalone = matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
const ios = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const phone = ios || /Android/i.test(navigator.userAgent);
/** Shown next to this phone in the computer's list of paired phones. */
const DEVICE = /iPad/.test(navigator.userAgent) ? "iPad" : ios ? "iPhone" : /Android/i.test(navigator.userAgent) ? "Android phone" : "Browser";

const DEFAULT_SERVER = "https://ntfy.sh";
const REFRESH_MS = 120000;   // asks by itself only after 2 quiet minutes: every tap's answer brings the status anyway
const LIVE_MS = 150000;      // an answer this recent counts as live
const REPLY_WAIT_MS = 20000;

let key = null, cmdTopic = "", replyTopic = "", server = DEFAULT_SERVER;
let state = null, stateAt = 0, lastId = null, lastSent = 0, pending = 0, noAnswer = false;

/** fetch that gives up after 12 s, so a stalled connection can't leave the page waiting. */
async function fetchT(url, opts = {}, ms = 12000) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), ms);
  const { text, ...init } = opts;
  try {
    const r = await fetch(url, { ...init, signal: ctl.signal });
    return text ? { ok: r.ok, status: r.status, text: await r.text() } : r;
  } catch (e) {
    throw e && e.name === "AbortError" ? new Error("timed out") : e;
  } finally {
    clearTimeout(timer);
  }
}

// ---------- Pairing codes and crypto ----------

/** A full pairing link ("…#k=KEY&s=SERVER"), just "k=…", or the bare key. */
function parsePairing(text) {
  text = (text || "").trim();
  const hash = text.includes("#") ? text.slice(text.indexOf("#") + 1) : text;
  const p = new URLSearchParams(hash);
  const k = p.get("k") || (/^[A-Za-z0-9_-]{43}$/.test(text) ? text : null);
  const s = p.get("s");
  return { k, s: s && /^https:\/\/[^\s]+$/.test(s) ? s.replace(/\/+$/, "") : null };
}

function keyBytes(k) {
  try { const raw = b64u.dec(k); return raw.length === 32 ? raw : null; } catch (_) { return null; }
}

async function topic(label, raw) {
  const d = await crypto.subtle.digest("SHA-256", new Uint8Array([...enc.encode(label), ...raw]));
  return "nocturnal-" + hex(d).slice(0, 24);
}

async function seal(topicName, obj) {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: enc.encode(topicName) }, key, enc.encode(JSON.stringify(obj)));
  return b64u.enc(new Uint8Array([...nonce, ...new Uint8Array(ct)]));
}

async function unseal(topicName, msg) {
  try {
    const raw = b64u.dec(msg);
    const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: raw.slice(0, 12), additionalData: enc.encode(topicName) }, key, raw.slice(12));
    return JSON.parse(dec.decode(pt));
  } catch (_) { return null; }
}

/** ntfy turns messages over 4 KB into attachments; fetch those (still sealed) from the same relay only. */
async function messageText(ev) {
  const a = ev.attachment;
  if (a && a.url && a.size < 65536) {
    try { if (new URL(a.url).origin === new URL(server).origin) return (await fetchT(a.url, { text: true })).text; } catch (_) {}
  }
  return ev.message || "";
}

// ---------- The relay ----------
// Replies arrive on one open connection (server-sent events) instead of polling: ntfy.sh allows a burst of about 60
// requests per address, refilled one every 5 s, so asking every second would soon get a busy phone blocked.

const waiters = new Map();   // request id -> { res, at }
let stream = null, streamReady = null;

/** Reopening with since= the last message seen replays anything missed while in the background. */
function openStream() {
  if (stream && stream.readyState === EventSource.CLOSED) closeStream();
  if (stream) return streamReady;
  const oldest = Math.min(...[...waiters.values()].map(w => w.at));
  const since = lastId || (isFinite(oldest) ? String(Math.floor(oldest / 1000) - 30) : "1m");
  stream = new EventSource(`${server}/${replyTopic}/sse?since=${encodeURIComponent(since)}`);
  streamReady = new Promise(res => { stream.addEventListener("open", res, { once: true }); setTimeout(res, 4000); });
  stream.onmessage = async e => {
    let ev; try { ev = JSON.parse(e.data); } catch (_) { return; }
    if (ev.event !== "message") return;
    lastId = ev.id;
    const m = await unseal(replyTopic, await messageText(ev));
    const w = m && waiters.get(m.re);
    if (w) { waiters.delete(m.re); w.res(m); }
  };
  return streamReady;
}
function closeStream() { if (stream) { stream.close(); stream = null; streamReady = null; } }

/** Without an open connection: ask every 2.5 s for up to 20 s. */
async function waitFor(n, since) {
  const deadline = Date.now() + REPLY_WAIT_MS;
  while (Date.now() < deadline) {
    await sleep(2500);
    let text;
    try { text = (await fetchT(`${server}/${replyTopic}/json?poll=1&since=${encodeURIComponent(since)}`, { text: true })).text; }
    catch (_) { continue; }
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let ev; try { ev = JSON.parse(line); } catch (_) { continue; }
      if (ev.event !== "message") continue;
      lastId = since = ev.id;
      const m = await unseal(replyTopic, await messageText(ev));
      if (m && m.re === n) return m;
    }
  }
  return null;
}

let queue = Promise.resolve();
/** One request at a time, in order. A tap shows "Sending…" at once, "Sent" when the relay has it and "Done" when
 *  the computer answers; background refreshes (bg) change only the freshness line. Resolves to the reply or null. */
function send(cmd, args = {}, { bg = false, force = false } = {}) {
  if (cmd === "panel" && pending && !force) return queue;
  if (!bg) ack("Sending…", "busy");
  pending++;
  queue = queue.then(() => sendNow(cmd, args, bg));
  return queue;
}

async function sendNow(cmd, args, bg) {
  const n = hex(crypto.getRandomValues(new Uint8Array(8)));
  const since = lastId || "30s";
  const replied = new Promise(res => waiters.set(n, { res, at: Date.now() }));
  try {
    if (window.EventSource) await openStream();
    const live = stream && stream.readyState !== EventSource.CLOSED;
    const body = await seal(cmdTopic, { t: Math.floor(Date.now() / 1000), n, cmd, args, dev: DEVICE });
    const r = await fetchT(`${server}/${cmdTopic}`, { method: "POST", body, headers: { Cache: "yes" } });
    if (!r.ok) throw Object.assign(new Error(r.status === 429 ? "Too many requests. Try again in a minute." : "The relay said " + r.status), { say: true });
    if (!bg) ack("Sent", "busy");
    const reply = live ? await Promise.race([replied, sleep(REPLY_WAIT_MS).then(() => null)]) : await waitFor(n, since);
    if (!reply) {
      noAnswer = true;
      if (!bg) ack(cmd === "wake" && state && state.checkIn ? "Sent. It wakes at its next check-in" : "No answer", "bad", 6000);
      render(state, stateAt);
      return null;
    }
    noAnswer = false;
    if (reply.panel) render(reply.panel, Date.now());
    if (reply.settings) renderSettings(reply.settings);
    if (reply.ok === false && reply.error) { note(reply.error); if (!bg) ack("Not done", "bad", 3000); }
    else if (!bg) ack("Done", "done", 2000);
    return reply;
  } catch (e) {
    if (!bg) ack(e.say ? e.message : "Can't reach the relay", "bad", 6000);
    else if (!stateAt) ack("Can't reach the relay", "bad");
    return null;
  } finally {
    waiters.delete(n);
    pending--;
    lastSent = Date.now();
  }
}
const refresh = force => send("panel", {}, { bg: true, force });

// ---------- Freshness line: "Live", "Last seen 4 min ago", or how the last tap is going ----------

let ackText = null, ackKind = "", ackTimer = null;
function ack(text, kind, ms) {
  ackText = text; ackKind = kind;
  clearTimeout(ackTimer);
  if (ms) ackTimer = setTimeout(() => { ackText = null; drawFresh(); }, ms);
  drawFresh();
}
function ago(ms) {
  const m = Math.round(ms / 60000);
  if (m < 60) return `Last seen ${Math.max(1, m)} min ago`;
  if (m < 24 * 60) return `Last seen ${Math.round(m / 60)} h ago`;
  return "Last seen " + when(stateAt);
}
function drawFresh() {
  let text, kind;
  if (ackText) { text = ackText; kind = ackKind; }
  else if (!stateAt) { text = "Connecting…"; kind = "busy"; }
  else if (Date.now() - stateAt < LIVE_MS && !noAnswer) { text = "Live"; kind = "live"; }
  else { text = ago(Date.now() - stateAt); kind = ""; }
  // Written only when it changes, so screen readers don't hear "Live" again every 15 seconds.
  if ($("freshtext").textContent !== text) $("freshtext").textContent = text;
  $("dot").className = "dot " + kind;
  $("fresh").className = "fresh " + kind;
}

const clock = at => new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
const when = at => {
  const d = new Date(at), now = new Date();
  if (d.toDateString() === now.toDateString()) return clock(at);
  if (now - d < 6 * 864e5) return d.toLocaleDateString([], { weekday: "short" }) + " " + clock(at);
  return d.toLocaleDateString([], { day: "numeric", month: "short" }) + " " + clock(at);
};

// ---------- Main screen ----------

/** Numbers count up to their new value. */
function countTo(el, value, digits) {
  const from = Number(el.dataset.v || 0);
  el.dataset.v = String(value);
  const show = v => { el.textContent = v.toFixed(digits); };
  if (reducedMotion.matches || from === value) return show(value);
  const t0 = performance.now(), dur = 700;
  const step = t => {
    const k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3);
    show(from + (value - from) * e);
    if (k < 1 && el.dataset.v === String(value)) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

/** The three numbers: sent as numbers by current versions, read from the sentences older ones sent. */
function numbersOf(p) {
  if (p.numbers && typeof p.numbers.pct === "number") return p.numbers;
  const line = p.batteryLine || p.battery || p.batteryState || "";
  const pct = /(\d{1,3})\s*%/.exec(line);
  if (!pct) return null;
  const hm = /(\d+)\s*h(?:\s*(\d+)\s*min)?/.exec(line), mins = /(\d+)\s*min/.exec(line);
  const h = hm ? +hm[1] + (hm[2] ? +hm[2] / 60 : 0) : mins ? +mins[1] / 60 : null;
  return { pct: +pct[1], w: typeof p.watts === "number" ? p.watts : null, h, plugged: /plugged|charg/.test(line) };
}

/** One line about the agents, most urgent first; otherwise the computer's own reason. */
function agentLine(p) {
  const agents = p.agents || [];
  const by = s => agents.filter(a => a.state === s);
  const waiting = by("waiting"), working = agents.filter(a => a.state === "working" || (!a.state && a.working)), done = by("finished");
  const names = list => list.length === 1 ? list[0].name : list.length + " agents";
  if (waiting.length) return `${names(waiting)} ${waiting.length === 1 ? "is" : "are"} waiting for you`;
  if (working.length) return `${names(working)} ${working.length === 1 ? "is" : "are"} working`;
  if (done.length) return `${names(done)} finished`;
  return p.detail || "";
}

function headline(p) {
  if (noAnswer) return p && p.keeps && !p.lidClosed ? "Not answering" : "Asleep";
  if (!p) return "…";
  return p.keeps ? "Keeps working" : p.lidClosed ? "Going to sleep" : "Sleeps normally";
}

function wakeHint() {
  const every = state && state.checkIn;
  if (wakeSentAt && every) return `Wake sent. It wakes at its next check-in, within ${every} min.`;
  return every ? `It checks for a wake every ${every} min.` : "To wake it from here, turn on check-ins in Nocturnal's settings.";
}

function render(p, at) {
  if (!p) { $("headline").textContent = headline(null); drawFresh(); return; }
  const fresh = at && at > stateAt && Date.now() - at < 60000;
  state = p; if (at) stateAt = at;
  if (fresh) wakeAnswered();
  store.set("nocturnal.last", JSON.stringify({ p, at: stateAt }));

  $("host").textContent = p.host || "Your computer";
  $("forget").textContent = armed.forget ? "Tap again to forget" : `Forget ${p.host || "this computer"}`;
  const keeps = !!p.keeps && !noAnswer;
  $("card").classList.toggle("keeps", keeps);
  const h = headline(p);
  if ($("headline").textContent !== h) { $("headline").textContent = h; $("announce").textContent = h; }
  $("line").textContent = noAnswer ? wakeHint() : agentLine(p);
  const w = $("warnings"); w.textContent = "";
  (p.warnings || []).forEach(t => { const e = document.createElement("p"); e.textContent = t; w.appendChild(e); });

  const n = numbersOf(p);
  $("numbers").hidden = !n;
  if (n) {
    countTo($("pct"), n.pct, 0);
    $("pctcap").textContent = n.charging ? "charging" : n.plugged ? "plugged in" : "battery";
    $("wfig").hidden = typeof n.w !== "number";
    if (typeof n.w === "number") countTo($("watts"), n.w, n.w < 10 ? 1 : 0);
    $("hfig").hidden = typeof n.h !== "number";
    if (typeof n.h === "number") {
      countTo($("hours"), n.h, n.h < 10 ? 1 : 0);
      $("hourscap").textContent = n.plugged ? "if unplugged" : "left, lid shut";
    }
  }

  if (!dragging && !armed.off) showMode(p.mode);
  $("timers").hidden = p.mode !== "on";
  $("approve").textContent = p.autoApprove ? "On" : "Off";
  $("approve").classList.toggle("on", !!p.autoApprove);
  renderSheet(p);
  $("updated").textContent = stateAt ? "Updated " + when(stateAt) : "Not updated yet";
  drawFresh();
}

let toastTimer = null;
function note(msg) {
  const t = $("toast");
  t.textContent = msg; t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 6000);
}

// ---------- Keep-awake slider ----------

const MODES = ["off", "auto", "on"];
let dragging = false, modeIndex = 1, justDragged = false;
const armed = { off: null, sleep: null, forget: null };

function thumbX(i) { return i * ($("slider").clientWidth - 8) / 3; }
function placeThumb(i, animate) {
  const t = $("thumb"), to = thumbX(i);
  const from = Number(t.dataset.x || to);
  t.dataset.x = String(to);
  t.style.setProperty("transform", `translateX(${to}px)`);
  if (animate && !reducedMotion.matches && from !== to && t.animate) {
    // Liquid: stretches toward where it's going, then settles a little past it and back.
    const mid = from + (to - from) * 0.55;
    t.animate([
      { transform: `translateX(${from}px) scale(1, 1)` },
      { transform: `translateX(${mid}px) scale(1.16, .9)`, offset: 0.45 },
      { transform: `translateX(${to + Math.sign(to - from) * 4}px) scale(.97, 1.03)`, offset: 0.8 },
      { transform: `translateX(${to}px) scale(1, 1)` },
    ], { duration: 460, easing: "cubic-bezier(.3,.7,.4,1)" });
  }
}
function showMode(mode, animate = true) {
  const i = Math.max(0, MODES.indexOf(mode));
  document.querySelectorAll("[data-mode]").forEach((b, j) => b.setAttribute("aria-checked", String(j === i)));
  if (i !== modeIndex || !$("thumb").dataset.x) placeThumb(i, animate && !!$("thumb").dataset.x);
  modeIndex = i;
}

/** Off with the lid shut lets it sleep, and a sleeping computer can't hear the phone, so it takes a second tap. */
function chooseMode(mode) {
  const offBtn = document.querySelector('[data-mode="off"]');
  const disarm = () => { clearTimeout(armed.off); armed.off = null; offBtn.textContent = "Off"; $("thumb").classList.remove("confirm"); };
  if (mode === "off" && state && state.lidClosed && !armed.off) {
    showMode("off");
    offBtn.textContent = "Tap again";
    $("thumb").classList.add("confirm");
    armed.off = setTimeout(() => { disarm(); if (state) showMode(state.mode); }, 4000);
    return;
  }
  if (armed.off) disarm();
  showMode(mode);
  $("timers").hidden = mode !== "on";
  send("mode", { mode }).then(r => { if ((!r || r.ok === false) && state) showMode(state.mode); });
}

function sliderSetup() {
  const sl = $("slider"), t = $("thumb");
  let startX = 0, startI = 0, moved = false, id = null;
  sl.addEventListener("pointerdown", e => {
    id = e.pointerId; startX = e.clientX; startI = modeIndex; moved = false;
  });
  sl.addEventListener("pointermove", e => {
    if (e.pointerId !== id) return;
    const dx = e.clientX - startX;
    if (!moved && Math.abs(dx) < 8) return;
    if (!moved) { moved = dragging = true; try { sl.setPointerCapture(id); } catch (_) {} }
    const x = Math.max(0, Math.min(thumbX(2), thumbX(startI) + dx));
    t.style.setProperty("transform", `translateX(${x}px)`);
    t.dataset.x = String(x);
  });
  const end = e => {
    if (e.pointerId !== id) return;
    id = null;
    if (!moved) return;
    dragging = false;
    const i = Math.round(Number(t.dataset.x) / Math.max(1, thumbX(1)));
    placeThumb(i, true); modeIndex = i;
    if (MODES[i] !== (state && state.mode)) chooseMode(MODES[i]); else showMode(MODES[i]);
    justDragged = true;   // the click that ends a drag (dispatched right after this) isn't a tap
    setTimeout(() => { justDragged = false; });
  };
  sl.addEventListener("pointerup", end);
  sl.addEventListener("pointercancel", e => { if (e.pointerId === id && moved) { id = null; dragging = false; if (state) showMode(state.mode); } });
  document.querySelectorAll("[data-mode]").forEach(b => b.addEventListener("click", () => { if (!justDragged) chooseMode(b.dataset.mode); }));
  sl.addEventListener("keydown", e => {
    const d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
    if (!d) return;
    e.preventDefault();
    const i = Math.max(0, Math.min(2, modeIndex + d));
    chooseMode(MODES[i]);
    document.querySelector(`[data-mode="${MODES[i]}"]`).focus();
  });
  addEventListener("resize", () => placeThumb(modeIndex, false));
  document.querySelectorAll("[data-for]").forEach(b => b.addEventListener("click", () => send("mode", { mode: "always", minutes: +b.dataset.for })));
  document.querySelectorAll("[data-until]").forEach(b => b.addEventListener("click", () => send("mode", { mode: "always", until_hour: +b.dataset.until })));
}

// ---------- Capsule: Sleep, Wake, Settings ----------

let wakeSentAt = 0, wakePoll = null;
function wakeAnswered() {
  wakeSentAt = 0;
  if (wakePoll) { clearInterval(wakePoll); wakePoll = null; }
}

function capsuleSetup() {
  const sb = $("sleepbtn");
  sb.addEventListener("click", () => {
    if (!armed.sleep) {
      sb.classList.add("confirm");
      armed.sleep = setTimeout(() => { armed.sleep = null; sb.classList.remove("confirm"); }, 4000);
      return;
    }
    clearTimeout(armed.sleep); armed.sleep = null; sb.classList.remove("confirm");
    send("sleep_now");
  });
  // Wake: a sleeping computer gets it at its next check-in (it waits at the relay); an awake one stays up an hour.
  $("wakebtn").addEventListener("click", async () => {
    wakeSentAt = Date.now();
    const r = await send("wake", { minutes: 60 });
    if (r) return;
    if (!wakePoll) wakePoll = setInterval(() => {
      if (Date.now() - wakeSentAt > 3 * 3600e3) { wakeAnswered(); return; }
      refresh(true);
    }, 60000);
  });
  $("setbtn").addEventListener("click", () => openSheet(1));
}

// ---------- Settings sheet ----------
// Stops: 0 = closed (only the capsule), 1 = 50% of the screen, 2 = 25%. Drag the grabber between them.

let sheetStop = 0;
const STOPS = [0, 0.5, 0.25];
function sheetY(stop) { const h = $("sheet").offsetHeight; return stop === 0 ? h : h - innerHeight * STOPS[stop]; }
function moveSheet(stop, animate = true) {
  const s = $("sheet");
  s.style.setProperty("transition", animate && !reducedMotion.matches ? "transform .42s cubic-bezier(.3,1.15,.5,1)" : "none");
  s.style.setProperty("transform", `translateY(${sheetY(stop)}px)`);
}
function openSheet(stop) {
  sheetStop = stop;
  $("sheet").hidden = false; $("scrim").hidden = false;
  moveSheet(0, false);
  void $("sheet").offsetHeight;
  moveSheet(stop);
  send("schema", {}, { bg: true });
  $("sheetbody").focus({ preventScroll: true });
}
function disarmForget() {
  clearTimeout(armed.forget); armed.forget = null;
  $("forget").classList.remove("confirm");
  $("forget").textContent = `Forget ${(state && state.host) || "this computer"}`;
}
function closeSheet() {
  sheetStop = 0;
  disarmForget();   // a half-done Forget doesn't wait behind a closed sheet
  moveSheet(0);
  $("scrim").hidden = true;
  setTimeout(() => { if (!sheetStop) $("sheet").hidden = true; }, 420);
  $("setbtn").focus();
}
function sheetSetup() {
  const g = $("grab"), s = $("sheet");
  let y0 = 0, base = 0, id = null, t0 = 0;
  g.addEventListener("pointerdown", e => {
    id = e.pointerId; y0 = e.clientY; base = sheetY(sheetStop); t0 = performance.now();
    g.setPointerCapture(id);
    s.style.setProperty("transition", "none");
  });
  g.addEventListener("pointermove", e => {
    if (e.pointerId !== id) return;
    const y = Math.max(0, base + e.clientY - y0);
    s.style.setProperty("transform", `translateY(${y}px)`);
  });
  const end = e => {
    if (e.pointerId !== id) return;
    id = null;
    const dy = e.clientY - y0, v = dy / Math.max(1, performance.now() - t0);
    const y = base + dy;
    // A flick decides; otherwise the nearest stop.
    let stop = [1, 2, 0].reduce((a, b) => Math.abs(sheetY(b) - y) < Math.abs(sheetY(a) - y) ? b : a);
    if (v > 0.6) stop = sheetStop === 1 ? 2 : 0;
    if (v < -0.6) stop = 1;
    if (stop === 0) closeSheet(); else { sheetStop = stop; moveSheet(stop); }
  };
  g.addEventListener("pointerup", end);
  g.addEventListener("pointercancel", end);
  $("scrim").addEventListener("click", closeSheet);
  document.addEventListener("keydown", e => { if (e.key === "Escape" && sheetStop) closeSheet(); });
  addEventListener("resize", () => { if (sheetStop) moveSheet(sheetStop, false); });

  $("refresh").addEventListener("click", () => send("panel", {}, { force: true }));
  $("measure").addEventListener("click", async () => { await send("power_test"); setTimeout(() => refresh(true), 3000); });
  document.querySelectorAll("[data-preset]").forEach(b => b.addEventListener("click", () => {
    document.querySelectorAll("[data-preset]").forEach(x => x.setAttribute("aria-checked", String(x === b)));
    send("preset", { preset: b.dataset.preset }).then(r => { if ((!r || r.ok === false) && state) renderSheet(state); });
  }));
  $("forget").addEventListener("click", () => {
    const b = $("forget");
    if (!armed.forget) {
      b.classList.add("confirm"); b.textContent = "Tap again to forget";
      armed.forget = setTimeout(disarmForget, 4000);
      return;
    }
    clearTimeout(armed.forget);
    closeStream();
    ["nocturnal.k", "nocturnal.s", "nocturnal.last"].forEach(store.del);
    store.set("nocturnal.unpaired", "1");   // the Home Screen icon's saved link mustn't pair it again
    location.replace(location.pathname);
  });
}

const PRESET_DETAIL = { longest: "Pauses chat and background apps. Music and calls keep going.", balanced: "Slows background apps.", speed: "Leaves apps alone." };
const PRESET_IDS = { max_battery: "longest", balanced: "balanced", full_speed: "speed" };
const STATE_WORDS = { waiting: "Waiting for you", working: "Working", finished: "Finished", idle: "Idle" };

function row(left, right, cls) {
  const r = document.createElement("div"); r.className = "row" + (cls ? " " + cls : "");
  r.append(left, right); return r;
}
function label(name, sub, subCls) {
  const l = document.createElement("div"); l.className = "name"; l.textContent = name;
  if (sub) { const s = document.createElement("span"); s.className = "state " + (subCls || ""); s.textContent = sub; l.appendChild(s); }
  return l;
}
function toggle(name, checked, onChange, disabled) {
  const sw = document.createElement("label"); sw.className = "switch";
  const i = document.createElement("input"); i.type = "checkbox"; i.checked = checked; i.disabled = !!disabled;
  i.setAttribute("aria-label", name);
  i.addEventListener("change", () => onChange(i.checked));
  sw.append(i, document.createElement("span")); return sw;
}
function emptyRow(el, text) { const e = document.createElement("div"); e.className = "empty"; e.textContent = text; el.appendChild(e); }

/** The parts of the sheet that come with every status: agents, apps, the lid preset, savings. */
function renderSheet(p) {
  const ag = $("agents"); ag.textContent = "";
  const agents = p.agents || [];
  if (!agents.length) emptyRow(ag, "Agents show up here when they run.");
  agents.forEach(a => {
    const st = a.state || (a.working ? "working" : "idle");
    ag.appendChild(row(label(a.name + (a.instances > 1 ? " ×" + a.instances : ""), STATE_WORDS[st] || "", st),
      toggle(a.name, a.keeps, on => send("track", { agent: a.id, keeps: on }).then(r => { if (!r || r.ok === false) renderSheet(state); }))));
  });
  const wl = $("watch"); wl.textContent = "";
  const watch = p.watch || [];
  if (!watch.length) emptyRow(wl, "Busy apps show up here.");
  watch.forEach(a => wl.appendChild(row(label(a.name), toggle(a.name, a.on, on => send("watch", { app: a.id, remove: !on }).then(r => { if (!r || r.ok === false) renderSheet(state); })))));
  document.querySelectorAll("[data-preset]").forEach(b => b.setAttribute("aria-checked", String(PRESET_IDS[b.dataset.preset] === p.preset)));
  $("presetdetail").textContent = PRESET_DETAIL[p.preset] || "";
  renderSavings(p);
}

const SAVING_NAMES = [["screen_off", "Screen fully off"], ["screen", "Screen off (locks)"], ["low_power", "Low Power Mode"],
  ["apps", "Slowing other apps"], ["simulators", "Pausing simulators"], ["audio", "Pausing background audio"]];
let measurePoll = null;
/** Mac only: what each lid-shut saving is worth, measured on that Mac. */
function renderSavings(p) {
  const s = p.savings || {}, unclear = p.savingsUnclear || [], el = $("savings");
  const has = Object.keys(s).length > 0 || unclear.length > 0;
  $("savingsbox").hidden = !(has || p.powerTest || p.powerTestAborted || p.canMeasure);
  el.textContent = "";
  const line = (name, value) => { const v = document.createElement("span"); v.className = "v"; v.textContent = value; el.appendChild(row(label(name), v)); };
  const watts = x => x >= 0.05 ? "saves " + x.toFixed(1) + " W" : "≈0 W";
  if (p.powerTest) emptyRow(el, p.powerTest + ". Keep the lid shut.");
  else {
    if (p.powerTestAborted) emptyRow(el, "Last time it stopped: " + String(p.powerTestAborted).replace(/\.$/, "") + ".");
    if ("total" in s || unclear.includes("total")) {
      line("All of Nocturnal's savings", unclear.includes("total") ? "unclear" : watts(s.total));
      if (s.closed_without && s.closed_with && !unclear.includes("total")) line("Lid shut, without → with", s.closed_without.toFixed(1) + " → " + s.closed_with.toFixed(1) + " W");
    }
    SAVING_NAMES.filter(([k]) => k in s).forEach(([k, name]) => line(name, watts(s[k])));
    if (!has && !p.powerTestAborted) emptyRow(el, "Shut the lid, then measure.");
  }
  $("measure").hidden = !p.canMeasure;
  $("measure").textContent = (has ? "Measure again" : "Measure now") + " (about 4 min)";
  clearTimeout(measurePoll); measurePoll = null;
  if (p.powerTest) measurePoll = setTimeout(() => refresh(true), 15000);
}

// Every setting the computer reports, in its groups. Values and choices come from the computer (the same table
// its agents use); only the words live here.
const SETTING_GROUPS = [
  ["Screen and power", ["screen", "low_power", "pause_simulators", "shut_down_simulators", "pause_background_audio"], "Dark means no password when you open the lid."],
  ["Sleep and safety", ["sleep_when_done", "quiet_minutes", "battery_floor", "only_on_power", "heat_guard"], "The battery limit, heat guard and plugged-in rule can only be loosened on the computer."],
  ["Keep awake for", ["claude_app", "downloads"], "Agents are found on their own."],
  ["Notifications", ["notify_done", "done_chime"], ""],
];
const SETTING_LABELS = {
  screen: "Screen", low_power: "Low Power Mode", pause_simulators: "Pause simulators and previews",
  shut_down_simulators: "Shut simulators down instead", pause_background_audio: "Pause apps holding the speakers",
  sleep_when_done: "Sleep when the work is done", quiet_minutes: "After nothing happens for", battery_floor: "Sleep at battery level",
  only_on_power: "Only when plugged in", heat_guard: "Heat guard", claude_app: "Claude app (Cowork, computer use)",
  downloads: "Downloads, exports and builds", notify_done: "Notify when an agent finishes", done_chime: "Play a chime too",
};
const CHOICE_LABELS = { max_battery: "Max Battery", balanced: "Balanced", full_speed: "Full Speed" };
let settingsCache = null, settingsDeferred = false;

function picker(name, options, value, onPick) {
  const sel = document.createElement("select"); sel.className = "pick"; sel.setAttribute("aria-label", name);
  options.forEach(([v, text, disabled]) => { const o = document.createElement("option"); o.value = v; o.textContent = text; o.disabled = !!disabled; sel.appendChild(o); });
  sel.value = String(value);
  sel.addEventListener("change", () => onPick(sel.value));
  return sel;
}

/** True when the computer took the change. Re-reads the settings afterwards (andRefresh) so dependent rows update;
 *  always when it wasn't taken, to show the real value again. */
async function setSetting(k, v, andRefresh = true) {
  const r = await send("set", { key: k, value: v });
  const ok = !!r && r.ok !== false;
  if (ok && settingsCache) { const s = settingsCache.find(x => x.key === k); if (s) s.value = s.type === "bool" ? v === "on" : v; }
  if (!ok || andRefresh) { if (settingsCache) renderSettings(settingsCache); send("schema", {}, { bg: true }); }
  return ok;
}

function renderSettings(list) {
  settingsCache = list;
  const root = $("settingslist");
  // Don't pull a menu or text box out from under a finger: redraw once it's let go.
  const f = document.activeElement;
  if (f && root.contains(f) && (f.tagName === "SELECT" || (f.tagName === "INPUT" && f.type === "text"))) {
    if (!settingsDeferred) {
      settingsDeferred = true;
      f.addEventListener("blur", () => { settingsDeferred = false; setTimeout(() => renderSettings(settingsCache)); }, { once: true });
    }
    return;
  }
  const by = Object.fromEntries(list.map(s => [s.key, s]));
  root.textContent = "";
  for (const [title, keys, foot] of SETTING_GROUPS) {
    const rows = [];
    for (const k of keys) {
      if (k === "screen") {
        if (!by.screen_off && !by.lock_on_close) continue;
        const cur = by.lock_on_close && by.lock_on_close.value ? "locks" : by.screen_off && by.screen_off.value ? "off" : "dark";
        const opts = [["dark", "Dark, no lock"]];
        if (by.screen_off) opts.push(["off", "Off, no lock"]);
        if (by.lock_on_close) opts.push(["locks", "Off, locks"]);
        rows.push(row(label("Screen"), picker("Screen", opts, cur, async v => {
          if (by.lock_on_close && !(await setSetting("lock_on_close", v === "locks" ? "on" : "off", !by.screen_off))) return;
          if (by.screen_off) await setSetting("screen_off", v === "off" ? "on" : "off");
        })));
        continue;
      }
      const s = by[k]; if (!s) continue;
      const name = SETTING_LABELS[k] || k.replace(/_/g, " ");
      if (s.type === "bool") {
        const locked = (k === "heat_guard" || k === "only_on_power") && s.value;   // only switched on from here
        rows.push(row(label(name), toggle(name, !!s.value, on => setSetting(k, on ? "on" : "off"), locked)));
      } else if (s.type === "enum") {
        rows.push(row(label(name), picker(name, (s.allowed || []).map(v => [v, CHOICE_LABELS[v] || v]), s.value, v => setSetting(k, v))));
      } else if (s.type === "int") {
        if (k === "quiet_minutes" && by.sleep_when_done && !by.sleep_when_done.value) continue;
        const steps = k === "battery_floor" ? [0, 5, 10, 15, 20, 25, 30, 40, 50] : [1, 2, 5, 10, 20, 30, 60];
        if (!steps.includes(s.value)) { steps.push(s.value); steps.sort((a, b) => a - b); }
        const opts = steps.map(n => [n, k === "battery_floor" ? (n === 0 ? "Never" : n + "%") : n + " min", k === "battery_floor" && n < s.value]);
        rows.push(row(label(name), picker(name, opts, s.value, v => setSetting(k, Number(v)))));
      }
    }
    if (!rows.length) continue;
    const h = document.createElement("h2"); h.textContent = title;
    const g = document.createElement("div"); g.className = "group"; rows.forEach(r => g.appendChild(r));
    root.append(h, g);
    if (foot) { const p = document.createElement("p"); p.className = "foot"; p.textContent = foot; root.appendChild(p); }
  }
}

// ---------- Pairing: QR scanning ----------
// A Home Screen app can't receive the link the Camera app opens (that goes to Safari), so it scans by itself: the
// built-in BarcodeDetector where there is one (Android), jsQR (served from this site) elsewhere.

let camStream = null, scanTimer = null;
function loadScript(src) {
  return new Promise((res, rej) => { const e = document.createElement("script"); e.src = src; e.onload = res; e.onerror = () => rej(new Error(src)); document.head.appendChild(e); });
}
async function startScan() {
  const err = t => { $("pairerr").textContent = t; };
  err("");
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) return err("This browser can't use the camera here. Paste the code instead.");
  let detector = null;
  try { if ("BarcodeDetector" in window && (await BarcodeDetector.getSupportedFormats()).includes("qr_code")) detector = new BarcodeDetector({ formats: ["qr_code"] }); } catch (_) {}
  try { if (!detector && !window.jsQR) await loadScript("jsQR.js"); }
  catch (_) { return err("The scanner didn't load. Check your connection, or paste the code."); }
  try { camStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false }); }
  catch (e) { return err(e && e.name === "NotAllowedError" ? "Camera access is off for this page. Allow it, or paste the code." : "Couldn't open the camera. Paste the code instead."); }
  const v = $("cam");
  v.srcObject = camStream;
  $("scanner").hidden = false; $("scanbtn").hidden = true;
  try { await v.play(); } catch (_) {}
  const c = document.createElement("canvas"), g = c.getContext("2d", { willReadFrequently: true });
  let warned = false;
  const tick = async () => {
    if (!camStream) return;
    let text = null;
    if (v.readyState >= 2 && v.videoWidth) {
      try {
        if (detector) { const r = await detector.detect(v); if (r.length) text = r[0].rawValue; }
        else {
          const sc = Math.min(1, 720 / Math.max(v.videoWidth, v.videoHeight));
          c.width = Math.round(v.videoWidth * sc); c.height = Math.round(v.videoHeight * sc);
          g.drawImage(v, 0, 0, c.width, c.height);
          const r = jsQR(g.getImageData(0, 0, c.width, c.height).data, c.width, c.height, { inversionAttempts: "dontInvert" });
          if (r) text = r.data;
        }
      } catch (_) {}
    }
    if (text) {
      const { k, s } = parsePairing(text);
      if (k && keyBytes(k)) { stopScan(); save(k, s); await begin(k, s); return; }
      if (!warned) { warned = true; err("That QR code isn't from Nocturnal."); }
    }
    scanTimer = setTimeout(tick, 120);
  };
  tick();
}
function stopScan() {
  clearTimeout(scanTimer); scanTimer = null;
  if (camStream) { camStream.getTracks().forEach(t => t.stop()); camStream = null; }
  $("cam").srcObject = null;
  $("scanner").hidden = true; $("scanbtn").hidden = false;
}

// ---------- Add to Home Screen ----------
// It runs full screen from the Home Screen, like an app. In a phone's browser tab it asks for that first, once per
// visit; "Continue in the browser" skips it. The iPhone app is the other way to get the same screen.

let inBrowser = false;
try { inBrowser = sessionStorage.getItem("nocturnal.inBrowser") === "1"; } catch (_) {}
const needsInstall = () => phone && !standalone && !inBrowser;
function showInstall() {
  const share = '<svg width="15" height="18" viewBox="0 0 15 18" aria-hidden="true"><path d="M7.5 1v10M4 4.5 7.5 1 11 4.5M3 7.5H1.5v9h12v-9H12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const steps = ios
    ? [`Tap ${share} <b>Share</b>`, "Tap <b>Add to Home Screen</b>", "Keep <b>Open as Web App</b> on, then <b>Add</b>"]
    : ["Open the browser menu <b>⋮</b>", "Tap <b>Add to Home screen</b> or <b>Install app</b>", "Confirm with <b>Add</b>"];
  $("steps").innerHTML = steps.map((t, i) => `<li><span class="n">${i + 1}</span><span>${t}</span></li>`).join("");
  $("installhint").textContent = key ? "Then open Nocturnal from your Home Screen. It stays paired." : "Then open Nocturnal from your Home Screen and pair it there.";
  $("pair").hidden = true; $("app").hidden = true; $("install").hidden = false;
}

// ---------- Start ----------

async function begin(k, s) {
  const raw = keyBytes(k);
  if (!raw) return false;
  server = s || DEFAULT_SERVER;
  key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
  cmdTopic = await topic("nocturnal/cmd/v1", raw);
  replyTopic = await topic("nocturnal/reply/v1", raw);
  $("pair").hidden = true; $("app").hidden = false;
  // The last status this phone saw, with when it came, until the computer answers.
  try { const last = JSON.parse(store.get("nocturnal.last") || "null"); if (last && last.p) render(last.p, last.at || 0); } catch (_) {}
  if (!state) showMode("auto", false);
  if (needsInstall()) showInstall();
  refresh(true);
  return true;
}

function save(k, s) {
  if (store.get("nocturnal.k") !== k) store.del("nocturnal.last");   // another computer: don't show the old one
  store.set("nocturnal.k", k);
  store.del("nocturnal.unpaired");
  if (s) store.set("nocturnal.s", s); else store.del("nocturnal.s");
  // In a browser tab the key stays in the address too: Add to Home Screen saves this address in the icon, so the
  // app pairs itself on launch even though Home Screen apps don't share Safari's storage.
  if (!standalone) { try { history.replaceState(null, "", "#k=" + k + (s ? "&s=" + encodeURIComponent(s) : "")); } catch (_) {} }
}

async function start() {
  if (!window.crypto || !crypto.subtle) {
    $("pair").hidden = false;
    $("pairerr").textContent = "This browser can't do the encryption Nocturnal needs. Open the page in Safari or Chrome.";
    return;
  }
  sliderSetup(); capsuleSetup(); sheetSetup();
  setInterval(() => { if (key && !document.hidden && !pending && Date.now() - lastSent > REFRESH_MS) refresh(); }, 5000);
  setInterval(() => { if (key && !document.hidden) drawFresh(); }, 15000);
  $("inbrowser").addEventListener("click", () => {
    inBrowser = true; try { sessionStorage.setItem("nocturnal.inBrowser", "1"); } catch (_) {}
    $("install").hidden = true;
    if (key) { $("app").hidden = false; placeThumb(modeIndex, false); } else $("pair").hidden = false;
  });
  // In the background the open connection is closed (iPhone drops it anyway). Back on screen: reopen it, which
  // replays answers that came in meanwhile, and refresh.
  const back = () => { if (!key) return; if (waiters.size && window.EventSource) openStream(); refresh(true); };
  document.addEventListener("visibilitychange", () => { if (document.hidden) { closeStream(); stopScan(); } else back(); });
  addEventListener("pageshow", e => { if (e.persisted) back(); });
  $("scanbtn").addEventListener("click", startScan);
  $("scanstop").addEventListener("click", stopScan);
  $("pairform").addEventListener("submit", async e => {
    e.preventDefault();
    const { k, s } = parsePairing($("code").value);
    if (!k || !keyBytes(k)) { $("pairerr").textContent = "That doesn't look like a Nocturnal pairing code."; return; }
    save(k, s);
    $("pairerr").textContent = "";
    await begin(k, s);
  });

  // 1. A link with the key in it (the QR code). In a Home Screen app it's removed from the address once saved,
  //    but the icon keeps the address it was added with, so every launch brings it back: once applied, it must not
  //    undo a newer pairing, or a "Forget" done in the app since.
  const fromLink = parsePairing(location.hash.slice(1));
  if (fromLink.k && keyBytes(fromLink.k)) {
    const stored = store.get("nocturnal.k");
    const stale = standalone && fromLink.k === store.get("nocturnal.linkApplied") &&
      (store.get("nocturnal.unpaired") === "1" || (!!stored && stored !== fromLink.k));
    if (standalone) { try { history.replaceState(null, "", location.pathname); } catch (_) {} }
    if (!stale) {
      save(fromLink.k, fromLink.s);
      store.set("nocturnal.linkApplied", fromLink.k);
      return begin(fromLink.k, fromLink.s);
    }
  }
  // 2. Paired before on this phone.
  const k = store.get("nocturnal.k");
  if (k && await begin(k, parsePairing("s=" + (store.get("nocturnal.s") || "")).s)) return;
  // 3. Not paired yet.
  if (needsInstall()) showInstall(); else $("pair").hidden = false;
}
start();

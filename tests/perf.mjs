#!/usr/bin/env node
// Ray's performance harness: hidden test instances (RAY_BACKGROUND, own throwaway data dirs), driven by test commands
// and DevTools, measured with proc_pid_rusage (tests/perf-rusage.py) and `ps -M` (the main thread).
//   scripts/locked perflab --wait 3000 -- node tests/perf.mjs --app <RayTests.app> --label <name> [--runs 3]
//     [--only launch,idle,tabswitch,commandbar,sidebar,drag,resize,iframes,memory] [--out <file.json>]
// Run it under the perflab lock: two measurements at once on one Mac skew each other. Medians over --runs; each
// scenario starts its own instances. Timing instances run without RAY_LOG_STATE (the state log is test-only work that
// grew with every feature); only the frame counts (tab switch, resize) come from a logged instance of their own.
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, cpSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : fallback; };
const app = resolve(opt("app", join(root, "build/RayTests.app")));
const label = opt("label", "build");
const runs = Number(opt("runs", "3"));
const only = opt("only", "launch,idle,tabswitch,commandbar,sidebar,drag,resize,iframes,memory").split(",");
const out = opt("out", null);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const median = (xs) => { const s = xs.filter((x) => x != null && !Number.isNaN(x)).sort((a, b) => a - b); return s.length ? s[(s.length - 1) >> 1] * 0.5 + s[s.length >> 1] * 0.5 : null; };
const pct = (xs, p) => { const s = xs.filter((x) => x != null).sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : null; };
const round = (x, d = 1) => (x == null ? null : Math.round(x * 10 ** d) / 10 ** d);
const log = (...a) => console.error(`[perf ${label}]`, ...a);

// MARK: Fixture server

const longPage = (i) => `<title>Long ${i}</title><style>body{margin:0;font:16px/1.6 sans-serif}p{margin:0 16px 12px}</style>` +
  Array.from({ length: 150 }, (_, k) => `<p>Paragraph ${k} of page ${i}: the quick brown fox jumps over the lazy dog.</p>`).join("");
let crossOrigin = "";
function serve(req, res) {
  const url = new URL(req.url, "http://x");
  const html = (body) => { res.writeHead(200, { "content-type": "text/html" }); res.end(body); };
  if (url.pathname === "/a") return html("<title>A</title><p>a</p>");
  if (url.pathname === "/long") return html(longPage(url.searchParams.get("i") ?? 0));
  if (url.pathname === "/leaf") return html(`<title>leaf</title><p style="margin:2px">frame ${url.searchParams.get("i")}</p>`);
  if (url.pathname === "/frames") {
    // Same-site frames, then cross-site ones (localhost vs 127.0.0.1: other renderer processes), then nested ones.
    const n = Number(url.searchParams.get("n") ?? 40), cross = Number(url.searchParams.get("cross") ?? 10);
    const frames = Array.from({ length: n }, (_, i) => `<iframe width=160 height=60 src="/leaf?i=${i}"></iframe>`).join("") +
      Array.from({ length: cross }, (_, i) => `<iframe width=160 height=60 src="${crossOrigin}/leaf?x=${i}"></iframe>`).join("") +
      `<iframe width=300 height=200 src="/frames?n=5&cross=0&nested=1"></iframe>`.repeat(url.searchParams.has("nested") ? 0 : 4);
    return html(`<title>Frames</title>${frames}`);
  }
  if (url.pathname === "/suggest") {
    res.writeHead(200, { "content-type": "application/json" });
    const q = url.searchParams.get("q") ?? "";
    return res.end(JSON.stringify([q, [`${q} one`, `${q} two`, `${q} three`]]));
  }
  if (url.pathname === "/search") return html("<title>Search</title><p>results</p>");
  res.writeHead(404); res.end("no");
}
const server = createServer(serve);
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
crossOrigin = origin.replace("127.0.0.1", "localhost");

// MARK: Instances

const work = mkdtempSync(join(tmpdir(), "ray-perf-"));
let portBase = 11000 + Math.floor(Math.random() * 500);
const live = new Set();

function parseTime(t) { // ps's [[h:]m]m:ss.cc
  const parts = t.split(":").map(Number);
  return parts.reduce((acc, v) => acc * 60 + v, 0);
}

function start({ logged = false, env = {}, seed = null, url = `${origin}/a`, dir = null } = {}) {
  const data = dir ?? mkdtempSync(join(work, "data-"));
  if (seed && !dir) cpSync(seed, data, { recursive: true });
  const port = portBase++;
  const it = { dir: data, port, log: "", states: [], t0: performance.now() };
  let partial = "";
  it.proc = spawn(join(app, "Contents/MacOS/Ray"), [], {
    env: {
      ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", ...(logged ? { RAY_LOG_STATE: "1" } : {}),
      RAY_DATA_DIR: data, RAY_DOWNLOADS_DIR: join(data, "Downloads"), RAY_PASTEBOARD: `dev.shanus.ray.perf.${process.pid}`,
      RAY_REMOTE_DEBUGGING_PORT: String(port), RAY_START_URL: url, RAY_SUGGEST_URL: `${origin}/suggest?q=%s&engine=%e`,
      RAY_SEARCH_URL: `${origin}/search?q=%s`, ...env,
    },
    stdio: ["pipe", "ignore", "pipe"],
  });
  live.add(it);
  it.proc.stdin.on("error", () => {});
  it.proc.stderr.setEncoding("utf8");
  it.waiters = [];
  it.proc.stderr.on("data", (chunk) => {
    const lines = (partial + chunk).split("\n");
    partial = lines.pop();
    for (const line of lines) {
      const at = line.indexOf("[ray-state] ");
      if (at >= 0) { try { it.states.push(JSON.parse(line.slice(at + 12))); } catch {} continue; }
      const ack = line.indexOf("[ray-test] ");
      if (ack >= 0) {
        const now = performance.now();
        const text = line.slice(ack + 11);
        const w = it.waiters.findIndex((w) => text.startsWith(w.marker));
        if (w >= 0) { const [waiter] = it.waiters.splice(w, 1); waiter.resolve({ result: text.slice(waiter.marker.length), at: now }); }
      }
    }
  });
  it.exit = new Promise((r) => it.proc.on("exit", (c, s) => { live.delete(it); r(c ?? s); }));
  it.cmd = (line, ms = 20000) => new Promise((resolve, reject) => {
    const sent = performance.now();
    const waiter = { marker: `${line} -> `, resolve: ({ result, at }) => { clearTimeout(timer); resolve({ result, ms: at - sent }); } };
    const timer = setTimeout(() => { it.waiters.splice(it.waiters.indexOf(waiter), 1); reject(new Error(`timed out: ${line}`)); }, ms);
    it.waiters.push(waiter);
    it.proc.stdin.write(line + "\n");
  });
  it.ok = async (line, ms) => { const r = await it.cmd(line, ms); if (r.result !== "ok") throw new Error(`${line}: ${r.result}`); return r.ms; };
  // The main thread's backlog: an unknown command answers at once once the main queue reaches it.
  it.ping = async () => (await it.cmd("perfping")).ms;
  it.state = async () => { await it.ok("state"); return it.states.at(-1); };
  it.pids = () => {
    const rows = execFileSync("ps", ["-A", "-o", "pid=,ppid=,command="], { encoding: "utf8" }).split("\n");
    const kids = { host: [it.proc.pid], gpu: [], renderer: [], other: [] };
    for (const row of rows) {
      const m = row.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
      if (!m || Number(m[2]) !== it.proc.pid) continue;
      const kind = m[3].includes("--type=gpu-process") ? "gpu" : m[3].includes("--type=renderer") ? "renderer" : "other";
      kids[kind].push(Number(m[1]));
    }
    return kids;
  };
  // CPU (s), idle wakeups and footprint (MB), per process kind and in total, plus the host's main thread CPU (s).
  it.usage = () => {
    const kids = it.pids();
    const all = Object.values(kids).flat();
    const r = JSON.parse(execFileSync("python3", ["-I", join(here, "perf-rusage.py"), ...all.map(String)], { encoding: "utf8" }));
    const sum = (pids, key) => pids.reduce((a, p) => a + (r[p]?.[key] ?? 0), 0);
    const by = {};
    for (const [k, pids] of Object.entries(kids)) by[k] = { cpu: sum(pids, "cpu") / 1e9, idle: sum(pids, "idle"), intr: sum(pids, "intr"), mb: sum(pids, "footprint") / 2 ** 20, n: pids.length };
    by.total = { cpu: sum(all, "cpu") / 1e9, idle: sum(all, "idle"), intr: sum(all, "intr"), mb: sum(all, "footprint") / 2 ** 20, n: all.length };
    const ps = execFileSync("ps", ["-M", "-p", String(it.proc.pid)], { encoding: "utf8" }).split("\n")[1].trim().split(/\s+/);
    by.main = { cpu: parseTime(ps[6]) + parseTime(ps[7]) };
    by.at = performance.now();
    return by;
  };
  it.stop = async () => {
    it.proc.stdin.write("menu quit\n");
    const code = await Promise.race([it.exit, sleep(15000).then(() => "timeout")]);
    if (code === "timeout") { it.proc.kill("SIGKILL"); await it.exit; }
    if (!dir) rmSync(data, { recursive: true, force: true });
  };
  return it;
}
process.on("exit", () => { for (const it of live) try { it.proc.kill("SIGKILL"); } catch {} rmSync(work, { recursive: true, force: true }); });
process.on("SIGINT", () => process.exit(130));
process.on("SIGTERM", () => process.exit(143));

/** Deltas between two `usage()` samples: CPU seconds, wakeups per second, over `secs`. */
function delta(a, b) {
  const secs = (b.at - a.at) / 1000;
  const d = { secs };
  for (const k of ["host", "gpu", "renderer", "other", "total"]) d[k] = { cpu: b[k].cpu - a[k].cpu, idlePerSec: (b[k].idle - a[k].idle) / secs, intrPerSec: (b[k].intr - a[k].intr) / secs };
  d.main = { cpu: b.main.cpu - a.main.cpu };
  return d;
}

// DevTools over HTTP + one WebSocket per instance.
async function devtools(it) {
  const until = Date.now() + 30000;
  let version;
  while (!version) {
    try { version = await (await fetch(`http://127.0.0.1:${it.port}/json/version`)).json(); } catch { if (Date.now() > until) throw new Error("no DevTools"); await sleep(50); }
  }
  const ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = j)));
  let next = 1;
  const pending = new Map();
  ws.onmessage = (m) => { const msg = JSON.parse(m.data); if (msg.id && pending.has(msg.id)) { const p = pending.get(msg.id); pending.delete(msg.id); msg.error ? p.j(new Error(msg.error.message)) : p.r(msg.result); } };
  const send = (method, params = {}, sessionId) => new Promise((r, j) => { const id = next++; pending.set(id, { r, j }); ws.send(JSON.stringify({ id, method, params, sessionId })); });
  const dt = { ws, send };
  dt.pages = async () => (await send("Target.getTargets")).targetInfos.filter((t) => t.type === "page");
  dt.attach = async (match) => {
    let target;
    const end = Date.now() + 15000;
    while (!(target = (await dt.pages()).find(match))) { if (Date.now() > end) throw new Error("no such page"); await sleep(100); }
    return (await send("Target.attachToTarget", { targetId: target.targetId, flatten: true })).sessionId;
  };
  dt.eval = async (sid, expression) => (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, sid)).result?.value;
  dt.open = async (url) => send("Target.createTarget", { url });
  dt.close = () => ws.close();
  return dt;
}
async function waitFor(what, fn, ms = 15000, every = 50) {
  const end = Date.now() + ms;
  for (;;) { const v = await fn(); if (v) return v; if (Date.now() > end) throw new Error(`timed out waiting for ${what}`); await sleep(every); }
}
async function pageLoaded(it, title = "A") {
  return waitFor(`page ${title}`, async () => {
    try { return (await (await fetch(`http://127.0.0.1:${it.port}/json/list`)).json()).some((t) => t.type === "page" && t.title === title); } catch { return false; }
  }, 30000, 20);
}
async function openTabs(it, dt, n, path = "/long") {
  const before = (await dt.pages()).length;
  for (let i = 0; i < n; i++) await dt.open(`${origin}${path}?i=${i}`);
  await waitFor(`${n} tabs`, async () => (await dt.pages()).filter((p) => p.title.startsWith("Long")).length >= n, 30000, 200);
  return before + n;
}

// MARK: Scenarios

const scenarios = {};

scenarios.launch = async () => {
  // Cold: a new data dir. Warm: the same dir again (its sidebar and profile on disk). Time to the start page's title.
  const result = {};
  const dir = mkdtempSync(join(work, "launch-"));
  for (const kind of ["cold", "warm"]) {
    const it = start({ dir });
    await pageLoaded(it);
    result[`${kind}Ms`] = performance.now() - it.t0;
    await sleep(3000);
    const u = it.usage();
    result[`${kind}HostMB`] = u.host.mb;
    result[`${kind}TotalMB`] = u.total.mb;
    result[`${kind}HostCpuS`] = u.host.cpu;
    await it.stop();
  }
  rmSync(dir, { recursive: true, force: true });
  return result;
};

scenarios.idle = async () => {
  const it = start();
  await pageLoaded(it);
  await it.ok("onscreen on");
  const dt = await devtools(it);
  const r = {};
  for (const [name, tabs] of [["1tab", 1], ["15tabs", 15]]) {
    if (tabs > 1) await openTabs(it, dt, tabs - 1);
    await sleep(8000);
    const a = it.usage();
    await sleep(20000);
    const b = it.usage();
    const d = delta(a, b);
    r[`${name}HostCpuPct`] = (d.host.cpu / d.secs) * 100;
    r[`${name}MainCpuPct`] = (d.main.cpu / d.secs) * 100;
    r[`${name}GpuCpuPct`] = (d.gpu.cpu / d.secs) * 100;
    r[`${name}TotalCpuPct`] = (d.total.cpu / d.secs) * 100;
    r[`${name}HostWakeups`] = d.host.idlePerSec + d.host.intrPerSec;
    r[`${name}TotalWakeups`] = d.total.idlePerSec + d.total.intrPerSec;
    r[`${name}HostMB`] = b.host.mb;
    r[`${name}TotalMB`] = b.total.mb;
  }
  dt.close();
  await it.stop();
  return r;
};

// PERF_SAMPLE=<dir>: `sample` the host for the length of a measured loop (a profile, not a measurement: run it alone).
function profiling(it, name, secs) {
  const dir = process.env.PERF_SAMPLE;
  if (!dir) return;
  mkdirSync(dir, { recursive: true });
  spawn("sample", [String(it.proc.pid), String(Math.ceil(secs)), "-mayDie", "-file", join(dir, `${name}.txt`)], { stdio: "ignore" });
}
async function switchRun(it, count, gap) {
  const acks = [], pings = [];
  if (count >= 32) profiling(it, "tabswitch", (count * (gap + 25)) / 1000);
  const a = it.usage();
  for (let i = 0; i < count; i++) {
    acks.push(await it.ok("menu nextTab"));
    pings.push(await it.ping());
    await sleep(gap);
  }
  const b = it.usage();
  return { acks, pings, d: delta(a, b) };
}
scenarios.tabswitch = async () => {
  const r = {};
  {
    const it = start();
    await pageLoaded(it);
    await it.ok("onscreen on");
    const dt = await devtools(it);
    await openTabs(it, dt, 7);
    await sleep(4000);
    await switchRun(it, 8, 300); // every tab shown once (a first show makes the page's compositor)
    await sleep(1500);
    const { acks, pings, d } = await switchRun(it, 32, 350);
    r.ackMs = median(acks);
    r.ackP95Ms = pct(acks, 0.95);
    r.pingAfterMs = median(pings);
    r.mainCpuMsPerSwitch = (d.main.cpu / 32) * 1000;
    r.hostCpuMsPerSwitch = (d.host.cpu / 32) * 1000;
    r.gpuCpuMsPerSwitch = (d.gpu.cpu / 32) * 1000;
    r.totalCpuMsPerSwitch = (d.total.cpu / 32) * 1000;
    dt.close();
    await it.stop();
  }
  {
    // Frames (logged instance): display frames until the new page shows, and blank frames.
    const it = start({ logged: true });
    await pageLoaded(it);
    await it.ok("onscreen on");
    const dt = await devtools(it);
    await openTabs(it, dt, 7);
    await sleep(4000);
    await switchRun(it, 8, 300);
    await sleep(1000);
    await switchRun(it, 20, 400);
    await sleep(800);
    const s = await it.state();
    const sw = (s.pages?.switches ?? []).slice(-20);
    r.framesToNew = median(sw.map((x) => x.frames.indexOf("n") < 0 ? x.frames.length : x.frames.indexOf("n")));
    r.blankFrames = sw.reduce((a, x) => a + x.blankFrames, 0);
    r.switchesSeen = sw.length;
    dt.close();
    await it.stop();
  }
  return r;
};

// A fake Chrome profile with a big history (Importer's reader: the urls table), imported once per build.
let historySeed = null;
const historyQueries = ["site12", "topic45", "examplecom", "readme"];
async function makeHistorySeed() {
  if (historySeed) return historySeed;
  const support = join(work, "support");
  const chrome = join(support, "Google/Chrome");
  mkdirSync(join(chrome, "Default"), { recursive: true });
  const fixture = join(root, "Importer/fixtures/home/Library/Application Support/Google/Chrome");
  copyFileSync(join(fixture, "Local State"), join(chrome, "Local State"));
  copyFileSync(join(fixture, "Default/Preferences"), join(chrome, "Default/Preferences"));
  const N = 20000;
  const now = (Date.now() * 1000) + 11_644_473_600_000_000;
  const rows = [];
  for (let i = 0; i < N; i++) {
    const t = now - Math.floor((i / N) * 30 * 86400 * 1e6);
    rows.push(`('https://site${i % 700}.example.com/docs/topic${i % 97}/page-${i}/readme','Topic ${i % 97} page ${i} on site${i % 700}',${1 + (i % 9)},${i % 3},${t},0)`);
  }
  const sql = `CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT,url LONGVARCHAR,title LONGVARCHAR,visit_count INTEGER DEFAULT 0 NOT NULL,typed_count INTEGER DEFAULT 0 NOT NULL,last_visit_time INTEGER NOT NULL,hidden INTEGER DEFAULT 0 NOT NULL);
BEGIN;` + rows.map((v) => `INSERT INTO urls(url,title,visit_count,typed_count,last_visit_time,hidden) VALUES ${v};`).join("\n") + "\nCOMMIT;";
  execFileSync("sqlite3", [join(chrome, "Default/History")], { input: sql });
  const seed = mkdtempSync(join(work, "seed-"));
  const it = start({ dir: seed, env: { RAY_IMPORT_SOURCE_DIR: support } });
  await pageLoaded(it);
  await it.ok("import chrome Default history");
  const last = "https://site0.example.com/docs/topic0/page-0/readme";
  await waitFor("history import", async () => {
    const r = await it.cmd(`importcheck history ${last}`, 60000);
    try { const j = JSON.parse(r.result); return j.has && j.count >= N * 0.9 ? j : null; } catch { return null; }
  }, 240000, 2000);
  await sleep(1000);
  await it.stop();
  historySeed = seed;
  return seed;
}
scenarios.commandbar = async () => {
  const seed = await makeHistorySeed();
  const it = start({ seed });
  await pageLoaded(it);
  const r = { openMs: [], keyMs: [], keyAckMs: [], deleteMs: [] };
  await sleep(3000);
  const a = it.usage();
  let keys = 0;
  for (let round = 0; round < 3; round++) {
    const open = await it.ok("menu newTab");
    r.openMs.push(open + (await it.ping()));
    await sleep(600);
    for (const q of historyQueries) {
      for (const ch of q) {
        const ack = await it.ok(`type ${ch}`);
        const ping = await it.ping();
        r.keyAckMs.push(ack);
        r.keyMs.push(ack + ping);
        keys++;
        await sleep(60);
      }
      for (let i = 0; i < q.length; i++) { r.deleteMs.push((await it.ok("backspace")) + (await it.ping())); await sleep(30); }
    }
    await it.ok("escape");
    await it.cmd("escape");
    await sleep(500);
  }
  const b = it.usage();
  const d = delta(a, b);
  await it.stop();
  return {
    openMs: median(r.openMs), keyMs: median(r.keyMs), keyP95Ms: pct(r.keyMs, 0.95), keyMaxMs: Math.max(...r.keyMs),
    keyAckMs: median(r.keyAckMs), deleteMs: median(r.deleteMs),
    mainCpuMsPerKey: (d.main.cpu / keys) * 1000, hostCpuMsPerKey: (d.host.cpu / keys) * 1000,
  };
};

let profilingCount = 0;
async function toggles(it, n) {
  if (n >= 10) profiling(it, `toggle-${profilingCount++}`, (n * 725) / 1000);
  const a = it.usage();
  const acks = [];
  for (let i = 0; i < n; i++) { acks.push(await it.ok("menu toggleSidebar")); await sleep(700); }
  const b = it.usage();
  return { acks, d: delta(a, b) };
}
scenarios.sidebar = async () => {
  const it = start();
  await pageLoaded(it);
  await it.ok("onscreen on");
  const dt = await devtools(it);
  const r = {};
  for (const [name, tabs] of [["1tab", 1], ["15tabs", 15]]) {
    if (tabs > 1) { await openTabs(it, dt, tabs - 1); await sleep(4000); }
    await toggles(it, 2);
    const { acks, d } = await toggles(it, 10);
    r[`${name}AckMs`] = median(acks);
    r[`${name}MainCpuMsPerToggle`] = (d.main.cpu / 10) * 1000;
    r[`${name}HostCpuMsPerToggle`] = (d.host.cpu / 10) * 1000;
    r[`${name}GpuCpuMsPerToggle`] = (d.gpu.cpu / 10) * 1000;
    r[`${name}TotalCpuMsPerToggle`] = (d.total.cpu / 10) * 1000;
  }
  dt.close();
  await it.stop();
  return r;
};

// Today rows' frames, from a logged instance with 15 tabs (the same for every run of a build).
let rowFrames = null;
async function todayRowFrames() {
  if (rowFrames) return rowFrames;
  const it = start({ logged: true });
  await pageLoaded(it);
  const dt = await devtools(it);
  await openTabs(it, dt, 14);
  await sleep(2000);
  const s = await it.state();
  rowFrames = s.sidebar.today.map((e) => s.sidebarFrames[e.id]).filter(Boolean).map((f) => { const [x, y, w, h] = f.split(",").map(Number); return { cx: x + w / 2, cy: y + h / 2, h }; });
  dt.close();
  await it.stop();
  return rowFrames;
}
scenarios.drag = async () => {
  const frames = await todayRowFrames();
  const it = start();
  await pageLoaded(it);
  await it.ok("onscreen on");
  const dt = await devtools(it);
  await openTabs(it, dt, 14);
  await sleep(4000);
  const moves = [];
  const a = it.usage();
  for (let round = 0; round < 4; round++) {
    const from = frames[2], to = frames[Math.min(frames.length - 2, 10)];
    await it.ok(`press ${from.cx} ${from.cy}`);
    for (let s = 1; s <= 40; s++) {
      const t = round % 2 ? 1 - s / 40 : s / 40;
      moves.push(await it.ok(`move ${from.cx + 2} ${from.cy + (to.cy - from.cy) * t}`));
      await sleep(16);
    }
    await it.ok(`release ${from.cx + 2} ${round % 2 ? from.cy : to.cy}`);
    await sleep(800);
  }
  const b = it.usage();
  const d = delta(a, b);
  dt.close();
  await it.stop();
  return { moveAckMs: median(moves), moveP95Ms: pct(moves, 0.95), mainCpuMsPerMove: (d.main.cpu / moves.length) * 1000,
    hostCpuMsPerMove: (d.host.cpu / moves.length) * 1000, totalCpuMsPerMove: (d.total.cpu / moves.length) * 1000 };
};

scenarios.resize = async () => {
  // Sidebar width (0.9.4+): a sweep of a step per display frame, timed inside Ray (logged instance).
  const it = start({ logged: true });
  await pageLoaded(it);
  await it.ok("onscreen on");
  const probe = await it.cmd("sidebarwidth 267");
  if (probe.result !== "ok") { await it.stop(); return { supported: false }; }
  const dt = await devtools(it);
  await openTabs(it, dt, 14);
  await sleep(3000);
  const sweeps = [];
  const a = it.usage();
  for (let i = 0; i < 6; i++) {
    await it.ok(`sidebarwidth sweep ${i % 2 ? -150 : 150} 40`);
    const s = await waitFor("sweep", async () => { const s = await it.state(); return s.sidebarResize?.sweep ? s : null; }, 10000, 250);
    sweeps.push(s.sidebarResize.sweep);
    await sleep(400);
  }
  const b = it.usage();
  const d = delta(a, b);
  dt.close();
  await it.stop();
  return { supported: true, layoutMsMax: median(sweeps.map((x) => x.layoutMsMax)), layoutMsMean: median(sweeps.map((x) => x.layoutMsMean)), frameMsMax: median(sweeps.map((x) => x.frameMsMax)), longFrames: median(sweeps.map((x) => x.longFrames)), mainCpuMsPerSweep: (d.main.cpu / 6) * 1000, totalCpuMsPerSweep: (d.total.cpu / 6) * 1000 };
};

scenarios.iframes = async () => {
  const it = start();
  await pageLoaded(it);
  await it.ok("onscreen on");
  const dt = await devtools(it);
  const sid = await dt.attach((p) => p.title === "A");
  const loads = [];
  const a = it.usage();
  for (let i = 0; i < 6; i++) {
    await dt.send("Page.navigate", { url: `${origin}/frames?n=40&cross=10&r=${i}` }, sid);
    const ms = await waitFor("frames load", async () => {
      try { return await dt.eval(sid, `(() => { const n = performance.getEntriesByType("navigation")[0]; return location.search.includes("r=${i}") && n && n.loadEventEnd > 0 ? n.loadEventEnd - n.startTime : 0; })()`); } catch { return 0; }
    }, 30000, 50);
    if (i > 0) loads.push(ms); // the first warms caches
    await sleep(1500);
  }
  const b = it.usage();
  const d = delta(a, b);
  await sleep(4000);
  const c = it.usage();
  await sleep(15000);
  const e = it.usage();
  const idle = delta(c, e);
  dt.close();
  await it.stop();
  return { loadMs: median(loads), mainCpuMsPerLoad: (d.main.cpu / 6) * 1000, hostCpuMsPerLoad: (d.host.cpu / 6) * 1000,
    totalCpuMsPerLoad: (d.total.cpu / 6) * 1000, idleHostCpuPct: (idle.host.cpu / idle.secs) * 100,
    idleHostWakeups: idle.host.idlePerSec + idle.host.intrPerSec, renderers: e.renderer.n, totalMB: e.total.mb };
};

scenarios.memory = async () => {
  const it = start();
  await pageLoaded(it);
  await it.ok("onscreen on");
  const dt = await devtools(it);
  await sleep(4000);
  const host = [it.usage().host.mb], total = [it.usage().total.mb];
  for (let cycle = 0; cycle < 4; cycle++) {
    await openTabs(it, dt, 12);
    await sleep(1500);
    for (let i = 0; i < 24; i++) { await it.ok("menu nextTab"); await sleep(120); }
    for (let i = 0; i < 4; i++) {
      await it.ok("menu newTab");
      await sleep(200);
      for (const ch of "site1") { await it.ok(`type ${ch}`); await sleep(40); }
      await it.ok("escape");
      await it.cmd("escape");
      await sleep(200);
    }
    for (let i = 0; i < 4; i++) { await it.ok("menu toggleSidebar"); await sleep(600); }
    for (let i = 0; i < 12; i++) { await it.cmd("menu closeTab"); await sleep(150); }
    await sleep(6000);
    const u = it.usage();
    host.push(u.host.mb);
    total.push(u.total.mb);
  }
  dt.close();
  await it.stop();
  return { startHostMB: host[0], afterHostMB: host.at(-1), growthPerCycleHostMB: (host[4] - host[1]) / 3,
    startTotalMB: total[0], afterTotalMB: total.at(-1), growthPerCycleTotalMB: (total[4] - total[1]) / 3 };
};

// MARK: Run

const results = {};
for (const name of only) {
  const fn = scenarios[name];
  if (!fn) { log(`no scenario ${name}`); continue; }
  const n = name === "launch" ? Math.max(runs, 5) : runs;
  const samples = [];
  for (let i = 0; i < n; i++) {
    log(`${name} run ${i + 1}/${n}`);
    try { samples.push(await fn()); } catch (error) { log(`${name} run ${i + 1} failed: ${error.message}`); }
  }
  const keys = [...new Set(samples.flatMap(Object.keys))];
  results[name] = Object.fromEntries(keys.map((k) => [k, typeof samples[0]?.[k] === "boolean" ? samples[0][k] : round(median(samples.map((s) => s[k])), 2)]));
  results[name].runs = samples.length;
  log(name, JSON.stringify(results[name]));
}
const report = { label, app, date: new Date().toISOString(), runs, results };
if (out) writeFileSync(out, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
server.close();
process.exit(0);

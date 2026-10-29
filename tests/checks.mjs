#!/usr/bin/env node
// Drives a hidden build/Ray.app over DevTools and Ray's [ray-state] log.
//   node tests/checks.mjs [check …]      (build first: scripts/build-app.sh)
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { createServer as createSecureServer } from "node:https";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync, statSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync, crc32 } from "node:zlib";
import { createDecipheriv, pbkdf2Sync } from "node:crypto";

/** A square PNG of one colour, for fixture icons. */
function solidPNG(size) {
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type), data]);
    const out = Buffer.alloc(12 + data.length);
    out.writeUInt32BE(data.length, 0);
    body.copy(out, 4);
    out.writeUInt32BE(crc32(body) >>> 0, 8 + data.length);
    return out;
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8; header[9] = 2;
  const row = Buffer.concat([Buffer.from([0]), Buffer.from(Array(size).fill([230, 90, 40]).flat())]);
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(Array(size).fill(row)))), chunk("IEND", Buffer.alloc(0)),
  ]);
}

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const app = join(root, "build/RayTests.app");
const port = 9400 + Math.floor(Math.random() * 400);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const pages = {
  "/a": `<title>Page A</title><a id=blank href="/b" target="_blank">blank</a> <a id=plain href="/b">plain</a>
         <button id=open onclick="window.open('/c')">open</button>`,
  "/b": `<title>Page B</title><p>b</p>`,
  // A page that loads a slow frame while it loads, then adds another and moves its own address after it has loaded
  // (as web apps do): one navigation, however many times the tab counts as loading.
  "/late-frames": `<title>Late frames</title><p>late frames</p><a id=next href="/slow?linked">next</a>
    <iframe src="/slow?inner"></iframe>
    <script>addEventListener("load", () => setTimeout(() => {
      history.pushState({}, "", "?pushed");
      const frame = document.createElement("iframe");
      frame.src = "/slow?late";
      document.body.append(frame);
    }, 300));</script>`,
  "/c": `<title>Page C</title><button id=close onclick="window.close()">close</button>`,
  // In-page anchors: same-document navigations that only change the address's fragment.
  "/anchors": `<title>Anchors</title><a id=jump href="#release-v0.2.43-nightly.1">jump</a>
    <div style="height:3000px"></div><h2 id=release-v0.2.43-nightly.1>v0.2.43</h2>`,
  "/h": `<title>Hist Page</title><p>history</p>`,
  "/find": `<title>Find</title><p>banana one</p><p>apple</p><p>banana two</p><p>banana three</p>`,
  "/search": `<title>Search</title><p>results</p>`,
  "/long": `<title>Long</title><style>body{margin:0;font:16px/1.6 sans-serif}p{margin:0 16px 12px}</style>` +
    Array.from({ length: 120 }, (_, i) => `<p id=p${i}>Paragraph ${i}: the quick brown fox jumps over the lazy dog, again and again, to make lines wrap differently at different widths.</p>`).join(""),
};
// Requests to /safe-storage/…, with the cookies they carried (the safe-storage-migration check).
const safeStorageRequests = [];
// Requests for search suggestions: the query and whose engine asked (RAY_SUGGEST_URL's `%e`).
const suggestRequests = [];
function serve(req, res) {
  const url = new URL(req.url, "http://x");
  if (url.pathname.startsWith("/safe-storage/")) {
    safeStorageRequests.push({ path: url.pathname, cookie: req.headers.cookie ?? "" });
    const headers = { "content-type": "text/html" };
    // Only when the browser didn't send it: a relaunch reloads this page, and must show the stored cookie, not a new one.
    if (url.pathname === "/safe-storage/set" && !/ray_safe=/.test(req.headers.cookie ?? ""))
      headers["set-cookie"] = `ray_safe=${url.searchParams.get("v")}; Max-Age=86400; Path=/`;
    res.writeHead(200, headers);
    return res.end("<title>Safe storage</title><p>safe storage</p>");
  }
  if (url.pathname === "/suggest") {
    const q = url.searchParams.get("q") ?? "";
    suggestRequests.push({ q, engine: url.searchParams.get("engine") });
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify([q, q.startsWith("zz") ? [`${q} one`, `${q} two`, q] : []]));
  }
  if (url.pathname.startsWith("/files/")) {
    // Attachments for the download checks.
    const name = url.pathname.slice("/files/".length);
    res.writeHead(200, { "content-type": "application/octet-stream", "content-disposition": `attachment; filename="${name}"` });
    return res.end("ray download fixture\n".repeat(64));
  }
  if (url.pathname === "/slow") {
    // The head arrives at once, the rest 1.5 s later: a page that is visibly loading for a while.
    res.writeHead(200, { "content-type": "text/html" });
    res.write("<title>Slow</title><p>starts at once</p>" + "<!-- padding -->".repeat(256));
    const timer = setTimeout(() => res.end("<p>done</p>"), 1500);
    res.on("close", () => clearTimeout(timer));
    return;
  }
  const body = pages[url.pathname];
  res.writeHead(body ? 200 : 404, { "content-type": "text/html" });
  res.end(body ?? "not found");
}
const server = createServer(serve);
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;

const dataDir = mkdtempSync(join(tmpdir(), "ray-checks-"));
// A throwaway self-signed certificate for the HTTPS fixture (the test app accepts any certificate).
execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=ray.test",
  "-keyout", join(dataDir, "fixture.key"), "-out", join(dataDir, "fixture.crt")], { stdio: "ignore" });
const secureServer = createSecureServer({ key: readFileSync(join(dataDir, "fixture.key")), cert: readFileSync(join(dataDir, "fixture.crt")) }, serve);
await new Promise((r) => secureServer.listen(0, "127.0.0.1", r));
const secureOrigin = `https://ray.test:${secureServer.address().port}`;
const crashesBefore = crashReports();
const stateMarker = "[ray-state] ";
let stderr = "";
let states = [];
let child;
let exitCode = null;
let exited;

function launch() {
  stderr = "";
  states = [];
  exitCode = null;
  let partial = "";
  child = spawn(join(app, "Contents/MacOS/Ray"), [], {
    env: {
      ...process.env,
      RAY_BACKGROUND: "1",
      RAY_LOG_STATE: "1",
      RAY_TEST_COMMANDS: "1",
      RAY_SUGGEST_URL: `${origin}/suggest?q=%s&engine=%e`,
      RAY_SEARCH_URL: `${origin}/search?q=%s`,
      RAY_DATA_DIR: dataDir,
      RAY_DOWNLOADS_DIR: join(dataDir, "Downloads"),
      RAY_HOST_RULES: "MAP ray.test 127.0.0.1",
      RAY_ARC_SIDEBAR: join(dataDir, "Arc", "StorableSidebar.json"),
      RAY_IGNORE_CERT_ERRORS: "1",
      RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}`,
      RAY_REMOTE_DEBUGGING_PORT: String(port),
      RAY_START_URL: `${origin}/a`,
    },
    stdio: ["pipe", "ignore", "pipe"],
  });
  child.stdin.on("error", () => {});
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    const lines = (partial + chunk).split("\n");
    partial = lines.pop();
    for (const line of lines) {
      const at = line.indexOf(stateMarker);
      if (at >= 0) states.push(JSON.parse(line.slice(at + stateMarker.length)));
    }
  });
  exited = new Promise((r) => child.on("exit", (code, signal) => r((exitCode = code ?? signal))));
}
launch();

const state = () => states.at(-1);
async function until(what, fn, ms = 8000, every = 100) {
  const end = Date.now() + ms;
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(every);
  }
}

let ws;
let nextId = 1;
const pending = new Map();
const events = [];
async function connect() {
  const version = await until("DevTools", async () => {
    try {
      return await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    } catch {
      return null;
    }
  }, 20000);
  ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = j)));
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
    } else events.push(msg);
  };
}
function send(method, params = {}, sessionId) {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params, sessionId }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}
async function targets() {
  return (await send("Target.getTargets")).targetInfos.filter((t) => t.type === "page");
}
async function session(urlPart) {
  const target = await until(`target ${urlPart}`, async () => (await targets()).find((t) => t.url.includes(urlPart)));
  const { sessionId } = await send("Target.attachToTarget", { targetId: target.targetId, flatten: true });
  return { target, sessionId };
}
async function evaluate(sessionId, expression) {
  const r = await send("Runtime.evaluate", { expression, userGesture: true, awaitPromise: true, returnByValue: true }, sessionId);
  return r.result?.value;
}
async function clickElement(sessionId, selector, modifiers = 0) {
  const box = await evaluate(sessionId, `(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
  for (const type of ["mousePressed", "mouseReleased"])
    await send("Input.dispatchMouseEvent", { type, x: box[0], y: box[1], button: "left", clickCount: 1, modifiers }, sessionId);
}
function frameOf(id) {
  const [x, y, w, h] = state().sidebarFrames[id].split(",").map(Number);
  return { x, y, w, h, cx: x + w / 2, cy: y + h / 2 };
}
function layoutOf(sidebar) {
  return JSON.stringify(["favorites", "pinned", "today"].map((k) => sidebar[k].map((e) => e.id)));
}
async function todayTabs(count) {
  while (state().sidebar.today.length < count) {
    const n = state().sidebar.today.length;
    await send("Target.createTarget", { url: `${origin}/c?n=${n}` });
    await until("today tab", () => state().sidebar.today.length > n);
  }
  await settle();
}
async function settle() {
  await sleep(250);
  await command("state");
}
async function commandResult(line) {
  const marker = `[ray-test] ${line} -> `;
  const from = stderr.length;
  child.stdin.write(line + "\n");
  return until(`command ${line}`, () => {
    const at = stderr.indexOf(marker, from);
    return at >= 0 ? stderr.slice(at + marker.length).split("\n")[0] : null;
  });
}
async function command(line) {
  const marker = `[ray-test] ${line} -> `;
  const from = stderr.length;
  child.stdin.write(line + "\n");
  const result = await until(`command ${line}`, () => {
    const at = stderr.indexOf(marker, from);
    return at >= 0 ? stderr.slice(at + marker.length).split("\n")[0] : null;
  });
  assert(result === "ok", `${line}: ${result}`);
}
const tabFor = (urlPart) => state()?.tabs.find((t) => t.url.includes(urlPart));
const visibleTabs = () => state()?.tabs.filter((t) => t.visible) ?? [];
function oneVisibleActive() {
  const s = state();
  const visible = visibleTabs();
  return visible.length === 1 && visible[0].id === s.active;
}
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
class Skip extends Error {}
function needsVisibleWindow() {
  if (state()?.windowVisibleOnScreen === false || state()?.windowOnActiveSpace === false)
    throw new Skip("the test window isn't on the visible desktop (a full-screen Space?), so Chrome hides its pages");
}

process.on("exit", () => { secureServer.close(); });
// Springs run on the display's frame timer, which stops while the display sleeps (overnight runs).
async function needsFrames() {
  await command("state");
  if (state()?.displayAsleep) throw new Skip("the display is asleep, so no animation frames arrive");
}

let savedSidebar = null;
let folderIDs = {};
let downloadedName = null;
let savedActive = null;
let savedSettings = null;

// Settings window checks: helpers.
const localOrigin = origin.replace("127.0.0.1", "localhost");
const raytestOrigin = origin.replace("127.0.0.1", "ray.test");
const allEntries = () => ["favorites", "pinned", "today"].flatMap((k) => state().sidebar[k]).filter((e) => e.kind !== "folder");
const entryOfTab = (tabId) => allEntries().find((e) => e.tab === tabId);
const activeTabState = () => state().tabs.find((t) => t.id === state().active);
const activeZoom = () => activeTabState()?.zoom;
const near = (a, b) => Math.abs(a - b) < 0.01;
/** Types an address into the command bar (⌘L: the current tab; ⌘T: a new one). */
async function goTo(url, newTab = false) {
  await command(newTab ? "menu newTab" : "menu focusAddress");
  await command(`type ${url}`);
  await command("enter");
}
async function setSetting(name, value) {
  await command(`setting ${name} ${value}`);
  await command("state");
}
async function closeSettingsWindow() {
  await command("settings close");
  await until("settings window closed", async () => { await command("state"); return state().settingsWindow.open === false; });
}
/** Each setting back to its default, so a check leaves nothing for the next. */
async function resetSettings() {
  for (const [name, value] of [["minimalURL", "off"], ["loadingProgress", "on"], ["theme", "default"], ["defaultZoom", "1"],
    ["newTabNextToActive", "off"], ["recentTabCycling", "on"], ["copyLinkShortcut", "on"], ["sidebarShortcut", "on"],
    ["appearanceMode", "auto"], ["scrollBars", "system"], ["pageAddressBar", "on"], ["showSidebarButton", "on"],
    ["fadeUnloadedTabs", "off"], ["tabReorderHaptics", "on"], ["undoReopensClosedTab", "off"], ["shortcuts", "default"]])
    await command(`setting ${name} ${value}`);
  await command("state");
}

/** A hidden instance of its own (own data dir, DevTools port and pasteboard), for checks that need launch settings the
 * shared one hasn't (RAY_REAUTH, RAY_TEST_SECRETS). `cmd` answers as `commandResult` does; `now()` logs and returns its
 * state; `stop()` quits it (killed after 15 s) and deletes its data dir. */
function ownInstance(name, env) {
  const dir = mkdtempSync(join(tmpdir(), `ray-${name}-`));
  const it = { dir, log: "", states: [], port: 10100 + Math.floor(Math.random() * 200) };
  let partial = "";
  it.proc = spawn(join(app, "Contents/MacOS/Ray"), [], {
    env: { ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_LOG_STATE: "1", RAY_DATA_DIR: dir,
      RAY_DOWNLOADS_DIR: join(dir, "Downloads"), RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}.${name}`,
      RAY_REMOTE_DEBUGGING_PORT: String(it.port), RAY_START_URL: `${origin}/b`, ...env },
    stdio: ["pipe", "ignore", "pipe"],
  });
  it.proc.stdin.on("error", () => {});
  it.proc.stderr.setEncoding("utf8");
  it.proc.stderr.on("data", (chunk) => {
    it.log += chunk;
    const lines = (partial + chunk).split("\n");
    partial = lines.pop();
    for (const line of lines) {
      const at = line.indexOf(stateMarker);
      if (at >= 0) it.states.push(JSON.parse(line.slice(at + stateMarker.length)));
    }
  });
  it.exit = new Promise((r) => it.proc.on("exit", (code, signal) => r(code ?? signal)));
  const tail = () => it.log.split("\n").filter((l) => l.trim()).slice(-6).join(" | ").slice(-1500);
  it.cmd = async (line, ms = 15000) => {
    const marker = `[ray-test] ${line} -> `;
    const from = it.log.length;
    it.proc.stdin.write(line + "\n");
    try {
      return await until(`command ${line}`, () => {
        const at = it.log.indexOf(marker, from);
        return at >= 0 ? it.log.slice(at + marker.length).split("\n")[0] : null;
      }, ms);
    } catch (error) { throw new Error(`${error.message}; its log: ${tail()}`); }
  };
  it.ok = async (line) => {
    const result = await it.cmd(line);
    assert(result === "ok", `${line}: ${result}`);
  };
  it.now = async () => {
    await it.cmd("state");
    return it.states.at(-1);
  };
  it.until = async (what, test, ms = 10000) => {
    try {
      return await until(what, async () => { const s = await it.now(); return test(s) ? s : null; }, ms, 150);
    } catch (error) {
      const s = it.states.at(-1) ?? {};
      throw new Error(`${error.message}; passwords ${JSON.stringify(s.passwordsPane)}, autofill ${JSON.stringify(s.autofillPane)}`);
    }
  };
  it.stop = async () => {
    it.proc.stdin.write("menu quit\n");
    const code = await Promise.race([it.exit, sleep(15000).then(() => "timeout")]);
    if (code === "timeout") it.proc.kill("SIGKILL");
    rmSync(it.dir, { recursive: true, force: true });
    assert(code !== "timeout", `the ${name} instance didn't quit within 15 s`);
  };
  return it;
}

const checks = {
  async boot() {
    await until("first tab", () => tabFor("/a"));
    assert(state().tabs.length === 1, `expected 1 tab, got ${state().tabs.length}`);
    assert(oneVisibleActive(), "the active tab isn't the only visible page");
  },
  async "page-channel"() {
    await until("hello", () => stderr.includes(`page channel ready`) && stderr.includes(`(${origin})`));
  },
  async navigate() {
    const { sessionId } = await session("/a");
    await evaluate(sessionId, `document.querySelector("#plain").click()`);
    await until("url /b", () => state().tabs.length === 1 && tabFor("/b"));
    await evaluate(sessionId, `history.back()`);
    await until("back to /a", () => state().tabs.length === 1 && tabFor("/a"));
    assert(state().address === "127.0.0.1", `address shows ${state().address}`);
  },
  async "target-blank"() {
    const before = state().tabs.length;
    const { sessionId } = await session("/a");
    await evaluate(sessionId, `document.querySelector("#blank").click()`);
    const opened = await until("new /b tab", () => state().tabs.length === before + 1 && tabFor("/b"));
    const ids = state().tabs.map((t) => t.id);
    assert(ids.indexOf(opened.id) === ids.indexOf(tabFor("/a").id) + 1, "new tab isn't right after its opener");
    await until("new tab active", () => state().active === opened.id && oneVisibleActive());
  },
  async "window-open"() {
    const before = state().tabs.length;
    const { sessionId } = await session("/a");
    await evaluate(sessionId, `document.querySelector("#open").click()`);
    const opened = await until("new /c tab", () => state().tabs.length === before + 1 && tabFor("/c"));
    await until("popup active", () => state().active === opened.id && oneVisibleActive());
  },
  async "background-tab"() {
    const { target } = await session("/a");
    await send("Target.activateTarget", { targetId: target.targetId });
    await until("/a active", () => state().active === tabFor("/a").id);
    const active = state().active;
    const before = state().tabs.length;
    const { sessionId } = await session("/a");
    await clickElement(sessionId, "#plain", 4);
    await until("background tab", () => state().tabs.length === before + 1);
    await sleep(300);
    assert(state().active === active, "⌘-click changed the active tab");
    assert(oneVisibleActive(), "a background tab became visible");
  },
  async "create-target"() {
    const before = state().tabs.length;
    await send("Target.createTarget", { url: `${origin}/b#created` });
    const created = await until("created tab", () => state().tabs.length === before + 1 && tabFor("#created"));
    await until("created tab active", () => state().active === created.id && oneVisibleActive());
  },
  async "activate-target"() {
    const { target } = await session("/a");
    await send("Target.activateTarget", { targetId: target.targetId });
    await until("/a active and only visible", () => state().active === tabFor("/a").id && oneVisibleActive());
  },
  async "page-closes-itself"() {
    const { sessionId, target } = await session("/c");
    await send("Target.activateTarget", { targetId: target.targetId });
    const closing = await until("/c active", () => state().active === tabFor("/c")?.id && tabFor("/c"));
    const before = state().tabs.length;
    await evaluate(sessionId, `window.close()`);
    await until("tab removed", () => state().tabs.length === before - 1 && !state().tabs.some((t) => t.id === closing.id));
    assert(state().active !== null && oneVisibleActive(), "no visible active tab after close");
  },
  async "close-target"() {
    const before = state().tabs.length;
    const target = (await targets()).find((t) => t.url.includes("#created"));
    await send("Target.closeTarget", { targetId: target.targetId });
    await until("tab removed", () => state().tabs.length === before - 1 && !tabFor("#created"));
    assert(oneVisibleActive(), "no visible active tab after close");
  },
  async permission() {
    // A prompt only shows over its own tab, so bring /a to the front first.
    const entryFor = (tabId) => ["favorites", "pinned", "today"].flatMap((k) => state().sidebar[k]).find((e) => e.tab === tabId);
    await command(`row ${entryFor(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    const { sessionId } = await session("/a");
    await evaluate(sessionId, `window.answer = null; Notification.requestPermission().then((r) => window.answer = r); 0`);
    const shown = await until("prompt", () => state().permission);
    assert(shown.kinds.includes("notifications"), `kinds ${shown.kinds}`);
    assert(shown.origin === origin + "/", `origin ${shown.origin}`);
    assert(await commandResult("perm allow") === "not ready", "Allow took a click in its first half second");
    await until("ready", async () => { await command("state"); return state().permission?.ready; }, 3000);
    // Only over its own tab: switching away hides it, coming back shows it again with a fresh half second.
    const home = state().activeEntry;
    await send("Target.createTarget", { url: `${origin}/b?perm` });
    await until("other tab", () => tabFor("/b?perm") && state().active === tabFor("/b?perm").id);
    await until("hidden", async () => { await command("state"); return state().permission === null; }, 3000);
    await command(`row ${home}`);
    await until("back", async () => { await command("state"); return state().permission !== null; }, 3000);
    assert(state().permission.ready === false, "the prompt came back without its half second");
    await until("ready again", async () => { await command("state"); return state().permission?.ready; }, 3000);
    await command("perm block");
    await until("denied", async () => (await evaluate(sessionId, `window.answer`)) === "denied");
    assert(await evaluate(sessionId, `Notification.requestPermission()`) === "denied", "Block wasn't remembered");
    await command("state");
    assert(state().permission === null, "a remembered answer prompted again");
  },
  async "permission-allow"() {
    await send("Target.createTarget", { url: `${secureOrigin}/b?allow` });
    const { sessionId } = await session(`${secureOrigin}/b?allow`);
    await until("loaded", async () => (await evaluate(sessionId, `document.readyState`)) === "complete");
    await evaluate(sessionId, `window.answer = null; window.getScreenDetails().then(() => window.answer = "ok", (e) => window.answer = e.name); 0`);
    const shown = await until("prompt", () => state().permission, 5000);
    assert(shown.kinds.includes("windowManagement"), `kinds ${shown.kinds}`);
    await until("ready", async () => { await command("state"); return state().permission?.ready; }, 3000);
    await command("perm allow");
    await until("granted", async () => (await evaluate(sessionId, `window.answer`)) === "ok");
    assert(await evaluate(sessionId, `navigator.permissions.query({ name: "window-management" }).then((p) => p.state)`) === "granted", "not remembered");
  },
  async "address-new-tab"() {
    const before = state().tabs.length;
    await command("menu newTab");
    await command(`type ${origin}/b#typed`);
    await command("enter");
    const opened = await until("typed tab", () => state().tabs.length === before + 1 && tabFor("#typed"));
    await until("typed tab active", () => state().active === opened.id && oneVisibleActive());
  },
  async "address-cancel"() {
    const before = state().tabs.length;
    const active = state().active;
    await command("menu newTab");
    await until("bar open", () => state().commandBar);
    await command("type something");
    await command("escape");
    await until("bar closed", () => state().commandBar === null);
    assert(state().tabs.length === before, "Esc opened a tab");
    assert(state().active === active, "Esc changed the active tab");
  },
  async "bar-lists-tabs"() {
    await command("menu newTab");
    const bar = await until("bar rows", () => state().commandBar?.rows.length && state().commandBar);
    assert(bar.mode === "newTab", `mode ${bar.mode}`);
    const tabRows = bar.rows.filter((r) => r.kind === "tab");
    assert(tabRows.length === Math.min(10, state().tabs.length - 1), `expected the other tabs, got ${tabRows.length}`);
    assert(!tabRows.some((r) => r.tab === state().active), `the current tab is offered: ${JSON.stringify(bar.rows)}`);
    assert(bar.rows.slice(0, tabRows.length).every((r) => r.kind === "tab"), `open tabs should come first: ${JSON.stringify(bar.rows)}`);
    assert(bar.rows.slice(tabRows.length).every((r) => r.kind === "history"), `then frequent history: ${JSON.stringify(bar.rows)}`);
    await command("escape");
  },
  async "bar-switch-to-tab"() {
    // From another tab: the current one is never offered.
    if (activeTabState()?.title === "Page B") {
      await command(`row ${entryOfTab(tabFor("/a").id).id}`);
      await until("on /a", async () => { await command("state"); return activeTabState()?.title === "Page A"; });
    }
    const before = state().tabs.length;
    await command("menu newTab");
    await command("type Page B");
    const bar = await until("tab row", () => state().commandBar?.rows.some((r) => r.kind === "tab") && state().commandBar);
    // An open tab you've been to whose title starts with what you typed leads (Arc), so Enter switches to it.
    assert(bar.rows[0].kind === "tab" && bar.rows[0].title === "Page B" && bar.selected === 0,
      `first row ${JSON.stringify(bar.rows[0])}, selected ${bar.selected}`);
    assert(bar.rows[1].kind === "search" && bar.rows[1].title === "Page B", `second row ${JSON.stringify(bar.rows[1])}`);
    await command("enter");
    await until("bar closed", () => state().commandBar === null);
    assert(state().tabs.length === before, "switching opened a tab");
    const active = state().tabs.find((t) => t.id === state().active);
    assert(active.title === "Page B" && oneVisibleActive(), `active is ${active.title}`);
  },
  async "bar-history"() {
    const { sessionId } = await session("/a");
    await evaluate(sessionId, `location.href = ${JSON.stringify(origin + "/h")}`);
    await until("on /h", () => tabFor("/h"));
    await evaluate((await session("/h")).sessionId, `location.href = ${JSON.stringify(origin + "/a")}`);
    await until("back on /a", () => !tabFor("/h"));
    await command("menu newTab");
    await command("type Hist");
    const bar = await until("history row", () => state().commandBar?.rows.some((r) => r.kind === "history" && r.title === "Hist Page") && state().commandBar);
    const row = bar.rows.findIndex((r) => r.kind === "history" && r.title === "Hist Page");
    const before = state().tabs.length;
    for (let i = 0; i < row; i++) await command("down");
    await command("enter");
    const opened = await until("history opened in new tab", () => state().tabs.length === before + 1 && tabFor("/h"));
    await until("active", () => state().active === opened.id);
  },
  async "address-navigate"() {
    const before = state().tabs.length;
    const active = state().active;
    await command("menu focusAddress");
    await command(`type ${origin}/c#navigated`);
    await command("enter");
    await until("active tab navigated", () => state().tabs.find((t) => t.id === active)?.url.includes("#navigated"));
    assert(state().tabs.length === before, "navigating opened a tab");
  },
  async "address-javascript"() {
    const active = state().active;
    const url = state().tabs.find((t) => t.id === active).url;
    await command("menu focusAddress");
    await command("type javascript:document.title='pwned'");
    await command("enter");
    await sleep(500);
    assert(state().tabs.find((t) => t.id === active).url === url, "javascript: changed the page");
    assert(!state().tabs.some((t) => t.title === "pwned"), "javascript: ran");
    await command("escape");
  },
  async "bar-one-row"() {
    await command("menu newTab");
    await command("type qqqxyz");
    const bar = await until("one row", () => state().commandBar?.query === "qqqxyz" && state().commandBar);
    await sleep(300);
    const now = state().commandBar;
    assert(now.rows.length === 1, `rows ${JSON.stringify(now.rows)}`);
    assert(now.rowsFullyVisible, "the only row is cut off");
    await command("escape");
  },
  async "bar-search-suggestions"() {
    await command("menu newTab");
    await command("type zzq");
    const bar = await until("suggestions", () => state().commandBar?.rows.some((r) => r.title === "zzq one") && state().commandBar);
    assert(bar.rows[0].title === "zzq" && bar.rows[0].kind === "search", `first row ${JSON.stringify(bar.rows[0])}`);
    assert(!bar.rows.slice(1).some((r) => r.title === "zzq"), "the typed query is repeated as a suggestion");
    assert(bar.rowsFullyVisible, "rows are cut off");
    await command("down");
    await until("second row selected", () => state().commandBar.selected === 1);
    const before = state().tabs.length;
    await command("enter");
    await until("search tab", () => state().tabs.length === before + 1 &&
      state().tabs.find((t) => t.id === state().active && t.url.startsWith(`${origin}/search?q=zzq`) && t.url.includes("one")));
  },
  async "bar-search-google"() {
    // Google is the default (Settings › Search): the bar says so, and a search goes to the template (here the
    // RAY_SEARCH_URL fixture), not to anything the engine reports.
    await command("menu newTab");
    await command("type fixed engine");
    const bar = await until("search row", () => state().commandBar?.query === "fixed engine" && state().commandBar.rows[0]?.kind === "search" && state().commandBar);
    assert(bar.rows[0].detail === "Search Google", `the search row says ${JSON.stringify(bar.rows[0])}`);
    const before = state().tabs.length;
    await command("enter");
    const tab = await until("search tab", () => state().tabs.length === before + 1 &&
      state().tabs.find((t) => t.id === state().active && t.url === `${origin}/search?q=fixed%20engine`));
    assert(tab, "the search didn't go to the template");
    await command(`rowaction close ${entryOfTab(tab.id).id}`);
    await until("search tab closed", () => state().tabs.length === before);
  },
  async "bar-actions"() {
    // Arc's command bar is also a control centre: menu commands by name, with their current shortcut, run as the menu
    // runs them, and only while the menu would enable them.
    await resetSettings();
    const barFor = async (text) => {
      await command("menu newTab");
      await until("bar open", async () => { await command("state"); return state().commandBar; });
      await command(`type ${text}`);
      return until(`rows for ${text}`, async () => { await command("state"); return state().commandBar?.query === text && state().commandBar; });
    };
    const actions = (bar) => bar.rows.filter((r) => r.kind === "action");
    const actionRow = (bar, title) => bar.rows.findIndex((r) => r.kind === "action" && r.title === title);
    const choose = async (index) => {
      for (let i = 0; i < index; i++) await command("down");
      await command("enter");
      await until("bar closed", () => state().commandBar === null);
    };
    await goTo(`${origin}/b?actions`, true);
    await until("page", async () => { await command("state"); return activeTabState()?.url.endsWith("/b?actions") && activeTabState()?.title === "Page B"; });
    const page = state().active;
    // "task": Task Manager, which has no shortcut, below what you typed (a partial name never takes Enter).
    let bar = await barFor("task");
    let at = actionRow(bar, "Task Manager");
    assert(at > 0 && bar.rows[at].detail === "", `task: ${JSON.stringify(bar.rows)}`);
    assert(bar.rows[0].kind === "search", `a partial name took the first row: ${JSON.stringify(bar.rows[0])}`);
    if (process.env.SNAP_DIR) await command(`barsnap ${join(process.env.SNAP_DIR, "command-bar-actions.png")}`);
    await command("escape");
    // Reopen Closed Tab (History's own target, not AppController) is offered too, with ⇧⌘T, once a tab was closed.
    await goTo(`${origin}/c?closed-for-bar`, true);
    await until("tab to close", async () => { await command("state"); return activeTabState()?.url.endsWith("/c?closed-for-bar"); });
    await command("menu closeTab");
    await until("closed", async () => { await command("state"); return !state().tabs.some((t) => t.url.endsWith("/c?closed-for-bar")); });
    bar = await barFor("reopen");
    at = actionRow(bar, "Reopen Closed Tab");
    assert(at >= 0 && bar.rows[at].detail === "⇧⌘T", `reopen: ${JSON.stringify(actions(bar))}`);
    await command("escape");
    // A short query offers two at most, a longer one three; and only word starts match ("ask" isn't Task Manager).
    bar = await barFor("re");
    assert(actions(bar).length > 0 && actions(bar).length <= 2, `"re" offered ${JSON.stringify(actions(bar))}`);
    await command("escape");
    bar = await barFor("page");
    assert(actions(bar).length <= 3, `"page" offered ${JSON.stringify(actions(bar))}`);
    await command("escape");
    bar = await barFor("ask");
    assert(actionRow(bar, "Task Manager") < 0, `"ask" matched mid-word: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    // An exact name leads, so Enter runs it: "zoom in" shows ⌘+ and zooms the page, as ⌘+ would.
    bar = await barFor("zoom in");
    assert(bar.rows[0].kind === "action" && bar.rows[0].title === "Zoom In" && bar.rows[0].detail === "⌘+",
      `zoom in: ${JSON.stringify(bar.rows)}`);
    await command("enter");
    await until("zoomed", async () => { await command("state"); return state().commandBar === null && near(activeZoom(), 1.1); }, 4000);
    assert(state().active === page, "Zoom In changed the tab");
    await command("zoom reset");
    await until("zoom back", async () => { await command("state"); return near(activeZoom(), 1); }, 4000);
    // "copy": Copy URL with ⇧⌘C, and with no shortcut once Settings gives ⇧⌘C to the page; it still copies.
    bar = await barFor("copy");
    at = actionRow(bar, "Copy URL");
    assert(at > 0 && bar.rows[at].detail === "⇧⌘C", `copy: ${JSON.stringify(bar.rows)}`);
    if (process.env.SNAP_DIR) {
      await command("down");
      await command(`barsnap ${join(process.env.SNAP_DIR, "command-bar-copy.png")}`);
    }
    await command("escape");
    await setSetting("copyLinkShortcut", "off");
    bar = await barFor("copy");
    at = actionRow(bar, "Copy URL");
    assert(at > 0 && bar.rows[at].detail === "", `copy without its shortcut: ${JSON.stringify(bar.rows)}`);
    await choose(at);
    await until("copied", async () => { await command("state"); return state().pasteboard === `${origin}/b?actions`; });
    await setSetting("copyLinkShortcut", "on");
    // An exact host match stays first: with chrome://history open, "history" autocompletes to its tab, and the
    // History command (an exact synonym) waits below it. With no host to complete, an exact name leads.
    // (Back on the page first: the current tab itself is never offered.)
    await command("menu showHistory");
    const historyTab = await until("history tab", async () => {
      await command("state");
      return activeTabState()?.url.startsWith("chrome://history") && activeTabState();
    });
    await command(`row ${entryOfTab(page).id}`);
    await until("back on the page", async () => { await command("state"); return state().active === page; });
    bar = await barFor("history");
    assert(bar.rows[0].kind === "tab" && bar.rows[0].tab === historyTab.id, `"history" first row: ${JSON.stringify(bar.rows[0])}`);
    assert(actionRow(bar, "Show Full History") > 0, `"history" didn't offer History: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    await command(`rowaction close ${entryOfTab(historyTab.id).id}`);
    await until("history tab closed", async () => { await command("state"); return !state().tabs.some((t) => t.id === historyTab.id); });
    bar = await barFor("task manager");
    assert(bar.rows[0].kind === "action" && bar.rows[0].title === "Task Manager", `task manager: ${JSON.stringify(bar.rows[0])}`);
    await command("escape");
    // An address that begins like an action word is an address: no action rows, and Enter goes there (a *.localhost
    // host, so nothing leaves the machine).
    bar = await barFor("printer.com");
    assert(bar.rows[0].kind === "url" && actions(bar).length === 0, `printer.com: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    const commandsRun = states.filter((s) => s.event === "chromeCommand").length;
    const tabs = state().tabs.length;
    const printer = origin.replace("http://127.0.0.1", "printer.localhost") + "/b?printer";
    bar = await barFor(printer);
    assert(bar.rows[0].kind === "url" && actions(bar).length === 0, `${printer}: ${JSON.stringify(bar.rows)}`);
    await command("enter");
    const opened = await until("printer tab", async () => { await command("state"); return state().tabs.length === tabs + 1 && tabFor("printer.localhost"); });
    assert(states.filter((s) => s.event === "chromeCommand").length === commandsRun, "the address ran a command");
    await command(`rowaction close ${entryOfTab(opened.id).id}`);
    await until("printer tab closed", async () => { await command("state"); return state().tabs.length === tabs; });
    // Print is there with a page, and not without one: a new private window has no tab.
    bar = await barFor("print");
    assert(actionRow(bar, "Print") >= 0, `print with a page: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    await command("menu newPrivateWindow");
    await until("private window", async () => { await command("state"); return state().private === true && state().commandBar; });
    await command("type print");
    bar = await until("private rows", async () => { await command("state"); return state().private && state().commandBar?.query === "print" && state().commandBar; });
    assert(actionRow(bar, "Print") < 0, `Print offered with no page: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    await command("key w cmd keywin");
    await until("back to the normal window", async () => { await command("state"); return state().private === false; }, 5000);
    await command(`rowaction close ${entryOfTab(page).id}`);
    await until("page closed", async () => { await command("state"); return !state().tabs.some((t) => t.id === page); });
    await resetSettings();
  },
  async "bar-ranking"() {
    // Arc's order: a page you go to that matches leads (Enter opens it), then what you typed, then the other pages;
    // the search engine's suggestions (the fixture's, for "zz…") only fill what's left of the five rows shown at once.
    // The list holds ten at most and scrolls. The current tab is never offered.
    const job = "/rank/zzconfig/job/app-v1-staging/job/common-pool/job/configupdate";
    Object.assign(pages, {
      "/rank/deploy": `<meta charset=utf-8><title>Zzconfig Update — CommonPool deployments</title><p>deploy</p>`,
      "/rank/zzlog": `<title>Zzconfig deploy log</title><p>log</p>`,
      [job]: `<title>Zzconfig job</title><p>job</p>`,
    });
    for (let i = 1; i <= 7; i++) pages[`/rank/p${i}`] = `<title>Zzconfig page ${i}</title><p>${i}</p>`;
    // History: /rank/deploy four times, the rest once (ten pages that match "zzconfig").
    await send("Target.createTarget", { url: `${origin}/b?rank-start` });
    const seeder = (await until("seeding tab", async () => { await command("state"); return tabFor("/b?rank-start"); })).id;
    const { sessionId } = await session("/b?rank-start");
    for (const path of ["/rank/deploy", "/rank/p1", "/rank/deploy", "/rank/p2", "/rank/deploy", "/rank/p3", "/rank/deploy",
      "/rank/p4", "/rank/p5", "/rank/p6", "/rank/p7", "/rank/zzlog", job, "/b?rank-away"]) {
      await send("Page.navigate", { url: origin + path }, sessionId);
      await until(`on ${path}`, async () => {
        await command("state");
        const tab = state().tabs.find((t) => t.id === seeder);
        return tab?.url === origin + path && (path.startsWith("/b") || tab.title.startsWith("Zzconfig"));
      });
    }
    const barFor = async (text) => {
      await command("menu newTab");
      await until("bar open", async () => { await command("state"); return state().commandBar; });
      await command(`type ${text}`);
      await sleep(300);
      await command("state");
      return state().commandBar?.query === text ? state().commandBar : null;
    };
    const deploy = "Zzconfig Update — CommonPool deployments";
    // History is read when the bar opens, so reopen it until the visits are in.
    let last = null;
    let bar = await until("ranked rows", async () => {
      const shown = (last = await barFor("zzconfig"));
      if (shown?.rows.length === 10 && shown.rows[0].title === deploy) return shown;
      await command("escape");
      return null;
    }, 15000).catch((error) => { throw new Error(`${error.message}: ${JSON.stringify(last?.rows)}`); });
    assert(bar.rows[0].kind === "history" && bar.selected === 0, `first row ${JSON.stringify(bar.rows[0])}, selected ${bar.selected}`);
    assert(bar.rows[1].kind === "search" && bar.rows[1].title === "zzconfig" && bar.rows[1].detail === "Search Google",
      `second row ${JSON.stringify(bar.rows[1])}`);
    assert(bar.rows.slice(2).every((r) => r.kind === "history"), `then pages: ${JSON.stringify(bar.rows)}`);
    // Short addresses: host, then the path's end, the middle elided; no scheme.
    const host = origin.replace("http://", "");
    assert(bar.rows[0].detail === `${host}/rank/deploy`, `deploy's address ${bar.rows[0].detail}`);
    const jobRow = bar.rows.find((r) => r.title === "Zzconfig job");
    assert(jobRow && jobRow.detail.startsWith(`${host}…`) && jobRow.detail.endsWith("job/configupdate") && jobRow.detail.length <= 32,
      `job's address ${jobRow?.detail}`);
    // Pages fill the five rows, so no suggestion shows (the fixture answers by now).
    await sleep(400);
    await command("state");
    bar = state().commandBar;
    assert(!bar.rows.some((r) => r.suggested), `suggestions with the rows full: ${JSON.stringify(bar.rows)}`);
    assert(bar.rows.length === 10 && bar.visibleRows === 5 && bar.firstVisibleRow === 0 && bar.rowsFullyVisible,
      `rows ${bar.rows.length}, shown ${bar.firstVisibleRow}+${bar.visibleRows}`);
    if (process.env.SNAP_DIR) await command(`barsnap ${join(process.env.SNAP_DIR, "command-bar-ranking.png")}`);
    // ↓ past the fifth row scrolls the list a row at a time; ↑ back to the top scrolls back.
    for (let i = 0; i < 5; i++) await command("down");
    await command("state");
    bar = state().commandBar;
    assert(bar.selected === 5 && bar.firstVisibleRow === 1 && bar.visibleRows === 5 && bar.rowsFullyVisible,
      `after 5 downs: selected ${bar.selected}, shown ${bar.firstVisibleRow}+${bar.visibleRows}`);
    for (let i = 0; i < 6; i++) await command("down");
    await command("state");
    bar = state().commandBar;
    assert(bar.selected === 9 && bar.firstVisibleRow === 5 && bar.rowsFullyVisible,
      `at the end: selected ${bar.selected}, shown ${bar.firstVisibleRow}+${bar.visibleRows}`);
    if (process.env.SNAP_DIR) await command(`barsnap ${join(process.env.SNAP_DIR, "command-bar-scrolled.png")}`);
    for (let i = 0; i < 9; i++) await command("up");
    await command("state");
    bar = state().commandBar;
    assert(bar.selected === 0 && bar.firstVisibleRow === 0, `back up: selected ${bar.selected}, first ${bar.firstVisibleRow}`);
    await command("escape");
    // Under three characters nothing leads: what you typed is first.
    bar = await until("zz rows", () => barFor("zz"));
    assert(bar.rows[0].kind === "search" && bar.rows[0].title === "zz", `"zz" first row ${JSON.stringify(bar.rows[0])}`);
    await command("escape");
    // Enter on the leading page opens it.
    const before = state().tabs.length;
    bar = await until("zzconfig rows", () => barFor("zzconfig"));
    assert(bar.rows[0].title === deploy, `first row ${JSON.stringify(bar.rows[0])}`);
    await command("enter");
    const opened = await until("deploy tab", async () => {
      await command("state");
      return state().tabs.length === before + 1 && state().tabs.find((t) => t.id === state().active && t.url === `${origin}/rank/deploy`);
    });
    // The current tab is never offered, nor its page as history: not for its title, not for its address, not in ⌘L.
    await until("deploy titled", async () => { await command("state"); return activeTabState()?.title === deploy; });
    for (const text of ["zzconfig", `${origin}/rank/deploy`, "127.0.0.1"]) {
      bar = await until(`rows for ${text}`, () => barFor(text));
      assert(!bar.rows.some((r) => r.tab === opened.id || r.title === deploy), `"${text}" offered the current tab: ${JSON.stringify(bar.rows)}`);
      await command("escape");
    }
    await command("menu focusAddress");
    await command(`type ${origin}/rank/deploy`);
    await sleep(300);
    await command("state");
    assert(state().commandBar.mode === "currentTab" && !state().commandBar.rows.some((r) => r.tab === opened.id),
      `⌘L offered the current tab: ${JSON.stringify(state().commandBar)}`);
    await command("escape");
    // Another tab on the same page is offered, and leads (open, and often visited).
    await send("Page.navigate", { url: `${origin}/rank/deploy` }, sessionId);
    await until("seeder on deploy", async () => {
      await command("state");
      return state().tabs.find((t) => t.id === seeder)?.title === deploy;
    });
    bar = await until("zzconfig rows", () => barFor("zzconfig"));
    assert(bar.rows[0].kind === "tab" && bar.rows[0].tab === seeder, `the other tab: ${JSON.stringify(bar.rows)}`);
    assert(!bar.rows.some((r) => r.tab === opened.id), `the current tab: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    // Few pages match: the pages, then two suggestions at most, within the five rows.
    bar = await until("suggestions", async () => {
      const shown = await barFor("zzconfig deploy");
      if (shown?.rows.some((r) => r.suggested)) return shown;
      await command("escape");
      return null;
    });
    const kinds = bar.rows.map((r) => (r.suggested ? "suggested" : r.kind));
    assert(JSON.stringify(kinds) === JSON.stringify(["tab", "search", "history", "suggested", "suggested"]),
      `"zzconfig deploy": ${JSON.stringify(bar.rows)}`);
    assert(bar.rows[2].title === "Zzconfig deploy log", `third row ${JSON.stringify(bar.rows[2])}`);
    if (process.env.SNAP_DIR) await command(`barsnap ${join(process.env.SNAP_DIR, "command-bar-suggestions.png")}`);
    await command("escape");
    for (const id of [opened.id, seeder]) await command(`rowaction close ${entryOfTab(id).id}`);
    await until("rank tabs closed", async () => {
      await command("state");
      return !state().tabs.some((t) => t.id === opened.id || t.id === seeder);
    });
  },
  async "devtools-docked"() {
    await command("menu toggleDevTools");
    const pages = await until("devtools docked", () => state().pages?.devToolsFrame && state().pages);
    const rect = (text) => text.match(/-?[\d.]+/g).map(Number);
    const [, , pw, ph] = rect(pages.pageFrame);
    const [, , dw, dh] = rect(pages.devToolsFrame);
    assert(pw > 100 && ph > 100, `page frame ${pages.pageFrame}`);
    assert(dw > 0 && dh > 0, `devtools frame ${pages.devToolsFrame}`);
    assert(pages.pageAboveDevTools === true, "the DevTools view covers the page");
    assert(oneVisibleActive(), "page not visible");
    await command("menu toggleDevTools");
    await until("devtools closed", () => !state().pages?.devToolsFrame);
  },
  async "switch-back-latency"() {
    await command("state");
    needsVisibleWindow();
    const { target, sessionId } = await session(`${origin}/a`);
    await send("Target.activateTarget", { targetId: target.targetId });
    await until("/a active", () => state().active === tabFor("/a")?.id);
    if (process.env.NO_NAV !== "1") {
      await evaluate(sessionId, `location.href = ${JSON.stringify(origin + "/b#nav1")}`);
      await until("nav1", () => tabFor("#nav1"));
      await evaluate((await session("#nav1")).sessionId, `location.href = ${JSON.stringify(origin + "/a")}`);
      await until("back on /a", () => !tabFor("#nav1"));
    }
    await send("Target.createTarget", { url: `${origin}/c#other` });
    await until("other active", () => state().active === tabFor("#other")?.id);
    await sleep(Number(process.env.HIDDEN_FOR ?? 1500));
    const again = await session(`${origin}/a`);
    const started = Date.now();
    await send("Target.activateTarget", { targetId: again.target.targetId });
    let shownAfter = null;
    for (let i = 0; i < 100 && shownAfter === null; i++) {
      const marker = `[ray-test] hit 400 14 -> `;
      const from = stderr.length;
      child.stdin.write("hit 400 14\n");
      const result = await until("hit", () => {
        const at = stderr.indexOf(marker, from);
        return at >= 0 ? stderr.slice(at + marker.length).split("\n")[0] : null;
      }, 2000, 2);
      if (result.startsWith("RenderWidgetHostViewCocoa")) shownAfter = Date.now() - started;
      else await sleep(2);
    }
    if (shownAfter === null) {
      await command("state");
      needsVisibleWindow();
    }
    console.log(`     page input surface shown ${shownAfter} ms after switching back`);
    assert(shownAfter !== null && shownAfter < 50, `page surface took ${shownAfter} ms`);
  },
  async "switch-no-blank"() {
    // Every display frame of a tab switch shows a page: the one left stays until the new one has drawn. The app
    // records each frame of a switch: o the page left, n the new one (once drawn), b both, - neither (blank).
    await needsFrames();
    const activeBefore = state().activeEntry;
    // On a full-screen Space the hidden window is off screen and Chrome draws nothing: bring it onto the shown
    // Space, nearly transparent and click-through, for this check only.
    let moved = false;
    if (state().windowVisibleOnScreen === false || state().windowOnActiveSpace === false) {
      await command("onscreen on");
      moved = true;
      await until("window on screen", async () => { await command("state"); return state().windowVisibleOnScreen; }, 5000, 100)
        .catch(() => {});
    }
    const opened = [];
    try {
      // On all Spaces the window doesn't count as on the active one; what Chrome goes by is whether it's visible.
      await command("state");
      if (!state().windowVisibleOnScreen) {
        throw new Skip(`the test window can't be put on screen (onActiveSpace ${state().windowOnActiveSpace}), so Chrome hides its pages`);
      }
      // Two pages in solid, different colours.
      const colours = { red: "#d02020", blue: "#2040d0" };
      for (const [name, colour] of Object.entries(colours)) {
        const url = `${origin}/b?switch=${name}`;
        const { targetId } = await send("Target.createTarget", { url });
        opened.push(targetId);
        await until(`${name} tab`, () => tabFor(url)?.title === "Page B");
        const { sessionId } = await session(url);
        await evaluate(sessionId, `document.documentElement.style.background = ${JSON.stringify(colour)}; true`);
      }
      const entryOf = (name) => allEntries().find((e) => e.live && e.url.endsWith(`/b?switch=${name}`)).id;
      const lastSwitch = () => state().pages.switches?.at(-1)?.n ?? 0;
      const seen = [];
      for (let i = 0; i < 6; i++) {
        // Long enough for the page left to lose its compositor, as on any real switch back.
        await sleep(400);
        await command("state");
        const before = lastSwitch();
        await command(`row ${entryOf(i % 2 ? "blue" : "red")}`);
        const record = await until("switch sampled", async () => {
          await command("state");
          return lastSwitch() > before && state().pages.switches.at(-1);
        }, 3000, 50);
        if (record.frames === "") throw new Skip("no display frames arrived during the switch");
        seen.push(record.frames);
      }
      console.log(`     switch frames: ${seen.join(" ")}`);
      assert(seen.every((f) => !f.includes("-")), `blank frames while switching tabs: ${seen.join(" ")}`);
      assert(seen.every((f) => f.endsWith("nn")), `the new page never drew: ${seen.join(" ")}`);
    } finally {
      if (activeBefore) await command(`row ${activeBefore}`);
      for (const targetId of opened) await send("Target.closeTarget", { targetId });
      if (moved) await command("onscreen off");
      await settle();
    }
  },
  async "top-strip-click"() {
    await command("state");
    needsVisibleWindow();
    const { target, sessionId } = await session(`${origin}/a`);
    await send("Target.activateTarget", { targetId: target.targetId });
    await until("/a active", () => state().active === tabFor("/a")?.id && oneVisibleActive());
    await evaluate(sessionId, `window.__downs = []; addEventListener("mousedown", (e) => __downs.push([e.clientX, e.clientY]), true); true`);
    // The strip is the page's own top edge, which only meets the window's top with the address bar off.
    const toolbar = state().toolbar != null;
    if (toolbar) await command("menu toggleToolbar");
    try {
      await sleep(Number(process.env.STRIP_WAIT ?? 300));
      await command("drag 400 14 120 60");
      await sleep(300);
      const downs = await evaluate(sessionId, `JSON.stringify(window.__downs)`);
      assert(JSON.parse(downs).length === 1, `page saw mousedowns ${downs}`);
      await command("menu newTab");
      await command("escape");
      assert(state().windowMovable === true, "window left unmovable after the drag");
    } finally {
      if (toolbar) await command("menu toggleToolbar");
    }
  },
  async "pin-unload-restore"() {
    const id = state().activeEntry;
    await command(`rowaction pin ${id}`);
    const pinned = await until("pinned", () => state().sidebar.pinned.find((e) => e.id === id));
    assert(pinned.pinnedURL === pinned.url, `pinned URL ${pinned.pinnedURL} vs ${pinned.url}`);
    const { sessionId } = await session(pinned.url);
    // Arc's rule: another query on the same path is still the pinned page (no "/", no Back to Pinned URL).
    const samePath = pinned.url.split(/[?#]/)[0] + "?tab=assigned";
    await evaluate(sessionId, `location.href = ${JSON.stringify(samePath)}`);
    const query = await until("same path, new query", () => state().sidebar.pinned.find((e) => e.id === id && e.url === samePath));
    assert(!query.away, `another query counted as away from ${pinned.pinnedURL}`);
    await evaluate(sessionId, `location.href = ${JSON.stringify(origin + "/b#away")}`);
    await until("away from pinned", () => state().sidebar.pinned.find((e) => e.id === id)?.away);
    await command(`rowaction back ${id}`);
    await until("back to pinned", () => !state().sidebar.pinned.find((e) => e.id === id)?.away);
    const liveBefore = state().tabs.length;
    await command("menu closeTab");
    const unloaded = await until("unloaded", () => {
      const e = state().sidebar.pinned.find((e) => e.id === id);
      return e && !e.live && e;
    });
    assert(unloaded.url === unloaded.pinnedURL, `unloaded at ${unloaded.url}`);
    await settle();
    assert(!state().sidebarFrames.alive.includes(id), "closed pinned tab still marked open");
    assert(state().tabs.length === liveBefore - 1, "the tab wasn't closed");
    await command(`row ${id}`);
    await until("reloaded and active", () => state().sidebar.pinned.find((e) => e.id === id)?.live && state().activeEntry === id);
    await settle();
    assert(state().sidebarFrames.alive.includes(id), "open pinned tab has no open dot");
    assert(oneVisibleActive(), "pinned tab not shown");
  },
  async favorites() {
    const id = state().sidebar.today[0].id;
    await command(`rowaction favorite ${id}`);
    await until("favorite", () => state().sidebar.favorites.some((e) => e.id === id) && !state().sidebar.today.some((e) => e.id === id));
    await command(`row ${id}`);
    await until("favorite active", () => state().activeEntry === id && oneVisibleActive());
  },
  async "drag-click-selects"() {
    await todayTabs(2);
    const before = state().sidebar;
    const target = before.today.find((e) => e.id !== state().activeEntry);
    const f = frameOf(target.id);
    await command(`drag ${f.cx} ${f.cy} 1 1`);
    await until("pressed row selected", () => state().activeEntry === target.id);
    assert(layoutOf(state().sidebar) === layoutOf(before), "a click without a drag moved a row");
  },
  async "drag-reorder"() {
    await todayTabs(3);
    const [first, , third] = state().sidebar.today;
    const a = frameOf(first.id);
    await command(`press ${a.cx} ${a.cy}`);
    await command(`move ${a.cx} ${a.cy + 10}`);
    await settle();
    const c = frameOf(third.id);
    await command(`move ${a.cx} ${c.cy + 4}`);
    await command(`release ${a.cx} ${c.cy + 4}`);
    await until("moved below the third", () => state().sidebar.today[2]?.id === first.id);
    await settle();
    const moved = frameOf(first.id), was = frameOf(state().sidebar.today[1].id);
    assert(moved.y > was.y, `dropped row at ${moved.y}, above its neighbour at ${was.y}`);
  },
  async "drag-to-pin"() {
    await todayTabs(2);
    const entry = state().sidebar.today[0];
    const pinnedBefore = state().sidebar.pinned.length;
    const from = frameOf(entry.id);
    await command(`press ${from.cx} ${from.cy}`);
    await command(`move ${from.cx} ${from.cy + 10}`);
    await settle();
    const newTab = frameOf("newTab");
    const aim = pinnedBefore === 0 ? newTab.y + 8 : newTab.y - 20;
    await command(`move ${from.cx} ${aim}`);
    await settle();
    const moved = frameOf("newTab");
    assert(moved.y > newTab.y + 30, `no gap opened above New Tab (${newTab.y} -> ${moved.y})`);
    assert(!("pinHint" in state().sidebarFrames || "pinnedGlow" in state().sidebarFrames), "a pin box showed");
    await command(`release ${from.cx} ${aim}`);
    const pinned = await until("pinned", () => state().sidebar.pinned.find((e) => e.id === entry.id));
    assert(state().sidebar.pinned.length === pinnedBefore + 1, "pinned count");
    assert(pinned.pinnedURL === pinned.url, `pinned URL ${pinned.pinnedURL} vs ${pinned.url}`);
  },
  async "drag-to-favorite"() {
    await settle();
    const entry = state().sidebar.pinned.at(-1);
    const from = frameOf(entry.id), first = state().sidebar.favorites[0];
    const listTop = Math.min(...[...state().sidebar.pinned, ...state().sidebar.today].map((e) => frameOf(e.id).y), frameOf("newTab").y);
    const tile = first ? frameOf(first.id) : { x: 12, cy: listTop - 30 };
    await command(`press ${from.cx} ${from.cy}`);
    await command(`move ${from.cx} ${from.cy - 10}`);
    await settle();
    let frames = state().sidebarFrames;
    assert(!("favoriteHint" in frames || "favoritesGlow" in frames), "favorites lit while over the list");
    await command(`move ${tile.x + 4} ${tile.cy}`);
    await settle();
    frames = state().sidebarFrames;
    assert((first ? "favoritesGlow" : "favoriteHint") in frames, "favorites not lit with the tab over them");
    const slot = frameOf(first ? "favoritesGlow" : "favoriteHint");
    const rowsTop = Math.min(frameOf("newTab").y, ...[...state().sidebar.pinned, ...state().sidebar.today]
      .filter((e) => e.id !== entry.id).map((e) => frameOf(e.id).y));
    assert(rowsTop >= slot.y + slot.h, `the list didn't make room for the favorites slot (${slot.y}+${slot.h} > ${rowsTop})`);
    await command(`release ${tile.x + 4} ${tile.cy}`);
    await until("favorite added at the end", () => state().sidebar.favorites.at(-1)?.id === entry.id);
    assert(!state().sidebar.pinned.some((e) => e.id === entry.id), "still pinned");
    assert(state().sidebar.favorites.at(-1).pinnedURL, "favorite lost its URL");
  },
  async "drag-pin-hint-gone"() {
    await settle();
    assert(!("pinHint" in state().sidebarFrames), "the empty pin slot stayed after the drop");
    const after = state().sidebarFrames;
    assert(!["favoriteHint", "favoritesGlow", "pinnedGlow"].some((k) => k in after), "a drop highlight stayed after the drop");
  },
  async "drag-out-cancels"() {
    await settle();
    const before = layoutOf(state().sidebar);
    const tile = frameOf(state().sidebar.favorites[0].id);
    await command(`drag ${tile.cx} ${tile.cy} 700 200`);
    await settle();
    assert(layoutOf(state().sidebar) === before, "dropping on the page moved a tab");
  },
  async "drag-favorite-to-today"() {
    const entry = state().sidebar.favorites[0];
    const tile = frameOf(entry.id), row = frameOf(state().sidebar.today[0].id);
    await command(`drag ${tile.cx} ${tile.cy} ${row.cx - tile.cx} ${row.cy - tile.cy}`);
    const today = await until("today", () => state().sidebar.today.find((e) => e.id === entry.id));
    assert(today.pinnedURL === null, "today tab kept a pinned URL");
    assert(!state().sidebar.favorites.some((e) => e.id === entry.id), "still a favorite");
  },
  async "tile-hover"() {
    await todayTabs(2);
    const [fav, other] = state().sidebar.today;
    await command(`rowaction favorite ${fav.id}`);
    await until("favorited", () => state().sidebar.favorites.some((e) => e.id === fav.id));
    await command(`row ${other.id}`);
    await until("other active", () => state().activeEntry === other.id);
    await settle();
    assert(state().sidebarFrames.tilesTracked === "1", "a tile has no tracking area");
    assert(state().sidebarFrames.hoveredTile === "" && state().sidebarFrames.hoverShown === "", "a tile showed hover with no pointer");
    const fades = Number(state().sidebarFrames.hoverFades);
    const tile = frameOf(fav.id), row = frameOf(other.id);
    await command(`hover ${tile.cx} ${tile.cy}`);
    await command("state");
    assert(state().sidebarFrames.hoveredTile === fav.id, `hovered ${state().sidebarFrames.hoveredTile}`);
    assert(state().sidebarFrames.hoverShown === fav.id, "the hovered tile didn't brighten");
    assert(Number(state().sidebarFrames.hoverFades) === fades + 1, "the hover didn't fade in");
    const lit = frameOf(fav.id);
    assert(lit.x === tile.x && lit.y === tile.y && lit.w === tile.w && lit.h === tile.h, "hover moved the tile");
    await command(`hover ${row.cx} ${row.cy}`);
    await command("state");
    assert(state().sidebarFrames.hoveredTile === "" && state().sidebarFrames.hoverShown === "", "hover stayed after the pointer left");
    assert(Number(state().sidebarFrames.hoverFades) === fades + 2, "the hover didn't fade out");
    // A selected tile keeps its look: hover doesn't brighten it.
    await command(`row ${fav.id}`);
    await until("tile active", () => state().activeEntry === fav.id);
    await command(`hover ${tile.cx} ${tile.cy}`);
    await command("state");
    assert(state().sidebarFrames.hoveredTile === fav.id, "a selected tile ignored the pointer");
    assert(state().sidebarFrames.hoverShown === "", "hover brightened the selected tile");
    await command(`hover ${row.cx} ${row.cy}`);
    await command(`row ${other.id}`);
    await command(`rowaction unfavorite ${fav.id}`);
    await until("unfavorited", () => !state().sidebar.favorites.some((e) => e.id === fav.id));
  },
  async "folder-create"() {
    await todayTabs(3);
    for (let i = 0; i < 2; i++) {
      const id = state().sidebar.today[0].id;
      await command(`rowaction pin ${id}`);
      await until("pinned", () => state().sidebar.pinned.some((e) => e.id === id));
    }
    const [a, b] = state().sidebar.pinned.filter((e) => e.kind === "pinned").slice(-2);
    await command(`rowaction newfolder ${a.id}`);
    const folder = await until("folder", () => state().sidebar.pinned.find((e) => e.kind === "folder" && state().sidebar.pinned.find((x) => x.id === a.id)?.parent === e.id));
    assert(folder.title === "New Folder", `folder named ${folder.title}`);
    const order = state().sidebar.pinned.map((e) => e.id);
    assert(order.indexOf(a.id) === order.indexOf(folder.id) + 1, "the tab isn't right after its folder");
    await until("renaming the new folder", async () => { await command("state"); return state().sidebarFrames.renaming === folder.id; }, 3000);
    await settle();
    assert(frameOf(a.id).x === frameOf(folder.id).x + 16, `indent ${frameOf(folder.id).x} -> ${frameOf(a.id).x}`);
    await command(`rename ${folder.id} Work`);
    await until("renamed", () => state().sidebar.pinned.find((e) => e.id === folder.id)?.title === "Work");
    folderIDs = { folder: folder.id, a: a.id, b: b.id };
  },
  async "folder-toggle"() {
    const { folder, a, b } = folderIDs;
    await command(`row ${b}`);
    await until("b active", () => state().activeEntry === b);
    await command(`rowaction togglefolder ${folder}`);
    await until("closed", () => state().sidebar.pinned.find((e) => e.id === folder)?.open === false);
    await settle();
    assert(state().sidebarFrames.hidden.includes(a), "a closed folder still shows its tab");
    await command(`row ${a}`);
    await until("a active", () => state().activeEntry === a);
    await settle();
    assert(!state().sidebarFrames.hidden.includes(a), "the active tab hid inside a closed folder");
    await command(`row ${folder}`);
    await until("open again", () => state().sidebar.pinned.find((e) => e.id === folder)?.open === true);
  },
  async "folder-rename"() {
    const { folder } = folderIDs;
    const folderRow = () => state().sidebar.pinned.find((e) => e.id === folder);
    await settle();
    // A double click is two single clicks (each toggles the folder); it never starts a rename.
    const f = frameOf(folder);
    await command(`press ${f.cx} ${f.cy} 1`);
    await command(`release ${f.cx} ${f.cy} 1`);
    await until("first click closed it", async () => { await command("state"); return folderRow().open === false; });
    await command(`press ${f.cx} ${f.cy} 2`);
    await command(`release ${f.cx} ${f.cy} 2`);
    await until("second click opened it", async () => { await command("state"); return folderRow().open === true; });
    await new Promise((r) => setTimeout(r, 400));
    await command("state");
    assert(state().sidebarFrames.renaming === "", `a double click started renaming ${state().sidebarFrames.renaming}`);
    assert(!("renameDone" in state().sidebarFrames), "a Done button showed without a rename");
    // Rename comes from the row's menu; Done commits.
    await command(`rowaction renamefolder ${folder}`);
    await until("renaming", async () => { await command("state"); return state().sidebarFrames.renaming === folder; }, 3000);
    const [dx, dy, dw, dh] = state().sidebarFrames.renameDone.split(",").map(Number);
    const row = frameOf(folder);
    assert(dw >= 30 && dw <= 70 && dh >= 14 && dh <= 26, `Done button is ${dw}x${dh}`);
    assert(dx >= row.x + row.w / 2 && dx + dw <= row.x + row.w, `Done at ${dx} outside the row's end (${row.x}..${row.x + row.w})`);
    assert(Math.abs(dy + dh / 2 - row.cy) <= 1.5, `Done at ${dy + dh / 2}, row middle ${row.cy}`);
    // The field's text sits where the label's was: the field takes the label's frame.
    assert(state().sidebarFrames.renameLook === "0,0.0,0.0", `rename field look ${state().sidebarFrames.renameLook}`);
    await command("type Work Done");
    await command("renamedone");
    await until("committed by Done", async () => { await command("state"); return folderRow().title === "Work Done" && state().sidebarFrames.renaming === ""; });
    assert(!("renameDone" in state().sidebarFrames), "the Done button stayed after committing");
    // Escape cancels.
    await command(`rowaction renamefolder ${folder}`);
    await until("renaming again", async () => { await command("state"); return state().sidebarFrames.renaming === folder; }, 3000);
    await command("type Nope");
    await command("escape");
    await until("cancelled", async () => { await command("state"); return state().sidebarFrames.renaming === ""; });
    assert(folderRow().title === "Work Done", `escape kept ${folderRow().title}`);
    // Enter commits.
    await command(`rowaction renamefolder ${folder}`);
    await until("renaming a third time", async () => { await command("state"); return state().sidebarFrames.renaming === folder; }, 3000);
    await command("type Work");
    await command("enter");
    await until("committed by Enter", async () => { await command("state"); return folderRow().title === "Work"; });
  },
  async "folder-animation"() {
    await needsFrames();
    await command("state");
    if (state().sidebarFrames.reduceMotion === "1") throw new Skip("Reduce Motion is on, so folders don't animate");
    const { folder, a, b } = folderIDs;
    const toggle = () => command(`rowaction togglefolder ${folder}`);
    const folderOpen = () => state().sidebar.pinned.find((e) => e.id === folder).open;
    // The folder's own animation has ended when the app says so (it counts the frames it drew part-way).
    const done = (what) => until(what, async () => { await command("state"); return state().sidebarFrames.folding === "0"; }, 3000, 30);
    const chevron = () => state().sidebarFrames.chevrons.split("|").find((c) => c.startsWith(folder)).split("=")[1].split(",").map(Number);
    // The active tab stays in sight inside a closed folder, so make another one active first.
    await command(`row ${b}`);
    await until("b active", () => state().activeEntry === b);
    await settle();
    assert(folderOpen() === true, "the folder starts closed");
    const below = frameOf(b).y, child = frameOf(a).y;
    const [openDx, openDy, midX, midY] = chevron();
    assert(Math.abs(openDx) < 0.6 && openDy > 2, `an open folder's chevron points ${openDx},${openDy}, not down`);
    await toggle();
    await until("closed", async () => { await command("state"); return folderOpen() === false; });
    await done("close animation");
    let frames = state().sidebarFrames;
    assert(Number(frames.foldSteps) >= 3, `closing drew over ${frames.foldSteps} frames`);
    assert(frames.hidden.includes(a) && frames.collapsing === "", `the child ended hidden:${frames.hidden} collapsing:${frames.collapsing}`);
    assert(frames.faded === "", `rows left faded: ${frames.faded}`);
    assert(frameOf(b).y === below - 41, `the row below is at ${frameOf(b).y}, was ${below}`);
    const [closedDx, closedDy, cx, cy] = chevron();
    assert(closedDx > 2 && Math.abs(closedDy) < 0.6, `a closed folder's chevron points ${closedDx},${closedDy}, not right`);
    assert(Math.abs(cx - midX) < 0.6 && Math.abs(cy - midY) < 0.6, `the chevron moved while turning: ${midX},${midY} -> ${cx},${cy}`);
    await toggle();
    await until("open", async () => { await command("state"); return folderOpen() === true; });
    await done("open animation");
    frames = state().sidebarFrames;
    assert(Number(frames.foldSteps) >= 3, `opening drew over ${frames.foldSteps} frames`);
    assert(!frames.hidden.includes(a) && frames.collapsing === "" && frames.faded === "", `the child didn't come back: ${JSON.stringify(frames)}`);
    assert(frameOf(a).y === child && frameOf(b).y === below, "rows weren't back in place after opening");
    assert(chevron().join() === [openDx, openDy, midX, midY].join(), "the chevron didn't turn back");
    // Toggling again mid-animation reverses from where things are drawn and ends in the right place.
    await toggle();
    await toggle();
    await done("reopened mid-close");
    await settle();
    frames = state().sidebarFrames;
    assert(folderOpen() === true && !frames.hidden.includes(a) && frames.faded === "" && frames.collapsing === "", "close then open left it wrong");
    assert(frameOf(a).y === child && frameOf(b).y === below, "close then open moved rows");
    assert((await commandResult(`hit ${frameOf(a).cx} ${frameOf(a).cy}`)).startsWith("SidebarRowView"), "the child can't be hit after reopening");
    await toggle();
    await toggle();
    await toggle();
    await done("closed mid-open");
    await settle();
    frames = state().sidebarFrames;
    assert(folderOpen() === false && frames.hidden.includes(a) && frames.collapsing === "" && frames.faded === "", `open, close, open, close left it wrong: ${frames.hidden}`);
    assert(frameOf(b).y < below, "the row below stayed down after closing");
    await toggle();
    await until("open at the end", async () => { await command("state"); return folderOpen() === true; });
    await done("final open");
  },
  async "folder-drag-in"() {
    const { folder, b } = folderIDs;
    await settle();
    const from = frameOf(b), target = frameOf(folder);
    await command(`press ${from.cx} ${from.cy}`);
    await command(`move ${from.cx} ${from.cy + 10}`);
    await command(`move ${target.cx} ${target.cy}`);
    await settle();
    assert(state().sidebarFrames.litFolder === folder, "the folder didn't light up under the tab");
    await command(`release ${target.cx} ${target.cy}`);
    await until("in the folder", () => state().sidebar.pinned.find((e) => e.id === b)?.parent === folder);
    await settle();
    assert(state().sidebarFrames.litFolder === "", "the folder stayed lit");
  },
  async "folder-drag-folder"() {
    const { folder, a, b } = folderIDs;
    const other = state().sidebar.today[0];
    await command(`rowaction pin ${other.id}`);
    await until("pinned last", () => state().sidebar.pinned.at(-1)?.id === other.id);
    await settle();
    const from = frameOf(folder), below = frameOf(other.id);
    await command(`press ${from.cx} ${from.cy}`);
    await command(`move ${from.cx} ${from.cy + 10}`);
    await settle();
    assert(state().sidebarFrames.hidden.includes(a), "a dragged folder didn't fold");
    const after = frameOf(other.id);
    await command(`move ${from.cx} ${after.y + after.h + 4}`);
    await command(`release ${from.cx} ${after.y + after.h + 4}`);
    await until("folder after the other tab", () => {
      const ids = state().sidebar.pinned.map((e) => e.id);
      return ids.indexOf(folder) > ids.indexOf(other.id);
    });
    const ids = state().sidebar.pinned.map((e) => e.id);
    const at = ids.indexOf(folder);
    assert(new Set([ids[at + 1], ids[at + 2]]).has(a) && new Set([ids[at + 1], ids[at + 2]]).has(b), `tabs left their folder: ${ids}`);
    assert([a, b].every((id) => state().sidebar.pinned.find((e) => e.id === id).parent === folder), "tabs lost their folder");
    void below;
  },
  async "folder-out-and-delete"() {
    const { folder, a, b } = folderIDs;
    await command(`rowaction outfolder ${a}`);
    await until("out", () => state().sidebar.pinned.find((e) => e.id === a)?.parent === null);
    await command(`rowaction nestfolder ${folder}`);
    const nested = await until("nested", () => state().sidebar.pinned.find((e) => e.kind === "folder" && e.parent === folder));
    await command(`rowaction deletefolder ${folder}`);
    await until("deleted", () => !state().sidebar.pinned.some((e) => e.id === folder));
    const pinned = state().sidebar.pinned;
    assert(pinned.find((e) => e.id === b).parent === null, "the deleted folder's tab didn't move up");
    assert(pinned.find((e) => e.id === nested.id).parent === null, "the deleted folder's folder didn't move up");
    await command(`rowaction infolder ${b} ${nested.id}`);
    await until("kept a folder for restore", () => state().sidebar.pinned.find((e) => e.id === b)?.parent === nested.id);
  },
  async extensions() {
    // A local unpacked extension with a toolbar popup; nothing is fetched from the Web Store.
    const dir = join(dataDir, "fixture-extension");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      manifest_version: 3, name: "Ray Fixture", version: "1.0",
      action: { default_title: "Fixture", default_popup: "popup.html" },
      // Only the extension's own icon, none for its action: the toolbar falls back to it, as Chrome's does.
      icons: { 16: "icon.png", 48: "icon.png" },
    }));
    writeFileSync(join(dir, "icon.png"), solidPNG(48));
    // Shaped like real popups: a dark page whose script fills it in late, sizing it again (a green block).
    writeFileSync(join(dir, "popup.html"), `<!doctype html><style>body{margin:0;background:#1d1d24;color:#eee;font:14px sans-serif}</style>` +
      `<body><div id=app>loading</div><script src="popup.js"></script></body>`);
    writeFileSync(join(dir, "popup.js"), `setTimeout(() => { const a = document.getElementById("app");
      a.style.cssText = "width:296px;height:216px;padding:12px;background:#22aa66"; a.textContent = "fixture popup"; }, 300);`);
    const from = stderr.length;
    await command(`extinstall ${dir}`);
    const id = await until("installed", () => stderr.slice(from).match(/\[ray-test\] installed ([a-p]{32})/)?.[1], 15000);
    await until("listed", async () => { await command("state"); return state().extensions.some((e) => e.id === id && e.enabled); }, 8000);
    const before = state().sidebar.today.length;
    // On the shown desktop, so the popup draws and its pixels can be read back (skipped where it can't be).
    const onScreen = await commandResult("onscreen on") === "ok";
    try {
      await command(`extrun ${id}`);
      await until("popup open", () => state().extensionPopup?.startsWith(`chrome-extension://${id}/popup.html`));
      const { sessionId } = await session(`chrome-extension://${id}/popup.html`);
      const page = await until("popup filled in", async () => {
        const p = await evaluate(sessionId, `({ text: document.body.innerText, w: innerWidth, h: innerHeight })`);
        return p?.text === "fixture popup" && p.w >= 320 && p.h >= 240 ? p : null;
      }, 8000);
      assert(state().sidebar.today.length === before, "the popup page showed up as a tab");
      assert(![...state().sidebar.today, ...state().sidebar.pinned].some((e) => e.url.startsWith("chrome-extension://")), "popup in the sidebar");
      // App side: the popup's window follows the page's size, and its page is shown with Chrome's content under it.
      const view = await until("popup window sized", async () => {
        await command("state");
        const v = state().extensionPopupView;
        const [, , w, h] = v?.frame.split(",").map(Number) ?? [];
        return v && w >= page.w && h >= page.h ? v : null;
      }, 4000).catch(() => { throw new Error(`popup window ${JSON.stringify(state().extensionPopupView)}, page ${JSON.stringify(page)}`); });
      assert(view.visible && !view.pageHidden, `popup window ${JSON.stringify(view)}`);
      if (onScreen && view.onScreen) {
        // What reaches the screen is the page: mostly its green block, not a blank (white) window. Green leads red and
        // blue whatever the display's colour profile does to it.
        const [x, y, w, h] = view.frame.split(",").map(Number);
        const shot = join(dataDir, "popup-shot.bmp");
        const result = await until("popup drawn", async () => {
          if (spawnSync("screencapture", ["-x", "-t", "bmp", `-R${x},${y},${w},${h}`, shot]).status !== 0 || !existsSync(shot)) return { denied: true };
          const bmp = readFileSync(shot);
          const offset = bmp.readUInt32LE(10), width = bmp.readInt32LE(18), rows = Math.abs(bmp.readInt32LE(22));
          if (bmp.readUInt16LE(28) !== 32) return { denied: true };
          let green = 0, white = 0;
          for (let i = 0; i < width * rows; i++) {
            const [b, g, r] = [bmp[offset + 4 * i], bmp[offset + 4 * i + 1], bmp[offset + 4 * i + 2]];
            if (g > r + 50 && g > b + 30) green++;
            if (r > 235 && g > 235 && b > 235) white++;
          }
          const total = width * rows;
          const sample = { green: +(green / total).toFixed(2), white: +(white / total).toFixed(2) };
          return sample.green > 0.5 ? sample : null;
        }, 3000, 250).catch(() => null);
        assert(result, `the popup's window doesn't show its page (blank): ${JSON.stringify(view)}`);
        if (result.denied) console.log("     note: screen capture not allowed, popup pixels not checked");
      } else console.log("     note: test window not on the shown desktop, popup pixels not checked");
      const [, , w, h] = view.frame.split(",").map(Number);
      assert(w === page.w && h === page.h, `popup window ${w}×${h} for a ${page.w}×${page.h} page`);
      assert(view.renderView && view.contentLayers > 0, `no content layer under the popup's render view: ${JSON.stringify(view)}`);
      assert(view.behind === 1 && !view.opaque, `something drawn behind the popup's page: ${JSON.stringify(view)}`);
      await command("extclose");
      await until("popup closed", () => state().extensionPopup === null);
      // A tab switch ends it (Chrome's popup closes when it loses focus), and so does the page closing itself.
      await todayTabs(before + 1);
      await command(`extrun ${id}`);
      await until("popup open again", () => state().extensionPopup);
      await command("menu nextTab");
      await until("popup closed by a tab switch", async () => { await command("state"); return state().extensionPopup === null; });
      await command(`extrun ${id}`);
      await until("popup open once more", () => state().extensionPopup);
      const again = await session(`chrome-extension://${id}/popup.html`);
      await evaluate(again.sessionId, "window.close()");
      await until("popup closed by its page", async () => { await command("state"); return state().extensionPopup === null && state().extensionPopupView === null; });
    } finally {
      if (onScreen) await commandResult("onscreen off");
    }
    await command("menu toggleSiteControls");
    await until("panel lists it", async () => { await command("state"); return state().siteControls?.extensions.includes(id); });
    assert(state().siteControls.extensionIcons[id] === true, "the panel's tile has no icon for an extension with one");
    await command("menu toggleSiteControls");
    await until("panel closed", async () => { await command("state"); return state().siteControls === null; });
    await until("popup page gone", async () => !(await targets()).some((t) => t.url.startsWith(`chrome-extension://${id}/`)), 8000);
  },
  async "extension-prompt"() {
    await command("extprompt fake Evil\u2028Name");
    await until("prompt shown", () => state().installPrompt);
    assert(state().installPrompt.addEnabled === false, "Add was clickable straight away");
    assert(await commandResult("extprompt accept") === "not ready", "Add took a click in its first half second");
    await until("add ready", async () => { await command("state"); return state().installPrompt?.addEnabled; }, 3000);
    await command("extprompt cancel");
    await until("prompt gone", () => state().installPrompt === null);
  },
  async downloads() {
    const { sessionId } = await session(state().tabs.find((t) => t.active)?.url ?? "/a");
    await until("loaded", async () => (await evaluate(sessionId, `document.readyState`)) === "complete");
    await evaluate(sessionId, `(() => { const a = document.createElement("a"); a.href = "/files/notes.txt"; a.click(); })()`);
    const item = await until("finished", () => state().downloads.find((d) => d.filename === "notes.txt" && d.state === "finished"), 15000);
    assert(item.path.startsWith(join(dataDir, "Downloads")), `saved to ${item.path}`);
    assert(existsSync(item.path), "no file on disk");
    await command("dlopen");
    await until("list open", () => state().downloadsOpen);
    if (process.env.SNAP_DIR) { await sleep(300); await command(`dlsnap ${join(process.env.SNAP_DIR, "downloads.png")}`); }
    // The button sits bottom left in the sidebar's footer.
    const [bx, by] = state().downloadsButton.split(",").map(Number);
    const windowHeight = Number(state().windowFrame.match(/-?[\d.]+/g)[3]);
    assert(bx < 40 && by > windowHeight - 80, `downloads button at ${bx},${by}`);
    downloadedName = item.filename;
    // ⌥⌘L toggles the panel; with the sidebar hidden, opening it brings the sidebar out and keeps it out.
    await command("menu showDownloads");
    await until("panel closed", () => !state().downloadsOpen);
    await command("menu toggleSidebar");
    await until("sidebar hidden", () => state().sidebar.hidden);
    await command("menu showDownloads");
    await until("panel open over a peeking sidebar", () => state().downloadsOpen && state().sidebar.peeking);
    await command("pointer 900 400");
    await sleep(400);
    await command("state");
    assert(state().sidebar.peeking, "the sidebar hid while the downloads panel was open");
    await command("menu showDownloads");
    await until("panel closed again", () => !state().downloadsOpen);
    await command("pointer 900 400");
    await until("sidebar hides after", async () => { await command("state"); return !state().sidebar.peeking; }, 3000);
    await command("menu toggleSidebar");
    await until("sidebar back", () => !state().sidebar.hidden);
  },
  async "download-insecure-blocked"() {
    // A file over plain HTTP from a secure page never lands without Keep. This engine cancels Chrome's insecure
    // download; a newer one may hold it as dangerous (Ardia 0.2.42 shows Keep/Discard for that). Either way nothing
    // is on disk until Keep is pressed, and this check never presses it.
    const insecure = origin.replace("127.0.0.1", "ray.test");
    await send("Target.createTarget", { url: `${secureOrigin}/b?dl` });
    const { sessionId } = await session(secureOrigin);
    await until("loaded", async () => (await evaluate(sessionId, `document.readyState`)) === "complete");
    await evaluate(sessionId, `(() => { const a = document.createElement("a"); a.href = ${JSON.stringify(insecure + "/files/held.txt")}; a.click(); })()`);
    const item = await until("blocked", () => state().downloads.find((d) => d.filename === "held.txt" && (d.state !== "downloading" || d.dangerous)), 15000);
    assert(item.state !== "finished", "an insecure download finished");
    await sleep(500);
    assert(!existsSync(join(dataDir, "Downloads", "held.txt")), "an insecure download was saved");
  },
  async "find-in-page"() {
    await send("Target.createTarget", { url: `${origin}/find` });
    await until("find page", () => tabFor("/find") && state().active === tabFor("/find").id);
    const { sessionId } = await session("/find");
    await until("loaded", async () => (await evaluate(sessionId, `document.readyState`)) === "complete");
    await command("key f cmd");
    await until("bar open", () => state().find);
    await command("type banana");
    await until("three matches", () => state().find?.count === 3 && state().find.active === 1, 5000);
    await command("enter");
    await until("second", () => state().find?.active === 2);
    await command("key g cmd");
    await until("third", () => state().find?.active === 3);
    await command("key g cmd shift");
    await until("back to second", () => state().find?.active === 2);
    await command("escape");
    await until("closed", () => state().find === null);
    // The bar's buttons take clicks, even after a toast has come and gone in the same corner.
    await command("key c cmd shift");
    await until("toast", () => state().toast !== "");
    await until("toast gone", async () => { await command("state"); return state().toast === ""; }, 5000);
    await sleep(400);
    await command("key f cmd");
    await until("open again", () => state().find);
    await command("type banana");
    await until("matches again", () => state().find?.count === 3, 5000);
    const [fx, fy, fw, fh] = state().find.frame.split(",").map(Number);
    const before = state().find.active;
    await command(`press ${fx + fw - 47} ${fy + fh / 2}`);
    await command(`release ${fx + fw - 47} ${fy + fh / 2}`);
    await until("next by click", async () => { await command("state"); return state().find?.active === before % 3 + 1; }, 3000);
    await command(`press ${fx + fw - 19} ${fy + fh / 2}`);
    await command(`release ${fx + fw - 19} ${fy + fh / 2}`);
    await until("closed by click", async () => { await command("state"); return state().find === null; }, 3000);
  },
  async "about-panel"() {
    if (!process.env.SNAP_DIR) return;
    await command(`aboutsnap ${join(process.env.SNAP_DIR, "about.png")}`);
  },
  async "privacy-usage-descriptions"() {
    // macOS kills an app that touches the camera, microphone or location without saying why in its Info.plist.
    const plist = readFileSync(join(app, "Contents/Info.plist"), "utf8");
    for (const key of ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSLocationUsageDescription", "NSBluetoothAlwaysUsageDescription"])
      assert(plist.includes(`<key>${key}</key>`), `Info.plist lacks ${key}`);
  },
  async "updater-config"() {
    // Self-update (Sparkle): the feed, the key and the version keys are in Info.plist, Sparkle.framework is embedded
    // and signed, and the test build never starts the updater (so a check run can't reach the feed).
    const plist = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", join(app, "Contents/Info.plist")], { encoding: "utf8" }));
    assert(plist.SUFeedURL === "https://github.com/shanuflash/ray/releases/latest/download/appcast.xml", `SUFeedURL is ${plist.SUFeedURL}`);
    assert(typeof plist.SUPublicEDKey === "string" && plist.SUPublicEDKey.length > 0, "Info.plist lacks SUPublicEDKey");
    assert(plist.SUPublicEDKey === readFileSync(join(root, "Branding/sparkle-public-key.txt"), "utf8").trim(), "SUPublicEDKey isn't Branding/sparkle-public-key.txt");
    assert(plist.SUEnableAutomaticChecks === true && plist.SUScheduledCheckInterval === 86400, "automatic daily checks aren't on");
    assert(plist.SUAutomaticallyUpdate === true, "Settings › General's install-automatically default isn't on");
    const version = Object.fromEntries(readFileSync(join(root, "VERSION"), "utf8").trim().split("\n").map((l) => l.split("=")));
    assert(plist.CFBundleShortVersionString === version.version, `CFBundleShortVersionString ${plist.CFBundleShortVersionString} != VERSION ${version.version}`);
    assert(/^\d+$/.test(plist.CFBundleVersion) && plist.CFBundleVersion === version.build, `CFBundleVersion ${plist.CFBundleVersion} != VERSION build ${version.build}`);
    const framework = join(app, "Contents/Frameworks/Sparkle.framework");
    const lock = Object.fromEntries(readFileSync(join(root, "sparkle.lock"), "utf8").trim().split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
    const frameworkInfo = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", join(framework, "Versions/B/Resources/Info.plist")], { encoding: "utf8" }));
    assert(frameworkInfo.CFBundleShortVersionString === lock.version, `embedded Sparkle is ${frameworkInfo.CFBundleShortVersionString}, sparkle.lock says ${lock.version}`);
    for (const part of ["Versions/B/Autoupdate", "Versions/B/Updater.app"])
      assert(existsSync(join(framework, part)), `Sparkle.framework lacks ${part}`);
    assert(!existsSync(join(framework, "Versions/B/XPCServices")), "Sparkle's XPC services (sandbox only) are embedded");
    execFileSync("codesign", ["--verify", "--deep", "--strict", framework]);
    execFileSync("codesign", ["--verify", "--deep", "--strict", app]);
    // One signing identity across builds. With the owner's Apple Development certificate it has a Team ID, so the
    // keychain lets every build into "Ray Safe Storage" (its partition list); "Ray Code Signing" keeps permissions only.
    const identities = execFileSync("security", ["find-identity", "-v", "-p", "codesigning"], { encoding: "utf8" });
    if (identities.includes('"Apple Development: ')) {
      const signature = spawnSync("codesign", ["-dvv", "-r", "-", app], { encoding: "utf8" });
      const text = signature.stdout + signature.stderr;
      assert(/^TeamIdentifier=[A-Z0-9]{10}$/m.test(text) && /anchor apple generic/.test(text),
        `the app isn't signed with the Apple Development certificate: ${text.trim().split("\n").filter((l) => /Team|designated/.test(l)).join(" | ")}`);
    } else if (execFileSync("security", ["find-identity", "-p", "codesigning"], { encoding: "utf8" }).includes('"Ray Code Signing"')) {
      const requirement = spawnSync("codesign", ["-dr", "-", app], { encoding: "utf8" });
      assert(/certificate root = H"57dd31c307844623c2a646a24fb7f19c27327a4f"/.test(requirement.stdout + requirement.stderr),
        `the app isn't signed with Ray Code Signing: ${(requirement.stdout + requirement.stderr).trim().split("\n").at(-1)}`);
    }
    assert(execFileSync("otool", ["-L", join(app, "Contents/MacOS/Ray")], { encoding: "utf8" }).includes("@rpath/Sparkle.framework/"), "Ray isn't linked against Sparkle");
    await command("state");
    assert(state().updater?.started === false && state().updater?.reason === "test build", `the test build started the updater: ${JSON.stringify(state().updater)}`);
    // The app keeps no HTTP cache, so a check always fetches the current feed (a cached redirect once pinned 0.1.0).
    await command("state");
    assert(state().updater?.urlCacheBytes === 0, `the app still has an HTTP cache: ${JSON.stringify(state().updater)}`);
  },
  async "private-window"() {
    const mainEntry = state().activeEntry;
    await command("menu newPrivateWindow");
    // Both windows log; ask for the current one's state so the normal window's own updates don't race this.
    await until("private window", async () => { await command("state"); return state().private === true && state().commandBar; });
    await command(`type ${origin}/b?private`);
    await command("enter");
    await until("private page", async () => { await command("state"); return state().private === true && state().tabs.some((t) => t.url.includes("/b?private")); });
    assert(state().sidebar.favorites.length === 0 && state().sidebar.pinned.length === 0, "a private window started with saved tabs");
    // Cookies set in the private window stay there, on the same site.
    const priv = await session("/b?private");
    await until("loaded", async () => (await evaluate(priv.sessionId, `document.readyState`)) === "complete");
    await evaluate(priv.sessionId, `document.cookie = "private_marker=1; path=/"`);
    const normal = await session("/a");
    const normalCookies = await evaluate(normal.sessionId, `document.cookie`);
    assert(!normalCookies.includes("private_marker"), `a private cookie reached a normal window: ${normalCookies}`);
    await sleep(800);
    const saved = existsSync(join(dataDir, "Sidebar.json")) ? readFileSync(join(dataDir, "Sidebar.json"), "utf8") : "";
    assert(!saved.includes("b?private"), "a private tab was saved to Sidebar.json");
    // ⌘W closes the private tab, then with no tab left, the window.
    await command("key w cmd");
    await until("private tab closed", async () => { await command("state"); return state().private === true && state().active === null; }, 5000);
    await command("key w cmd keywin");
    await until("back to the normal window", async () => { await command("state"); return state().private === false; }, 5000);
    await until("private page gone", async () => !(await targets()).some((t) => t.url.includes("/b?private")), 8000);
    assert(state().activeEntry === mainEntry, "the normal window changed while the private one was open");
  },
  async "open-from-other-apps"() {
    // Ray as a web browser to macOS: the build declares http(s) and HTML (what System Settings › Default web browser
    // lists) and PDF, and no file: scheme.
    const plist = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", join(app, "Contents/Info.plist")], { encoding: "utf8" }));
    const schemes = (plist.CFBundleURLTypes ?? []).flatMap((t) => t.CFBundleURLSchemes ?? []);
    assert(schemes.includes("http") && schemes.includes("https"), `URL schemes: ${schemes}`);
    assert(!schemes.includes("file"), "Ray claims file: links");
    const types = (plist.CFBundleDocumentTypes ?? []).flatMap((t) => t.LSItemContentTypes ?? []);
    for (const type of ["public.html", "public.xhtml", "com.adobe.pdf"]) assert(types.includes(type), `no ${type} in ${types}`);
    assert(plist.CFBundleDocumentTypes.every((t) => t.CFBundleTypeRole === "Viewer"), "a document type isn't Viewer");

    const otherAppOpens = (log, from) => [...log.slice(from).matchAll(/\[ray\] from other apps: (\d+) received, (\d+) accepted, (\w+)(, queued)?/g)]
      .map((m) => ({ received: +m[1], accepted: +m[2], kind: m[3], queued: !!m[4] }));
    await command("state");
    const activeIs = (part) => async () => {
      await command("state");
      const t = tabFor(part);
      return t && state().active === t.id && state().private === false && t;
    };

    // A link, as another app sends it (a GetURL Apple Event): a new active Today tab in the normal window.
    await command(`appopen link ${origin}/b?other=1`);
    const first = await until("link tab", activeIs("/b?other=1"));
    assert(entryOfTab(first.id)?.kind === "today", "the link didn't open as a Today tab");
    assert(oneVisibleActive(), "the link's tab isn't the one visible page");

    // Anything but http(s) is refused: the engine's pages, script, data and file links; then a good one to wait on.
    let mark = stderr.length;
    const tabsBefore = state().tabs.length;
    for (const bad of ["javascript:alert(1)", "chrome://settings", "ray://settings", "data:text/html,<b>x</b>",
      "file:///private/etc/hosts", "view-source:https://example.com", "about:blank"])
      await command(`appopen link ${bad}`);
    await command(`appopen direct chrome://version javascript:void(0)`);
    await command(`appopen link ${origin}/b?other=after`);
    await until("link after the refused ones", activeIs("/b?other=after"));
    const refused = otherAppOpens(stderr, mark);
    assert(refused.at(-1)?.accepted === 1 && refused.slice(0, -1).every((r) => r.accepted === 0),
      `a refused URL was taken: ${JSON.stringify(refused)}`);
    assert(state().tabs.length === tabsBefore + 1, `${state().tabs.length - tabsBefore} tabs from one good link`);
    assert(!state().tabs.some((t) => /^(javascript|data|file|view-source|about):|^chrome:\/\/(settings|version)/.test(t.url)),
      `a refused URL opened: ${state().tabs.map((t) => t.url)}`);

    // Several at once: all as tabs, the last one active.
    await command(`appopen direct ${origin}/b?many=1 ${origin}/b?many=2 ${origin}/b?many=3`);
    await until("last of several active", activeIs("/b?many=3"));
    const today = state().sidebar.today.map((e) => e.url);
    assert(["/b?many=1", "/b?many=2", "/b?many=3"].every((u) => today.some((url) => url.includes(u))), `Today: ${today}`);

    // A command bar in the way closes for the link, so its page shows.
    await command("menu newTab");
    await until("command bar", async () => { await command("state"); return state().commandBar; });
    await command(`appopen link ${origin}/b?other=bar`);
    await until("link over the command bar", activeIs("/b?other=bar"));
    assert(state().commandBar === null, "the command bar stayed over the link's page");

    // Files: an HTML file from a document open (Finder's) opens as a file: page; other types, folders, missing files
    // and a file: link don't.
    const files = join(dataDir, "other-apps");
    mkdirSync(join(files, "folder.html"), { recursive: true });
    writeFileSync(join(files, "page.html"), "<title>Local file</title><p>local</p>");
    writeFileSync(join(files, "notes.txt"), "notes");
    writeFileSync(join(files, "run.sh"), "#!/bin/sh\necho hi\n");
    mark = stderr.length;
    await command(`appopen files ${["notes.txt", "run.sh", "folder.html", "missing.html"].map((f) => join(files, f)).join(" ")}`);
    await command(`appopen link file://${join(files, "page.html")}`);
    await until("refusals logged", () => otherAppOpens(stderr, mark).length === 2);
    assert(otherAppOpens(stderr, mark).every((r) => r.accepted === 0), `a file was taken: ${JSON.stringify(otherAppOpens(stderr, mark))}`);
    await command(`appopen files ${join(files, "page.html")}`);
    const local = await until("local file tab", activeIs("/other-apps/page.html"));
    assert(local.url.startsWith("file:///"), `the file opened as ${local.url}`);
    await until("local file loaded", async () => { await command("state"); return tabFor("/other-apps/page.html")?.title === "Local file"; });
    assert(!state().tabs.some((t) => /notes\.txt|run\.sh|folder\.html|missing\.html/.test(t.url)), "a refused file opened");

    // With a private window in front, the link still goes to the normal window.
    await command("menu newPrivateWindow");
    await until("private window", async () => { await command("state"); return state().private === true; });
    const privateStates = states.length;
    await command(`appopen link ${origin}/b?other=private`);
    await until("link in the normal window", activeIs("/b?other=private"));
    assert(!states.slice(privateStates).some((s) => s.private && s.tabs.some((t) => t.url.includes("other=private"))),
      "the link opened in the private window");
    await command("closewindow private");
    await until("private window closed", async () => (await commandResult("windows")) === "1");
    await command("state");
  },
  async "open-from-other-apps-launch"() {
    // A cold start by a link and then by a file, the way macOS starts Ray for them: `open -g -n` (a new instance, never
    // brought to the front) with the URL or file, on its own data dir. Its log goes to a file, and its test commands
    // come through a FIFO, since Launch Services starts it, not this script.
    const otherAppOpens = (log, from) => [...log.slice(from).matchAll(/\[ray\] from other apps: (\d+) received, (\d+) accepted, (\w+)(, queued)?/g)]
      .map((m) => ({ received: +m[1], accepted: +m[2], kind: m[3], queued: !!m[4] }));
    const { openSync, writeSync, closeSync, constants: fsConstants } = await import("node:fs");
    const dir = mkdtempSync(join(tmpdir(), "ray-open-"));
    const page = join(dir, "launch page.html");
    writeFileSync(page, "<title>Launch file</title><p>launch</p>");
    let it = null;
    const start = (target) => {
      const log = join(dir, `log-${Date.now()}.txt`);
      writeFileSync(log, "");
      const fifo = join(dir, `stdin-${Date.now()}`);
      execFileSync("mkfifo", [fifo]);
      // Opened read-write so neither side waits for the other.
      const input = openSync(fifo, fsConstants.O_RDWR);
      const env = { RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_LOG_STATE: "1", RAY_DATA_DIR: dir,
        RAY_DOWNLOADS_DIR: join(dir, "Downloads"), RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}.open`,
        RAY_SUGGEST_URL: `${origin}/suggest?q=%s`, RAY_SEARCH_URL: `${origin}/search?q=%s`, RAY_START_URL: `${origin}/a?start` };
      execFileSync("open", ["-g", "-n", "-i", fifo, "-o", "/dev/null", "--stderr", log,
        ...Object.entries(env).flatMap(([k, v]) => ["--env", `${k}=${v}`]), "-a", app, target]);
      it = { log, input, text: () => readFileSync(log, "utf8") };
      it.states = () => it.text().split("\n").filter((l) => l.includes(stateMarker)).map((l) => JSON.parse(l.slice(l.indexOf(stateMarker) + stateMarker.length)));
      it.pids = () => {
        const r = spawnSync("lsof", ["-t", log], { encoding: "utf8" });
        return r.stdout.split("\n").filter(Boolean).filter((pid) =>
          spawnSync("ps", ["-p", pid, "-o", "comm="], { encoding: "utf8" }).stdout.trim().endsWith("/Contents/MacOS/Ray"));
      };
      return it;
    };
    const cmd = async (line) => {
      const marker = `[ray-test] ${line} -> `;
      const from = it.text().length;
      writeSync(it.input, line + "\n");
      return until(`command ${line}`, () => {
        const text = it.text();
        const at = text.indexOf(marker, from);
        return at >= 0 ? text.slice(at + marker.length).split("\n")[0] : null;
      }, 20000);
    };
    const tail = () => it.text().split("\n").filter((l) => l.trim()).slice(-6).join(" | ").slice(-1500);
    const waitFor = async (what, fn) => {
      try { return await until(what, fn, 25000); } catch (error) { throw new Error(`${error.message}; its log: ${tail()}`); }
    };
    const stop = async () => {
      writeSync(it.input, "menu quit\n");
      await waitFor("instance quit", () => it.pids().length === 0);
      closeSync(it.input);
    };
    const settled = (part) => async () => {
      if ((await cmd("state")) !== "ok") return null;
      const s = it.states().at(-1);
      const tab = s?.tabs.find((t) => t.url.includes(part));
      return tab && s.active === tab.id && s;
    };
    try {
      // 1. A fresh profile, launched by a link: the link is the one tab, in place of the start page.
      start(`${origin}/b?launch=link`);
      let s = await waitFor("launch link active", settled("/b?launch=link"));
      const opens = otherAppOpens(it.text(), 0);
      assert(opens.length === 1 && opens[0].accepted === 1 && opens[0].kind === "links", `opens: ${JSON.stringify(opens)}`);
      assert(opens[0].queued, "the launch link arrived after the engine started (not queued for the first window)");
      assert(s.sidebar.today.length === 1, `Today after a link launch: ${s.sidebar.today.map((e) => e.url)}`);
      assert(!s.tabs.some((t) => t.url.includes("?start")), "the start page opened beside the launch link");
      assert(s.commandBar === null, "a new-tab command bar opened over the launch link");
      await sleep(800);
      await stop();

      // 2. The same profile, launched by an HTML file from Finder: the session comes back, the file opens on top.
      start(page);
      s = await waitFor("launch file active", settled("launch%20page.html"));
      const fileOpens = otherAppOpens(it.text(), 0);
      assert(fileOpens.length === 1 && fileOpens[0].kind === "documents" && fileOpens[0].queued, `opens: ${JSON.stringify(fileOpens)}`);
      const urls = s.sidebar.today.map((e) => e.url);
      assert(urls.some((u) => u.includes("/b?launch=link")), `the session didn't come back: ${urls}`);
      assert(urls.length === 2 && !s.tabs.some((t) => t.url.includes("?start")), `Today: ${urls}`);
      await stop();
      rmSync(dir, { recursive: true, force: true });
    } finally {
      for (const pid of it?.pids() ?? []) spawnSync("kill", ["-TERM", pid]);
    }
  },
  async "safe-storage-migration"() {
    // Ray 0.1's data, encrypted under the mock keychain's public key, moves to Ray's own key on the first launch
    // that leaves the mock keychain: cookies survive, the database stops opening with the mock key, and the move
    // happens once. The engine's file keychain (RAY_KEYCHAIN=file) stands in for the login keychain, so this never
    // touches the user's. Own instances on their own data dir, next to the main one.
    const dir = mkdtempSync(join(tmpdir(), "ray-safe-storage-"));
    const token = `t${process.pid}x${Date.now()}`;
    const running = [];
    const start = (env) => {
      let log = "";
      const proc = spawn(join(app, "Contents/MacOS/Ray"), [], {
        env: { ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_DATA_DIR: dir,
          RAY_DOWNLOADS_DIR: join(dir, "Downloads"), RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}.safe`, ...env },
        stdio: ["pipe", "ignore", "pipe"],
      });
      proc.stdin.on("error", () => {});
      proc.stderr.setEncoding("utf8");
      proc.stderr.on("data", (chunk) => (log += chunk));
      const it = { proc, log: () => log, exit: new Promise((r) => proc.on("exit", (code, signal) => r(code ?? signal))) };
      running.push(it);
      return it;
    };
    const stop = async (it) => {
      it.proc.stdin.write("menu quit\n");
      const code = await Promise.race([it.exit, sleep(15000).then(() => "timeout")]);
      assert(code !== "timeout", "a safe-storage instance didn't quit within 15 s");
    };
    // The first /safe-storage/ request after `mark`: a relaunch restores the last tab (/safe-storage/set) rather than
    // opening RAY_START_URL, and that request carries the cookies the engine read back from disk.
    const firstSince = (mark) => safeStorageRequests[mark];
    const keyOf = (password) => pbkdf2Sync(password, "saltysalt", 1003, 16, "sha1");
    const open = (hex, key) => {
      const value = Buffer.from(hex, "hex");
      if (value.subarray(0, 3).toString() !== "v10") return null;
      try {
        const decipher = createDecipheriv("aes-128-cbc", key, Buffer.alloc(16, " "));
        return Buffer.concat([decipher.update(value.subarray(3)), decipher.final()]).toString("latin1");
      } catch { return null; }
    };
    const cookieDB = join(dir, "Chromium/Default/Cookies");
    const stored = () => execFileSync("sqlite3", ["-readonly", cookieDB, "SELECT hex(encrypted_value) FROM cookies WHERE name = 'ray_safe'"], { encoding: "utf8" }).trim();
    // A failure names the instance's own last log lines (it isn't the main instance whose log the runner prints).
    const waitFor = async (what, it, fn) => {
      try { await until(what, fn, 20000); } catch (error) {
        throw new Error(`${error.message}; its log: ${it.log().split("\n").filter((l) => l.trim()).slice(-6).join(" | ").slice(-1500)}`);
      }
    };
    try {
      // 1. Ray 0.1: the mock keychain. A persistent cookie, written to disk when the instance quits.
      let mark = safeStorageRequests.length;
      const old = start({ RAY_START_URL: `${origin}/safe-storage/set?v=${token}` });
      await waitFor("cookie set", old, () => firstSince(mark));
      await sleep(500);
      await stop(old);
      const mockKey = keyOf("mock_password");
      assert(open(stored(), mockKey)?.endsWith(token), "the cookie isn't stored under the mock key to begin with");
      // 2. The move: the cookie comes back, now under the key in the (file) keychain only.
      mark = safeStorageRequests.length;
      const moved = start({ RAY_KEYCHAIN: "file" });
      await waitFor("page after the move", moved, () => firstSince(mark));
      assert(firstSince(mark).cookie.includes(`ray_safe=${token}`), `the cookie was lost in the move: ${JSON.stringify(firstSince(mark))}`);
      assert(/safe storage: keychain, migrated, [1-9]\d* values moved/.test(moved.log()), `no move logged: ${moved.log().match(/safe storage:.*/)?.[0]}`);
      await stop(moved);
      const password = readFileSync(join(dir, "Chromium/Test Safe Storage Key"));
      assert(password.length === 24, `keychain password is ${password.length} bytes`);
      const value = stored();
      assert(open(value, keyOf(password))?.endsWith(token), "the cookie isn't under Ray's key");
      assert(open(value, mockKey) === null, "the cookie still opens with the mock key");
      assert(existsSync(join(dir, "Chromium/Ray Safe Storage")), "no marker after the move");
      assert(existsSync(join(dir, "Safe Storage Migration/backup/Default/Cookies")), "no backup of the original");
      // 3. Once only.
      mark = safeStorageRequests.length;
      const again = start({ RAY_KEYCHAIN: "file" });
      await waitFor("page on the next launch", again, () => firstSince(mark));
      assert(firstSince(mark).cookie.includes(`ray_safe=${token}`), "the cookie was lost on the next launch");
      assert(/safe storage: keychain, ready, 0 values moved/.test(again.log()), `moved again: ${again.log().match(/safe storage:.*/)?.[0]}`);
      await stop(again);
      rmSync(dir, { recursive: true, force: true });
    } finally {
      for (const it of running) if (it.proc.exitCode === null && it.proc.signalCode === null) it.proc.kill("SIGKILL");
    }
  },
  async "settings-passwords"() {
    // Settings › Passwords on instances of its own whose engine answers the OS re-auth at once (RAY_REAUTH; no Touch ID
    // or password prompt, never the login keychain): locked by default, Unlock, the list, show and copy, add, edit and
    // delete, Export behind re-auth, CSV import, and no password, username or site in the state log or stderr.
    const hex = () => Math.random().toString(16).slice(2, 10);
    const secrets = [`Fx-${hex()}-"quoted"\\slash`, `Fx-${hex()}-second`, `Fx-${hex()}-third`, `Fx-${hex()}-csv`];
    const logins = [
      { origin: "https://login.fixture.test", username: "fixture.user@example.test", password: secrets[0] },
      { origin: "https://login.fixture.test", username: "fixture.renamed@example.test", password: secrets[1] },
      // Typed without a scheme, with a path: kept as https://accounts.fixture.test.
      { origin: "accounts.fixture.test/login", username: "second@example.test", password: secrets[2] },
    ];
    const env = { RAY_TEST_SECRETS: JSON.stringify({ logins }) };
    const pane = (s) => s.passwordsPane;
    const running = [];
    const files = mkdtempSync(join(tmpdir(), "ray-passwords-files-"));
    try {
      // Denied: Unlock with a password saved stays locked, and Export writes nothing.
      const denied = ownInstance("passwords-denied", { ...env, RAY_REAUTH: "denied" });
      running.push(denied);
      await until("window", async () => (await denied.cmd("state", 20000)) === "ok" && denied.states.length > 0, 25000);
      await denied.ok("settings open passwords");
      let s = await denied.until("passwords pane", (s) => s.settingsWindow.pane === "passwords");
      assert(pane(s).locked && pane(s).count === 0, `not locked at first: ${JSON.stringify(pane(s))}`);
      // With nothing saved the engine unlocks without asking (Chrome's rule), so a password can be added.
      await denied.ok("passwords unlock");
      await denied.until("unlocked (empty)", (s) => !pane(s).locked);
      await denied.ok("passwords add 0");
      await denied.until("one saved", (s) => pane(s).count === 1 && pane(s).last === "added");
      await denied.ok("passwords lock");
      s = await denied.until("locked", (s) => pane(s).locked);
      assert(pane(s).count === 0 && pane(s).shown === 0, `locking kept the list: ${JSON.stringify(pane(s))}`);
      await denied.ok("passwords unlock");
      s = await denied.until("unlock denied", (s) => pane(s).last === "denied");
      assert(pane(s).locked, "a denied Unlock unlocked");
      const deniedFile = join(files, "denied.csv");
      await denied.ok(`passwords export ${deniedFile}`);
      await denied.until("export warning", (s) => pane(s).confirming === "exportPasswords");
      await denied.ok("passwords confirm yes");
      await denied.until("export refused", (s) => pane(s).export === "reauthFailed");
      assert(!existsSync(deniedFile), "a denied export wrote the file");
      await denied.stop();

      // Granted.
      const it = ownInstance("passwords", { ...env, RAY_REAUTH: "granted" });
      running.push(it);
      await until("window", async () => (await it.cmd("state", 20000)) === "ok" && it.states.length > 0, 25000);
      await it.ok("settings open passwords");
      s = await it.until("passwords pane", (s) => s.settingsWindow.pane === "passwords");
      assert(pane(s).locked, "Passwords isn't locked at first");
      assert(s.settingsWindow.rows.passwords.join() === "offerToSaveLogins,passwords.saved,jumpCloudRelay,jumpCloudRelay.setup,passwords.more",
        `rows ${s.settingsWindow.rows.passwords}`);
      if (process.env.SNAP_DIR) await it.ok(`settings snap ${join(process.env.SNAP_DIR, "settings-passwords-locked.png")}`);
      await it.ok("passwords unlock");
      await it.until("unlocked", (s) => !pane(s).locked && pane(s).guardArmed);
      await it.ok("passwords add 0");
      await it.until("first added", (s) => pane(s).count === 1 && pane(s).last === "added");
      await it.ok("passwords add 2");
      s = await it.until("second added", (s) => pane(s).count === 2 && pane(s).last === "added");
      // A site already saved for that username isn't saved twice.
      await it.ok("passwords add 0");
      s = await it.until("duplicate refused", (s) => pane(s).formError && pane(s).adding);
      assert(pane(s).count === 2, "a duplicate was saved");
      await it.ok("passwords close");
      // Search: by site or username, every word.
      await it.ok("passwords search fixture.user");
      await it.until("search narrows", (s) => pane(s).shown === 1);
      await it.ok("passwords search nothing-like-it");
      await it.until("search empties", (s) => pane(s).shown === 0);
      await it.ok("passwords search");
      await it.until("search cleared", (s) => pane(s).shown === 2);
      // Sorted by site: accounts.fixture.test, then login.fixture.test.
      await it.ok("passwords open 1");
      await it.until("row open", (s) => pane(s).open === 1);
      assert((await it.cmd("passwords revealcheck 0")) === "hidden", "the password showed before Show");
      await it.ok("passwords reveal");
      await it.until("revealed", (s) => pane(s).revealed);
      assert((await it.cmd("passwords revealcheck 0")) === "match", "Show didn't show the saved password");
      if (process.env.SNAP_DIR) {
        await it.ok("passwords reveal");
        await it.until("hidden again", (s) => !pane(s).revealed);
        await sleep(200);
        await it.ok(`settings snap ${join(process.env.SNAP_DIR, "settings-passwords-unlocked.png")}`);
        await it.ok("passwords reveal");
        await it.until("revealed again", (s) => pane(s).revealed);
      }
      // Copy: the password concealed and cleared later (only if still there); the username plain.
      await it.ok("passwords copy password");
      let board = JSON.parse(await it.cmd("passwords pasteboard 0"));
      assert(board.password && board.concealed && board.clearPending, `copied password ${JSON.stringify(board)}`);
      await it.ok("passwords clearnow");
      board = JSON.parse(await it.cmd("passwords pasteboard 0"));
      assert(board.empty && !board.clearPending, `the password stayed on the pasteboard ${JSON.stringify(board)}`);
      await it.ok("passwords copy user");
      board = JSON.parse(await it.cmd("passwords pasteboard 0"));
      assert(board.username && !board.concealed && !board.clearPending, `copied username ${JSON.stringify(board)}`);
      // Edit: a new username and password.
      await it.ok("passwords edit 1");
      s = await it.until("edited", (s) => pane(s).last === "edited" && !pane(s).editing);
      assert(pane(s).count === 2 && !pane(s).revealed, `after the edit ${JSON.stringify(pane(s))}`);
      await it.ok("passwords reveal");
      await it.until("revealed after edit", (s) => pane(s).revealed);
      assert((await it.cmd("passwords revealcheck 1")) === "match", "the edit didn't change the password");
      // Delete asks first; Cancel keeps it.
      await it.ok("passwords remove");
      await it.until("delete asks", (s) => pane(s).confirming === "removePassword");
      await it.ok("passwords confirm no");
      s = await it.until("kept", (s) => pane(s).confirming === null);
      assert(pane(s).count === 2, "Cancel deleted it");
      await it.ok("passwords remove");
      await it.until("delete asks again", (s) => pane(s).confirming === "removePassword");
      await it.ok("passwords confirm yes");
      s = await it.until("deleted", (s) => pane(s).count === 1 && pane(s).last === "removed");
      assert(pane(s).open === -1 && !pane(s).revealed, "the deleted row stayed open");
      // Five idle minutes (fired now) lock it and forget the list; so does closing the window.
      await it.ok("passwords idle");
      s = await it.until("idle lock", (s) => pane(s).locked);
      assert(pane(s).count === 0 && !pane(s).guardArmed, `the idle lock kept something ${JSON.stringify(pane(s))}`);
      await it.ok("passwords unlock");
      await it.until("unlocked again", (s) => !pane(s).locked && pane(s).count === 1);
      await it.ok("settings close");
      s = await it.until("window closed", (s) => !s.settingsWindow.open);
      assert(pane(s).locked && pane(s).count === 0, "closing Settings left Passwords unlocked");
      // Export: a warning, then the engine's re-auth, then the file (whatever is saved, as plain text).
      await it.ok("settings open passwords");
      const exported = join(files, "Ray Passwords.csv");
      await it.ok(`passwords export ${exported}`);
      await it.until("export warning", (s) => pane(s).confirming === "exportPasswords" && pane(s).moreOpen);
      await it.ok("passwords confirm yes");
      await it.until("exported", (s) => pane(s).export === "succeeded");
      const csv = readFileSync(exported, "utf8");
      assert(/^name,url,username,password/.test(csv) && csv.includes(secrets[2]) && csv.includes("second@example.test"),
        "the export doesn't hold the saved password");
      rmSync(exported);
      // Import a CSV (Chrome's columns): a new login comes in, one already saved counts as there.
      const imported = join(files, "import.csv");
      writeFileSync(imported, `name,url,username,password,note\nfixture,https://csv.fixture.test/,csv@example.test,${secrets[3]},\n` +
        `accounts,https://accounts.fixture.test/,second@example.test,${secrets[2]},\n`);
      await it.ok(`passwords importcsv ${imported}`);
      s = await it.until("imported", (s) => !pane(s).importing && pane(s).imported.saved !== undefined);
      assert(pane(s).imported.saved === 1 && pane(s).imported.existing === 1, `import ${JSON.stringify(pane(s).imported)}`);
      await it.ok("passwords unlock");
      await it.until("imported login listed", (s) => !pane(s).locked && pane(s).count === 2);
      if (process.env.SNAP_DIR) await it.ok(`settings snap ${join(process.env.SNAP_DIR, "settings-passwords-more.png")}`);

      // Nothing secret anywhere in the logs: no password in stderr; no username or site in any state line.
      for (const each of [denied, it]) {
        // As written, and as JSON writes it (the state log escapes the quotes and the backslash).
        for (const secret of secrets) for (const form of [secret, JSON.stringify(secret).slice(1, -1)]) assert(!each.log.includes(form), "a password is in stderr");
        const logged = JSON.stringify(each.states.map((s) => ({ passwordsPane: s.passwordsPane, settingsWindow: s.settingsWindow })));
        for (const word of ["fixture.user", "fixture.renamed", "second@example", "csv@example", "fixture.test"])
          assert(!logged.includes(word), `the state log names "${word}"`);
      }
      // The hook that answers re-auth isn't in Ray.app at all (only RayTests.app passes --ray-background).
      assert(!readFileSync(join(root, "build/Ray.app/Contents/MacOS/Ray")).includes("--ray-background"), "Ray.app has the re-auth test hook");
      assert(readFileSync(join(app, "Contents/MacOS/Ray")).includes("--ray-background"), "the test app lost its re-auth hook");
      await it.stop();
    } finally {
      for (const it of running) if (it.proc.exitCode === null && it.proc.signalCode === null) it.proc.kill("SIGKILL");
      for (const it of running) rmSync(it.dir, { recursive: true, force: true });
      rmSync(files, { recursive: true, force: true });
    }
  },
  async "settings-autofill"() {
    // Settings › Autofill on instances of its own (RAY_REAUTH): addresses and cards added, edited and deleted (asked
    // first), a card's number shown only through the engine's re-auth, and no number, name or address in the logs.
    const number = "4242 4242 4242 4242";
    const fixtures = {
      addresses: [
        { name: "Fixture Person", street: "1 Fixture Way", city: "Testville", postalCode: "12345", country: "United States",
          phone: "+1 555 0100", email: "fixture.person@example.test" },
        { name: "Renamed Person" },
      ],
      cards: [
        { name: "Fixture Holder", number, month: 8, year: 2031 },
        { name: "Renamed Holder" },
        { name: "Bad Number", number: "4242 4242 4242 4241", month: 1, year: 30 },
      ],
    };
    const env = { RAY_TEST_SECRETS: JSON.stringify(fixtures) };
    const pane = (s) => s.autofillPane;
    const running = [];
    try {
      // Denied: the number stays hidden.
      const denied = ownInstance("autofill-denied", { ...env, RAY_REAUTH: "denied" });
      running.push(denied);
      await until("window", async () => (await denied.cmd("state", 20000)) === "ok" && denied.states.length > 0, 25000);
      await denied.ok("settings open autofill");
      await denied.until("autofill pane", (s) => s.settingsWindow.pane === "autofill");
      await denied.ok("autofill addcard 0");
      await denied.until("card added", (s) => pane(s).cards === 1);
      await denied.ok("autofill open card 0");
      await denied.ok("autofill reveal");
      let s = await denied.until("reveal denied", (s) => pane(s).lastCard === "denied");
      assert(!pane(s).revealed && (await denied.cmd("autofill revealcheck 0")) === "hidden", "a denied re-auth showed the number");
      await denied.stop();

      const it = ownInstance("autofill", { ...env, RAY_REAUTH: "granted" });
      running.push(it);
      await until("window", async () => (await it.cmd("state", 20000)) === "ok" && it.states.length > 0, 25000);
      await it.ok("settings open autofill");
      s = await it.until("autofill pane", (s) => s.settingsWindow.pane === "autofill");
      assert(pane(s).addresses === 0 && pane(s).cards === 0, `a new profile has autofill ${JSON.stringify(pane(s))}`);
      assert(s.settingsWindow.rows.autofill.join() === "autofillAddresses,autofillCards,autofill.addresses,autofill.cards",
        `rows ${s.settingsWindow.rows.autofill}`);
      // Addresses: add, edit, delete (asked first).
      await it.ok("autofill addaddress 0");
      s = await it.until("address added", (s) => pane(s).addresses === 1 && pane(s).lastAddress === "added");
      const addressId = pane(s).addressIds[0];
      await it.ok("autofill open address 0");
      await it.until("address open", (s) => pane(s).openAddress === addressId);
      await it.ok("autofill edit 1");
      s = await it.until("address edited", (s) => pane(s).lastAddress === "saved" && pane(s).openAddress === null);
      assert(pane(s).addresses === 1 && pane(s).addressIds[0] === addressId, `the edit added an address ${JSON.stringify(pane(s))}`);
      // Cards: add (a bad number refused), show through re-auth, copy, edit, delete.
      await it.ok("autofill addcard 2");
      s = await it.until("bad number refused", (s) => pane(s).formError && pane(s).addingCard);
      assert(pane(s).cards === 0, "a card with a bad number was saved");
      await it.ok("autofill close");
      await it.ok("autofill addcard 0");
      s = await it.until("card added", (s) => pane(s).cards === 1 && pane(s).lastCard === "added");
      const cardId = pane(s).cardIds[0];
      if (process.env.SNAP_DIR) {
        await it.ok("autofill close");
        await it.ok(`settings snap ${join(process.env.SNAP_DIR, "settings-autofill.png")}`);
        await it.ok("autofill open address 0");
        await it.until("address open again", (s) => pane(s).openAddress === addressId);
        await sleep(200);
        await it.ok(`settings snap ${join(process.env.SNAP_DIR, "settings-autofill-address.png")}`);
        await it.ok("autofill close");
      }
      await it.ok("autofill open card 0");
      await it.until("card open", (s) => pane(s).openCard === cardId);
      assert((await it.cmd("autofill revealcheck 0")) === "hidden", "the number showed before Show");
      await it.ok("autofill reveal");
      await it.until("number shown", (s) => pane(s).revealed);
      if (process.env.SNAP_DIR) {
        await it.ok("autofill reveal");
        await it.until("number hidden", (s) => !pane(s).revealed);
        await sleep(200);
        await it.ok(`settings snap ${join(process.env.SNAP_DIR, "settings-autofill-card.png")}`);
        await it.ok("autofill reveal");
        await it.until("number shown again", (s) => pane(s).revealed);
      }
      assert((await it.cmd("autofill revealcheck 0")) === "match", "Show didn't show the card's number");
      await it.ok("autofill copy");
      const board = JSON.parse(await it.cmd("autofill pasteboard 0"));
      assert(board.number && board.concealed && board.clearPending, `copied number ${JSON.stringify(board)}`);
      await it.ok("passwords clearnow");
      // Closing the window hides the number.
      await it.ok("settings close");
      s = await it.until("window closed", (s) => !s.settingsWindow.open);
      assert(!pane(s).revealed, "closing Settings left the card number showing");
      await it.ok("settings open autofill");
      await it.ok("autofill open card 0");
      await it.until("card open again", (s) => pane(s).openCard === cardId);
      await it.ok("autofill edit 1");
      s = await it.until("card edited", (s) => pane(s).lastCard === "saved" && !pane(s).editingCard);
      assert(pane(s).cards === 1 && pane(s).cardIds[0] === cardId, `the edit added a card ${JSON.stringify(pane(s))}`);
      await it.ok("autofill open card 0");
      await it.ok("autofill remove");
      await it.until("delete asks", (s) => pane(s).confirming === "removeCard");
      await it.ok("autofill confirm yes");
      await it.until("card deleted", (s) => pane(s).cards === 0 && pane(s).lastCard === "removed");
      await it.ok("autofill open address 0");
      await it.ok("autofill remove");
      await it.until("address delete asks", (s) => pane(s).confirming === "removeAddress");
      await it.ok("autofill confirm yes");
      await it.until("address deleted", (s) => pane(s).addresses === 0 && pane(s).lastAddress === "removed");

      for (const each of [denied, it]) {
        for (const secret of ["4242424242424242", number]) assert(!each.log.includes(secret), "a card number is in stderr");
        const logged = JSON.stringify(each.states.map((s) => s.autofillPane));
        for (const word of ["Fixture", "Renamed", "Testville", "fixture.person", "555"]) assert(!logged.includes(word), `the state log names "${word}"`);
      }
      await it.stop();
    } finally {
      for (const it of running) if (it.proc.exitCode === null && it.proc.signalCode === null) it.proc.kill("SIGKILL");
      for (const it of running) rmSync(it.dir, { recursive: true, force: true });
    }
  },
  async "import-browser"() {
    // ImportSession end to end on its own hidden instances: the importer's fixtures (Importer/fixtures/home) stand in
    // for ~/Library and the fixture secret for the Keychain (RAY_IMPORT_SECRET), so no real profile and no Keychain
    // is touched. Arc's sidebar comes into the sidebar; Chrome's history, bookmarks, passwords and cookies into the
    // engine.
    const support = join(root, "Importer/fixtures/home/Library/Application Support");
    const secret = JSON.parse(readFileSync(join(root, "Importer/fixtures/secrets.json"), "utf8")).chromiumSafeStorageSecret;
    const running = [];
    const start = (env) => {
      const dir = mkdtempSync(join(tmpdir(), "ray-import-"));
      const it = { dir, log: "", states: [], port: 9850 + Math.floor(Math.random() * 140) };
      let partial = "";
      it.proc = spawn(join(app, "Contents/MacOS/Ray"), [], {
        env: { ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_LOG_STATE: "1", RAY_DATA_DIR: dir,
          RAY_DOWNLOADS_DIR: join(dir, "Downloads"), RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}.import`,
          RAY_IMPORT_SOURCE_DIR: support, RAY_REMOTE_DEBUGGING_PORT: String(it.port), RAY_START_URL: `${origin}/b`, ...env },
        stdio: ["pipe", "ignore", "pipe"],
      });
      it.proc.stdin.on("error", () => {});
      it.proc.stderr.setEncoding("utf8");
      it.proc.stderr.on("data", (chunk) => {
        it.log += chunk;
        const lines = (partial + chunk).split("\n");
        partial = lines.pop();
        for (const line of lines) {
          const at = line.indexOf(stateMarker);
          if (at >= 0) it.states.push(JSON.parse(line.slice(at + stateMarker.length)));
        }
      });
      it.exit = new Promise((r) => it.proc.on("exit", (code, signal) => r(code ?? signal)));
      running.push(it);
      return it;
    };
    const tail = (it) => it.log.split("\n").filter((l) => l.trim()).slice(-6).join(" | ").slice(-1500);
    const cmd = async (it, line, ms = 15000) => {
      const marker = `[ray-test] ${line} -> `;
      const from = it.log.length;
      it.proc.stdin.write(line + "\n");
      try {
        return await until(`command ${line}`, () => {
          const at = it.log.indexOf(marker, from);
          return at >= 0 ? it.log.slice(at + marker.length).split("\n")[0] : null;
        }, ms);
      } catch (error) { throw new Error(`${error.message}; its log: ${tail(it)}`); }
    };
    const runImport = async (it, args) => {
      const from = it.states.length;
      const result = await cmd(it, `import ${args}`);
      assert(result === "ok", `import ${args}: ${result}`);
      const done = await until(`import ${args} done`, () => it.states.slice(from).find((s) => s.event === "import" && s.import?.done), 60000);
      return done;
    };
    const stop = async (it) => {
      it.proc.stdin.write("menu quit\n");
      const code = await Promise.race([it.exit, sleep(15000).then(() => "timeout")]);
      assert(code !== "timeout", "an import instance didn't quit within 15 s");
      rmSync(it.dir, { recursive: true, force: true });
    };
    try {
      const it = start({ RAY_IMPORT_SECRET: secret });
      await until("window", async () => (await cmd(it, "state", 20000)) === "ok" && it.states.length > 0, 25000);

      // Sources: Arc first and recommended, then by name; Safari (from the fixture home) as one profile.
      const sources = JSON.parse(await cmd(it, "importcheck sources"));
      assert(sources[0]?.id === "arc" && sources[0].recommended, `Arc isn't first: ${sources.map((s) => s.id)}`);
      assert(sources.filter((s) => s.recommended).length === 1, "more than one source recommended");
      const chrome = sources.find((s) => s.id === "chrome");
      assert(chrome?.profiles.join() === "Default,Profile 1", `Chrome's profiles: ${JSON.stringify(chrome)}`);
      assert(["history", "passwords", "cookies", "bookmarks"].every((i) => chrome.items.includes(i)), `Chrome's items: ${chrome.items}`);
      assert(!chrome.items.includes("favorites"), "Chrome offers favorites");
      const safari = sources.find((s) => s.id === "safari");
      if (safari) assert(safari.profiles.join() === "Default" && safari.note === null, `Safari: ${JSON.stringify(safari)}`);

      // Preview: counts without the key, and the one-line summary.
      const arcPreview = JSON.parse(await cmd(it, "importcheck preview arc Default"));
      assert(arcPreview.counts.pinnedTabs === 6 && arcPreview.counts.favorites === 3 && arcPreview.counts.openTabs === 2,
        `Arc's preview counts: ${JSON.stringify(arcPreview)}`);
      // The summary is one short line: the two most telling counts (spaces and pinned tabs for Arc; open tabs and
      // bookmarks for the rest), then the profiles.
      assert(arcPreview.summary === "2 spaces, 6 pinned tabs · 2 profiles", `Arc's summary: ${arcPreview.summary}`);
      const chromePreview = JSON.parse(await cmd(it, "importcheck preview chrome Default"));
      assert(chromePreview.counts.history > 2000 && chromePreview.counts.bookmarks > 0 && chromePreview.counts.passwords > 0
        && chromePreview.counts.cookies > 0, `Chrome's preview counts: ${JSON.stringify(chromePreview)}`);
      const plural = (n, word) => `${n.toLocaleString("en-US")} ${word}${n === 1 ? "" : "s"}`;
      const chromeLead = [[chromePreview.counts.openTabs, "open tab"], [chromePreview.counts.bookmarks, "bookmark"],
        [chromePreview.counts.pinnedTabs, "pinned tab"]].filter(([n]) => n > 0).slice(0, 2).map(([n, w]) => plural(n, w)).join(", ");
      assert(chromePreview.summary === `${chromeLead} · 2 profiles`, `Chrome's summary: ${chromePreview.summary} (want ${chromeLead} · 2 profiles)`);

      // Arc: favorites, each space's pinned tabs in a folder named after it (two spaces), Today's tabs.
      const arc = await runImport(it, "arc Default pinnedTabs,favorites,openTabs");
      assert(JSON.stringify(arc.import.failed) === "{}", `Arc import failed: ${JSON.stringify(arc.import.failed)}`);
      assert(arc.import.imported.pinnedTabs === 6 && arc.import.imported.favorites === 3 && arc.import.imported.openTabs === 2,
        `Arc imported: ${JSON.stringify(arc.import.imported)}`);
      assert(JSON.stringify(arc.import.existing) === "{}", `Arc found tabs already in a new sidebar: ${JSON.stringify(arc.import.existing)}`);
      const sidebar = arc.sidebar;
      // The same again: nothing comes in twice, and the import says they were already here (not "0").
      const again = await runImport(it, "arc Default pinnedTabs,favorites,openTabs");
      assert(again.import.imported.pinnedTabs === 0 && again.import.imported.favorites === 0 && again.import.imported.openTabs === 0
        && again.import.existing.pinnedTabs === 6 && again.import.existing.favorites === 3 && again.import.existing.openTabs === 2,
        `Arc again: ${JSON.stringify(again.import)}`);
      assert(again.import.events.some((e) => e.finished === "pinnedTabs" && e.count === 0 && e.existing === 6), `events ${JSON.stringify(again.import.events)}`);
      assert(["favorites", "pinned", "today"].every((k) => again.sidebar[k].length === sidebar[k].length), "the second Arc import added tabs");
      assert(sidebar.favorites.map((e) => e.pinnedURL).join() === "https://mail.example.com/,https://music.example/,https://maps.example/",
        `favorites: ${sidebar.favorites.map((e) => e.pinnedURL)}`);
      const folder = (title) => sidebar.pinned.find((e) => e.kind === "folder" && e.title === title);
      const personal = folder("Personal");
      assert(personal && folder("Space 1"), `space folders: ${sidebar.pinned.filter((e) => e.kind === "folder").map((e) => e.title)}`);
      assert(folder("Reading")?.parent === personal.id && folder("Later")?.parent === folder("Reading").id, "Arc's nested folders didn't come over");
      const cal = sidebar.pinned.find((e) => e.pinnedURL === "https://calendar.example/");
      assert(cal?.title === "Cal" && cal.parent === personal.id && cal.live === false, `Arc's renamed pinned tab: ${JSON.stringify(cal)}`);
      // Arc's names stay names (the page's own title stays its title): Rename shows them, and clearing brings the title back.
      assert(cal.customTitle === "Cal" && cal.pageTitle === "Calendar – Week of Sep 1", `Arc's name: ${JSON.stringify(cal)}`);
      const tunes = sidebar.favorites.find((e) => e.pinnedURL === "https://music.example/");
      assert(tunes?.customTitle === "Tunes" && tunes.pageTitle === "Music", `Arc's favorite name: ${JSON.stringify(tunes)}`);
      const renamedToday = sidebar.today.find((e) => e.url === "https://today2.example/");
      assert(renamedToday?.customTitle === "Renamed today" && renamedToday.pageTitle === "Another today", `Arc's Today name: ${JSON.stringify(renamedToday)}`);
      assert(sidebar.pinned.every((e) => e.kind === "folder" || e.pinnedURL === "https://calendar.example/" || e.customTitle === null),
        `names on tabs Arc never renamed: ${JSON.stringify(sidebar.pinned.filter((e) => e.customTitle))}`);
      assert(sidebar.today.some((e) => e.pinnedURL === null && e.url === "https://today2.example/" && e.title === "Renamed today"),
        `Today: ${JSON.stringify(sidebar.today.map((e) => [e.url, e.title]))}`);

      // Chrome: everything; the key comes from the fixture secret.
      const all = "pinnedTabs,openTabs,history,bookmarks,passwords,cookies,autofill,extensions";
      const result = await runImport(it, `chrome Default ${all}`);
      const { imported, failed, events } = result.import;
      assert(JSON.stringify(failed) === "{}", `Chrome import failed: ${JSON.stringify(failed)}`);
      assert(imported.history > 2000 && imported.bookmarks > 0 && imported.passwords >= 2 && imported.cookies >= 3,
        `Chrome imported: ${JSON.stringify(imported)}`);
      assert(imported.extensions === 0, "extensions were installed");
      for (const item of all.split(",")) {
        const started = events.findIndex((e) => e.started === item);
        const ended = events.findIndex((e) => e.finished === item || e.failed === item);
        assert(started >= 0 && ended > started, `${item}: events ${JSON.stringify(events)}`);
      }
      // Chrome's pinned Mail is Arc's favorite already: never twice, and counted as already here.
      assert(result.import.existing.pinnedTabs >= 1, `Chrome's Mail not counted as already here: ${JSON.stringify(result.import.existing)}`);
      const everywhere = ["favorites", "pinned", "today"].flatMap((k) => result.sidebar[k]);
      assert(everywhere.filter((e) => e.url === "https://mail.example.com/").length === 1, "a tab came in twice");
      assert(result.sidebar.today.some((e) => e.url === "https://docs.example.com/"), "Chrome's open tabs aren't in Today");
      assert(!everywhere.some((e) => !/^https?:/.test(e.url) && e.kind !== "folder"), "a non-web address reached the sidebar");

      // In the engine: history, passwords (never shown), bookmarks (no bookmarklets), cookies.
      const history = JSON.parse(await cmd(it, "importcheck history https://newest.example/"));
      assert(history.has && history.count > 2000, `history: ${JSON.stringify(history)}`);
      const passwords = JSON.parse(await cmd(it, "importcheck passwords"));
      assert(passwords.some((p) => p.origin === "https://accounts.example.com" && p.username === "alex@example.com"),
        `passwords: ${JSON.stringify(passwords)}`);
      assert(!passwords.some((p) => p.origin.startsWith("android")), "an app login came in as a website's");
      const tree = await cmd(it, "importcheck bookmarks");
      const bar = JSON.parse(tree).bar;
      const importedFolder = bar.c.find((n) => n.t === "Imported from Google Chrome");
      assert(importedFolder?.c.some((n) => n.u === "https://ardia.example/"), `bookmarks bar: ${tree.slice(0, 400)}`);
      assert(!tree.includes("javascript:"), "a bookmarklet was imported");
      const version = await (await fetch(`http://127.0.0.1:${it.port}/json/version`)).json();
      const socket = new WebSocket(version.webSocketDebuggerUrl);
      await new Promise((r, j) => ((socket.onopen = r), (socket.onerror = j)));
      const cookies = await new Promise((resolve, reject) => {
        socket.onmessage = (m) => { const msg = JSON.parse(m.data); if (msg.id === 1) msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result.cookies); };
        socket.send(JSON.stringify({ id: 1, method: "Storage.getCookies" }));
      });
      socket.close();
      const sid = cookies.find((c) => c.name === "sid" && c.domain === ".example.com");
      assert(sid?.value === "s3ss10n" && sid.secure, `the fixture cookie: ${JSON.stringify(sid)}`);
      // No secret reaches the log.
      for (const value of ["s3ss10n", "correct horse", secret])
        assert(!it.log.includes(value), "a secret is in the log");
      await stop(it);

      // Without the key (the Keychain prompt denied): passwords and cookies fail, the rest comes in.
      const denied = start({});
      await until("window", async () => (await cmd(denied, "state", 20000)) === "ok" && denied.states.length > 0, 25000);
      const partial = await runImport(denied, "chrome Default history,passwords,cookies");
      assert(partial.import.imported.history > 2000,`history without the key: ${JSON.stringify(partial.import)}`);
      assert(partial.import.failed.passwords && partial.import.failed.cookies && !partial.import.failed.history,
        `failures without the key: ${JSON.stringify(partial.import.failed)}`);
      await stop(denied);
    } finally {
      for (const it of running) if (it.proc.exitCode === null && it.proc.signalCode === null) it.proc.kill("SIGKILL");
    }
  },
  async "test-app-needs-data-dir"() {
    // A test instance with no (or an empty) RAY_DATA_DIR must refuse to start rather than open the user's profile.
    // CFFIXED_USER_HOME points the home folder at a scratch dir, so even a regression here can't reach real data.
    const home = mkdtempSync(join(tmpdir(), "ray-nohome-"));
    for (const value of [undefined, ""]) {
      const env = { ...process.env, CFFIXED_USER_HOME: home, RAY_BACKGROUND: "1" };
      delete env.RAY_DATA_DIR;
      if (value !== undefined) env.RAY_DATA_DIR = value;
      const result = spawnSync(join(app, "Contents/MacOS/Ray"), [], { env, encoding: "utf8", timeout: 15000 });
      assert(result.status === 2, `test app started without RAY_DATA_DIR=${JSON.stringify(value)} (status ${result.status})`);
      assert(/needs RAY_DATA_DIR/.test(result.stderr), `no refusal message: ${result.stderr.slice(0, 200)}`);
    }
    assert(!existsSync(join(home, "Library/Application Support/Ray")), "the test app made a profile in the home folder");
  },
  async "page-toolbar"() {
    // The address bar above the page shows host and path, and View › Show Address Bar on Page turns it off.
    const entryFor = (tabId) => ["favorites", "pinned", "today"].flatMap((k) => state().sidebar[k]).find((e) => e.tab === tabId);
    await command(`row ${entryFor(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    await until("address", async () => { await command("state"); return state().toolbar?.address === origin.replace("http://", "") + "/a"; });
    if (process.env.SNAP_DIR) {
      await command(`toolbarsnap ${join(process.env.SNAP_DIR, "toolbar.png")}`);
      await command("menu toggleSidebar");
      // The buttons ride the sidebar's spring, which only ticks while the window is on screen.
      await until("sidebar hidden", async () => { await command("state"); return state().sidebar.hidden; });
      await sleep(400);
      await command(`toolbarsnap ${join(process.env.SNAP_DIR, "toolbar-sidebar-hidden.png")}`);
      await command("menu toggleSidebar");
      await until("sidebar back", async () => { await command("state"); return !state().sidebar.hidden; });
    }
    // A plain-http page on the user's own machine gets no warning in either address field, and both centre the text.
    for (const [name, field] of [["toolbar", state().toolbar.field], ["sidebar", state().addressField]]) {
      assert(field.look === "local" && field.icon === false, `${name} field warns on a local page: ${JSON.stringify(field)}`);
      assert(Math.abs(field.textOffset) <= 0.5, `${name} text is ${field.textOffset} pt off the middle`);
    }
    // The full address by default (host, then path in grey); View › Show Full Address off leaves the host alone.
    assert(state().toolbar.field.shown === origin.replace("http://", "") + "/a", `the bar shows ${state().toolbar.field.shown}`);
    await command("menu toggleFullAddress");
    await until("host only", async () => { await command("state"); return state().toolbar.field.shown === origin.replace("http://", ""); });
    await command("menu toggleFullAddress");
    await until("full again", async () => { await command("state"); return state().toolbar.field.shown.endsWith("/a"); });
    const cardTop = () => { const [, y, , h] = state().cardFrame.match(/-?[\d.]+/g).map(Number); return y + h; };
    const withBar = cardTop();
    // Docked beside the page's bar, the sidebar drops its own address field; without the bar it has one again.
    assert(state().sidebarAddressShown === false, "the docked sidebar repeats the address beside the page's bar");
    await command("menu toggleToolbar");
    await until("bar off", async () => { await command("state"); return state().toolbar === null; });
    assert(cardTop() > withBar, `the page didn't grow into the bar's room (${withBar} -> ${cardTop()})`);
    assert(state().sidebarAddressShown === true, "no address field anywhere with the page's bar off");
    await command("menu toggleToolbar");
    await until("bar on", async () => { await command("state"); return state().toolbar !== null; });
    // Peeking, the sidebar covers the bar's address, so it shows its own.
    await command("menu toggleSidebar");
    await until("sidebar hidden", async () => { await command("state"); return state().sidebar.hidden; });
    await command("peek on");
    await until("peeking", async () => { await command("state"); return state().sidebar.peeking; });
    assert(state().sidebarAddressShown === true, "a peeking sidebar has no address field");
    await command("peek off");
    await until("peek ended", async () => { await command("state"); return !state().sidebar.peeking; });
    await command("menu toggleSidebar");
    await until("sidebar back", async () => { await command("state"); return !state().sidebar.hidden && state().sidebarAddressShown === false; });
  },
  async "page-loading"() {
    // The address bar shows the load as a wash filling the field, and its reload button is a stop button meanwhile.
    const entryFor = (tabId) => ["favorites", "pinned", "today"].flatMap((k) => state().sidebar[k]).find((e) => e.tab === tabId);
    const field = () => state().toolbar.field;
    const loadSlow = async (tag) => {
      const from = states.length;
      await command("menu focusAddress");
      await command(`type ${origin}/slow?${tag}`);
      await command("enter");
      // Every state the log wrote during the load (loading and progress changes each write one).
      const seen = () => states.slice(from).filter((s) => s.toolbar?.field);
      return { seen, loading: await until("loading", () => seen().find((s) => s.toolbar.field.loading), 5000, 25) };
    };
    const aId = tabFor("/a").id;
    await command(`row ${entryFor(aId).id}`);
    await until("/a active", () => state().active === aId);
    await until("not loading", async () => { await command("state"); return field().loading === false; });
    assert(field().stopButton === false && field().wash === false, `the idle bar shows a load: ${JSON.stringify(field())}`);

    // Stop: the button is an ✕ while loading, and pressing it ends the load.
    const first = await loadSlow("stop");
    assert(first.loading.toolbar.field.stopButton === true, "the reload button isn't a stop button while loading");
    assert(first.loading.toolbar.field.wash === true, "no wash while loading");
    // One indicator: the page's own thin line stays off while the address bar shows the load.
    assert(!first.seen().some((s) => s.pages?.progressLine), "the page's own load line showed under the address bar");
    if (process.env.SNAP_DIR) await command(`toolbarsnap ${join(process.env.SNAP_DIR, "toolbar-loading.png")}`);
    await until("progress between 0 and 1", () => first.seen().find((s) => s.toolbar.field.loading && s.toolbar.field.progress > 0 && s.toolbar.field.progress < 1), 3000, 25);
    await command("toolbarreload");
    await until("stopped", async () => { await command("state"); return field().loading === false; }, 3000);
    assert(field().stopButton === false, "the stop button stayed after the load stopped");
    assert(field().wash === false, "the wash stayed after the load stopped");

    // A load that finishes by itself: steps came in one by one, then the wash is gone and the button is reload again.
    const second = await loadSlow("done");
    await until("loaded", async () => { await command("state"); return field().loading === false; }, 8000);
    assert(second.seen().some((s) => s.toolbar.field.loading && s.toolbar.field.progress < 1), "progress never showed mid-load");
    assert(field().progressSteps >= 2, `fewer than two progress steps were drawn (${field().progressSteps})`);
    assert(field().wash === false, "the wash stayed after the page loaded");
    // The fade only ticks while the window is on screen.
    if (state().windowVisibleOnScreen !== false) await until("wash faded", async () => { await command("state"); return field().washFinishing === false; }, 3000);
    assert(field().stopButton === false, "the stop button stayed after the page loaded");

    // Another tab shows its own state at once: nothing from the loading tab leaks into it, and back again.
    if (!tabFor("/b")) {
      await command("menu newTab");
      await command(`type ${origin}/b`);
      await command("enter");
      await until("/b open", () => tabFor("/b"));
    }
    await command(`row ${entryFor(aId).id}`);
    await until("/a active again", () => state().active === aId);
    await loadSlow("switch");
    await command(`row ${entryFor(tabFor("/b").id).id}`);
    await command("state");
    assert(field().loading === false && field().wash === false && field().stopButton === false,
      `the other tab shows the loading tab's state: ${JSON.stringify(field())}`);
    await command(`row ${entryFor(aId).id}`);
    await command("state");
    assert(field().loading === true && field().wash === true && field().stopButton === true,
      `switching back lost the load: ${JSON.stringify(field())}`);
    await until("switched load finished", async () => { await command("state"); return field().loading === false; }, 8000);
    // Leave the tab on /a for the checks after this one.
    await command("menu focusAddress");
    await command(`type ${origin}/a`);
    await command("enter");
    await until("/a again", () => tabFor("/a"));
  },
  async "load-sweep-once"() {
    // One main-frame navigation, one sweep. Chrome counts the tab as loading while any frame loads and puts its
    // progress back to 0.1 when one starts: a frame during the load mustn't restart the sweep, and frames or
    // same-page navigations after it mustn't start another. A navigation the page starts itself gets its own.
    const field = () => state().toolbar.field;
    await command("state");
    const before = field().sweeps;
    const from = states.length;
    const seen = () => states.slice(from).filter((s) => s.toolbar?.field);
    // Loading periods so far: [{ start, end }] as indexes into seen().
    const periods = () => {
      const list = [];
      seen().forEach((s, i) => {
        const open = list.at(-1) && list.at(-1).end === undefined;
        if (s.toolbar.field.loading && !open) list.push({ start: i });
        if (!s.toolbar.field.loading && open) list.at(-1).end = i;
      });
      return list;
    };
    if (process.env.WASH_SHOTS) await command(`fieldburst 75 33 ${join(process.env.WASH_SHOTS, "late-frames")}`);
    await goTo(`${origin}/late-frames`);
    await until("page loaded", () => periods()[0]?.end !== undefined, 8000, 25);
    const first = periods()[0];
    const during = seen().slice(first.start, first.end);
    assert(during[0].toolbar.field.wash === true, "no sweep from the start of a load the user started");
    const fractions = during.map((s) => s.toolbar.field.washFraction);
    assert(fractions.every((f, i) => i === 0 || f >= fractions[i - 1]), `the sweep went backwards: ${fractions.join(" ")}`);
    // The frame it adds afterwards: the tab loads again, the field stays quiet.
    await until("late frame loading", () => periods().length >= 2, 5000, 25);
    await until("late frame loaded", () => periods().at(-1).end !== undefined, 8000, 25);
    await command("state");
    const after = seen().slice(first.end);
    assert(!after.some((s) => s.toolbar.field.wash), "a frame loading after the page drew a sweep");
    assert(field().sweeps - before === 1, `one navigation drew ${field().sweeps - before} sweeps`);
    // A link the page follows by itself (not through Ray): its own sweep, from when the new page commits.
    const page = await session("late-frames");
    const fromLink = states.length;
    await evaluate(page.sessionId, `document.getElementById("next").click()`);
    await until("followed link loaded", async () => { await command("state"); return tabFor("/slow?linked") && field().loading === false; }, 8000);
    assert(states.slice(fromLink).some((s) => s.toolbar?.field?.wash), "no sweep for a link the page followed");
    assert(field().sweeps - before === 2, `a followed link drew ${field().sweeps - before - 1} sweeps`);
    if (process.env.WASH_SHOTS) {
      // A plain slow load too, for the frame strip.
      await command(`fieldburst 75 33 ${join(process.env.WASH_SHOTS, "slow")}`);
      await goTo(`${origin}/slow?shots`);
      await until("shots loaded", async () => { await command("state"); return tabFor("/slow?shots") && field().loading === false; }, 8000);
      await sleep(1500);
    }
    // Leave the tab on /a for the checks after this one.
    await goTo(`${origin}/a`);
    await until("/a again", () => tabFor("/a"));
  },
  async "site-controls"() {
    // The sliders button's panel: the site is the engine's committed origin, permissions go through the engine,
    // and a tile, Escape or a tab switch closes it.
    const entryFor = (tabId) => ["favorites", "pinned", "today"].flatMap((k) => state().sidebar[k]).find((e) => e.tab === tabId);
    await command(`row ${entryFor(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    const panel = () => state().siteControls;
    const open = async () => {
      await command("menu toggleSiteControls");
      await until("panel open", async () => { await command("state"); return panel() !== null; });
    };
    const setting = (title) => panel()?.settings.find((s) => s.title === title)?.value;
    await open();
    assert(panel().origin === origin, `panel's site is ${panel().origin}`);
    assert(panel().security === "Local", `a page on this machine says ${panel().security}`);
    assert(panel().tiles.join() === "share,copyLink,find,cast", `tiles ${panel().tiles}`);
    await until("pop-ups row", async () => { await command("state"); return setting("Pop-ups and Redirects") === "Blocked"; });
    if (process.env.SNAP_DIR) await command(`sitesnap ${join(process.env.SNAP_DIR, "site-controls.png")}`);
    await command("site set camera allow");
    await until("camera allowed", async () => { await command("state"); return setting("Camera") === "Allowed"; });
    await command("site set camera default");
    await until("camera back to default", async () => { await command("state"); return setting("Camera") === undefined; });
    await command("site press copyLink");
    await until("copied, panel gone", async () => { await command("state"); return panel() === null && state().pasteboard === `${origin}/a`; });
    await open();
    await command("key esc keywin");
    await until("escape closes", async () => { await command("state"); return panel() === null; });
    if (!tabFor("/b")) {
      await command("menu newTab");
      await command(`type ${origin}/b`);
      await command("enter");
      await until("/b open", () => tabFor("/b"));
    }
    await command(`row ${entryFor(tabFor("/a").id).id}`);
    await until("/a active again", () => state().active === tabFor("/a").id);
    await open();
    await command(`row ${entryFor(tabFor("/b").id).id}`);
    await until("tab switch closes", async () => { await command("state"); return panel() === null; });
    await command(`row ${entryFor(tabFor("/a").id).id}`);
  },
  async "copy-url"() {
    const url = state().sidebar[["favorites", "pinned", "today"].find((k) => state().sidebar[k].some((e) => e.id === state().activeEntry))]
      .find((e) => e.id === state().activeEntry).url;
    await command("key c cmd shift");
    await until("copied", () => state().pasteboard === url);
    assert(state().toast === "Copied Current URL", `toast says ${state().toast}`);
    assert(state().toastTruncated === false, "the toast cut its message short");
    await until("toast gone", async () => { await command("state"); return state().toast === ""; }, 5000);
  },
  async "page-commands"() {
    // The basics from Chrome's menus: zoom keys, View Source, History, Clear Browsing Data, Save Page As, Print.
    await resetSettings();
    await goTo(`${origin}/b?commands`, true);
    await until("page", async () => { await command("state"); return activeTabState()?.url.endsWith("/b?commands") && activeTabState()?.title === "Page B"; });
    const page = state().active;
    // ⌘= and ⌘− step once each (the menu's, never the engine's as well), ⌘0 goes back to the default.
    const zoomTo = async (keys, want, what) => {
      await command(`key ${keys} keywin`);
      await until(what, async () => { await command("state"); return near(activeZoom(), want); }, 4000);
      await sleep(300);
      await command("state");
      assert(near(activeZoom(), want), `${what}: zoom ${activeZoom()}, wanted ${want}`);
    };
    await zoomTo("= cmd", 1.1, "⌘=");
    // Arc's zoom level at the top right of the page, after a zoom you asked for.
    assert(state().toast === "110%" && state().toastTruncated === false, `zoom indicator says ${JSON.stringify(state().toast)}`);
    await zoomTo("- cmd", 1, "⌘−");
    await zoomTo("= cmd", 1.1, "⌘= again");
    await zoomTo("= cmd", 1.25, "⌘= twice");
    await zoomTo("0 cmd", 1, "⌘0");
    assert(state().toast === "100%", `after ⌘0 the indicator says ${JSON.stringify(state().toast)}`);
    // A navigation settling the default zoom isn't a zoom you asked for: no indicator.
    await until("indicator gone", async () => { await command("state"); return state().toast === ""; }, 5000);
    await setSetting("defaultZoom", "1.25");
    await until("default applied", async () => { await command("state"); return near(activeZoom(), 1.25); });
    await sleep(400);
    await command("state");
    assert(state().toast === "", `changing the default showed ${JSON.stringify(state().toast)}`);
    await setSetting("defaultZoom", "1");
    await until("default back", async () => { await command("state"); return near(activeZoom(), 1); });
    // View Source (⌥⌘U): the page's source in a new tab, not for Chrome's own pages.
    await command("key u cmd opt keywin");
    await until("source tab", async () => { await command("state"); return activeTabState()?.url === `view-source:${origin}/b?commands`; });
    await command("menu closeTab");
    await until("back on the page", async () => { await command("state"); return state().active === page; });
    // Show Full History (⌘Y): Chrome's history page; again, the same tab rather than another.
    await command("key y cmd keywin");
    await until("history", async () => { await command("state"); return activeTabState()?.url.startsWith("chrome://history"); });
    const history = state().active;
    const tabs = state().tabs.length;
    await command(`row ${entryOfTab(page).id}`);
    await until("page again", async () => { await command("state"); return state().active === page; });
    await command("key y cmd keywin");
    await until("history again", async () => { await command("state"); return state().active === history; });
    assert(state().tabs.length === tabs, `⌘Y opened a second history tab (${state().tabs.length} tabs, was ${tabs})`);
    await command("menu viewSource");
    await sleep(300);
    await command("state");
    assert(state().active === history && state().tabs.length === tabs, "View Source opened Chrome's own page's source");
    await command("menu closeTab");
    // Clear Browsing Data (⇧⌘⌫): Chrome's dialog over its settings page.
    await command("menu clearBrowsingData");
    await until("clear data", async () => { await command("state"); return activeTabState()?.url === "chrome://settings/clearBrowserData"; });
    await command("menu closeTab");
    // Save Page As takes ⌘S only when Settings gives ⌘S back from the sidebar.
    await command("state");
    assert(state().menuKeys.savePage === "" && state().menuKeys.toggleSidebar === "s", `⌘S: ${JSON.stringify(state().menuKeys)}`);
    await setSetting("sidebarShortcut", "off");
    assert(state().menuKeys.savePage === "s" && state().menuKeys.toggleSidebar === "", `⌘S freed: ${JSON.stringify(state().menuKeys)}`);
    await setSetting("sidebarShortcut", "on");
    // Print (⌘P): Chrome's print preview over the page; Escape closes it.
    await command(`row ${entryOfTab(page).id}`);
    await until("page for printing", async () => { await command("state"); return state().active === page; });
    await command("key p cmd keywin");
    await until("print command", async () => { await command("state"); return state().chromeCommand?.name === "print"; });
    assert(state().chromeCommand.ran === true, "the engine didn't take Print");
    await until("print preview", async () => (await targets()).some((t) => t.url.startsWith("chrome://print")), 8000);
    // Centred on the page both ways, as Arc and Dia show it (Chrome hangs it from the top of the page).
    const rect = (text) => text.match(/-?[\d.]+/g).map(Number);
    const [wx, wy] = rect(state().windowFrame);
    const [, toolbarY] = rect(state().toolbar.frame);
    const [, , pageWidth, pageHeight] = rect(state().pages.pageFrame);
    const [toolbarX] = rect(state().toolbar.frame);
    let dialog;
    await until("print preview window", async () => { dialog = JSON.parse(await commandResult("dialogs"))[0]; return dialog; });
    const [dx, dy, dw, dh] = rect(dialog);
    const pageMidY = wy + toolbarY - pageHeight / 2, pageMidX = wx + toolbarX + pageWidth / 2;
    assert(Math.abs(dy + dh / 2 - pageMidY) <= 2 && Math.abs(dx + dw / 2 - pageMidX) <= 2,
      `print preview at ${dialog}, page centre (${pageMidX}, ${pageMidY})`);
    // Its Cancel button closes it (a real click on the dialog's own control).
    const preview = await session("chrome://print");
    const deepFind = `const deep = (root, sel, out = []) => { for (const el of root.querySelectorAll("*")) if (el.shadowRoot) deep(el.shadowRoot, sel, out); root.querySelectorAll(sel).forEach((e) => out.push(e)); return out; };`;
    await until("cancel button", async () => (await evaluate(preview.sessionId, `(() => { ${deepFind} return deep(document, "cr-button.cancel-button").length; })()`)) > 0, 8000);
    await evaluate(preview.sessionId, `(() => { ${deepFind} deep(document, "cr-button.cancel-button")[0].click(); })()`);
    await until("print preview closed", async () => !(await targets()).some((t) => t.url.startsWith("chrome://print")), 8000);
    await command("menu closeTab");
  },
  // Settings window and the settings behind it. Each check puts every setting back to its default.
  async "settings-window"() {
    await resetSettings();
    await command("menu showSettings");
    await until("settings window", async () => { await command("state"); return state().settingsWindow.open; });
    const win = () => state().settingsWindow;
    const c = () => win().controls;
    // ⌘, opens General the first time (later, the pane last shown).
    assert(win().title === "Settings" && win().pane === "general", `window ${JSON.stringify(win())}`);
    assert(state().menuKeys.settings === ",", `Settings… answers to ${state().menuKeys.settings}`);
    const [, , width, height] = win().frame.match(/-?[\d.]+/g).map(Number);
    assert(width === 780 && height >= 560 && height < 620, `the window is ${width} x ${height}`);
    // The defaults, as the controls show them.
    assert(c().minimalURL === false && c().loadingProgress === true && c().newTabNextToActive === "At the top" &&
      c().recentTabCycling === true && c().copyLinkShortcut === true && c().sidebarShortcut === true, `switches ${JSON.stringify(c())}`);
    assert(c().defaultZoom === "100%" && c().defaultZoomOptions.length === 17 && c().defaultZoomOptions[0] === "25%" && c().defaultZoomOptions.at(-1) === "500%", `zoom ${c().defaultZoomOptions}`);
    assert(c().theme === "default" && c().themeSwatches === 9 && c().themeSelected === 0, `swatches ${c().theme} ${c().themeSwatches} ${c().themeSelected}`);
    assert(c().allSettingsLink === "All Chrome Settings…", `link ${c().allSettingsLink}`);
    // A control changes the setting, and a setting changed anywhere else shows in the control.
    await command("settings press minimalURL");
    await until("switch changed the setting", async () => { await command("state"); return state().settings.minimalURL === true; });
    await setSetting("minimalURL", "off");
    await until("control follows the setting", async () => { await command("state"); return c().minimalURL === false; });
    await command("settings press theme 3");
    await until("swatch chose Green", async () => { await command("state"); return state().settings.theme.setting === "#3EA64A" && c().themeSelected === 3; });
    await command("settings press defaultZoom 9");
    await until("popup chose 125%", async () => { await command("state"); return state().settings.defaultZoom === 1.25 && c().defaultZoom === "125%"; });
    await setSetting("defaultZoom", "1");
    await resetSettings();
    // Only one window, however it's opened.
    await command("menu showSettings");
    await command("settings open");
    await command("state");
    assert(win().windows === 1, `${win().windows} Settings windows`);
    if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "settings.png")}`);
    await closeSettingsWindow();
    // Its frame is remembered, in Settings.json next to Sidebar.json.
    const file = join(dataDir, "Settings.json");
    await until("frame saved", () => existsSync(file) && JSON.parse(readFileSync(file, "utf8")).windowFrame, 4000);
  },
  async "settings-catalog"() {
    // Every setting in the catalog (Host/SettingsCatalog.swift), with nothing per setting here: `setting <id> <value>`
    // round-trips its samples, refuses bad values and takes `default`; the state log shows it; and an instance of its
    // own on a Settings.json full of garbage falls back to every default, keeping the keys it doesn't know.
    await resetSettings();
    const catalog = async () => JSON.parse(await commandResult("settings catalog"));
    const keys = await catalog();
    assert(new Set(keys.map((k) => k.id)).size === keys.length, `ids repeat: ${keys.map((k) => k.id)}`);
    for (const id of ["minimalURL", "loadingProgress", "theme", "defaultZoom", "newTabNextToActive", "recentTabCycling",
      "copyLinkShortcut", "sidebarShortcut"]) assert(keys.some((k) => k.id === id), `${id} isn't in the catalog`);
    await command("state");
    for (const key of keys) {
      assert(key.value === key.default, `${key.id} isn't at its default: ${key.value} vs ${key.default}`);
      assert(key.id in state().settings, `${key.id} isn't in the state log's settings`);
      assert(key.title && key.pane && key.group && key.control && key.scope, `${key.id} lacks a part: ${JSON.stringify(key)}`);
      assert(key.samples.length > 0 || key.control.startsWith("custom"), `${key.id} has no samples`);
      const value = async () => (await catalog()).find((k) => k.id === key.id).value;
      for (const sample of key.samples) {
        await command(`setting ${key.id} ${sample}`);
        const now = await value();
        assert(now === sample, `${key.id}: set ${sample}, reads ${now}`);
      }
      const before = await value();
      for (const bad of key.rejects) {
        const result = await commandResult(`setting ${key.id} ${bad}`);
        assert(result.startsWith("usage"), `setting ${key.id} ${bad} -> ${result}`);
        assert((await value()) === before, `${key.id} changed on a refused ${bad}`);
      }
      await command(`setting ${key.id} default`);
      assert((await value()) === key.default, `${key.id}: default reads ${await value()}`);
    }
    const unknown = await commandResult("setting noSuchSetting on");
    assert(unknown.startsWith("usage"), `an unknown setting -> ${unknown}`);
    await resetSettings();

    // Garbage of every kind for every setting, plus keys this build doesn't know and Ray's own state.
    const dir = mkdtempSync(join(tmpdir(), "ray-settings-catalog-"));
    const file = join(dir, "Settings.json");
    const junk = ["garbage", { nested: true }, 12345.678, [1, 2], null];
    const future = { nested: [1, "two", { three: 3 }], flag: false };
    writeFileSync(file, JSON.stringify({
      ...Object.fromEntries(keys.map((k, i) => [k.id, junk[i % junk.length]])),
      fromTheFuture: future, oldSetting: "kept", zoomedHosts: ["kept.example"], onboarded: true,
    }));
    let log = "";
    const it = spawn(join(app, "Contents/MacOS/Ray"), [], {
      env: { ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_LOG_STATE: "1", RAY_DATA_DIR: dir,
        RAY_DOWNLOADS_DIR: join(dir, "Downloads"), RAY_START_URL: `${origin}/a`,
        RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}.settings` },
      stdio: ["pipe", "ignore", "pipe"],
    });
    const exit = new Promise((r) => it.on("exit", (code, signal) => r(code ?? signal)));
    it.stdin.on("error", () => {});
    it.stderr.setEncoding("utf8");
    it.stderr.on("data", (chunk) => { log += chunk; });
    const run = async (line) => {
      const marker = `[ray-test] ${line} -> `;
      const from = log.length;
      it.stdin.write(line + "\n");
      return until(`command ${line}`, () => {
        const at = log.indexOf(marker, from);
        return at >= 0 ? log.slice(at + marker.length).split("\n")[0] : null;
      }, 25000, 150);
    };
    try {
      const loaded = JSON.parse(await run("settings catalog"));
      for (const key of loaded) assert(key.value === key.default, `${key.id} from garbage: ${key.value}, not ${key.default}`);
      // A change saves the file: every setting valid again, the unknown keys and Ray's state as they were.
      const flag = loaded.find((k) => k.control === "toggle");
      const other = flag.default === "on" ? "off" : "on";
      assert((await run(`setting ${flag.id} ${other}`)) === "ok", `setting ${flag.id} ${other}`);
      const saved = await until("saved", () => {
        const json = JSON.parse(readFileSync(file, "utf8"));
        return json[flag.id] === (other === "on") ? json : null;
      }, 4000);
      // (Same content; the file's keys are written sorted, nested ones too.)
      const canon = (o) => JSON.stringify(o, (k, v) => (v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort()) : v));
      assert(canon(saved.fromTheFuture) === canon(future) && saved.oldSetting === "kept",
        `unknown keys after a save: ${JSON.stringify(saved)}`);
      assert(saved.zoomedHosts?.join() === "kept.example" && saved.onboarded === true, `Ray's state after a save: ${JSON.stringify(saved)}`);
      for (const key of loaded.filter((k) => k.id !== flag.id)) {
        assert(!junk.slice(0, 4).some((j) => JSON.stringify(j) === JSON.stringify(saved[key.id])), `${key.id} kept its garbage: ${JSON.stringify(saved[key.id])}`);
      }
      it.stdin.write("menu quit\n");
      assert((await Promise.race([exit, sleep(15000).then(() => "timeout")])) !== "timeout", "the instance didn't quit within 15 s");
    } finally {
      if (it.exitCode === null && it.signalCode === null) it.kill("SIGKILL");
      rmSync(dir, { recursive: true, force: true });
    }
  },
  async "settings-minimal-url"() {
    await resetSettings();
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    const host = origin.replace("http://", "");
    const shown = () => state().toolbar.field.shown;
    await until("full address by default", async () => { await command("state"); return shown() === `${host}/a`; });
    await setSetting("minimalURL", "on");
    await until("host only", async () => { await command("state"); return shown() === host; });
    // View › Show Full Address is the same setting.
    await command("menu toggleFullAddress");
    await until("full again from the menu", async () => { await command("state"); return shown() === `${host}/a` && state().settings.minimalURL === false; });
    await command("menu toggleFullAddress");
    await until("host only from the menu", async () => { await command("state"); return shown() === host && state().settings.minimalURL === true; });
    await resetSettings();
    await until("full again", async () => { await command("state"); return shown() === `${host}/a`; });
  },
  async "address-fragment"() {
    // The full address shows the fragment, also after an in-page #anchor (a same-document navigation), as Chrome
    // does; View Source shows view-source: and then the inner address by the same rules.
    await resetSettings();
    const host = origin.replace("http://", "");
    const field = () => state().toolbar?.field;
    const fragment = "#release-v0.2.43-nightly.1";
    await goTo(`${origin}/anchors`, true);
    await until("anchors page", async () => {
      await command("state");
      return activeTabState()?.url === `${origin}/anchors` && state().toolbar?.address === `${host}/anchors`;
    });
    const page = state().active;
    const { sessionId } = await session("/anchors");
    await clickElement(sessionId, "#jump");
    await until("the anchor's fragment shows", async () => {
      await command("state");
      return activeTabState()?.url === `${origin}/anchors${fragment}` && state().toolbar?.address === `${host}/anchors${fragment}`;
    });
    assert(field().host === host && field().trail === `/anchors${fragment}` && field().shown === `${host}/anchors${fragment}`,
      `anchor: ${JSON.stringify(field())}`);
    // A fragment set by script, kept percent-encoded as the URL has it.
    await evaluate(sessionId, `location.hash = "caf%C3%A9"; 0`);
    await until("script's fragment shows", async () => { await command("state"); return field()?.shown === `${host}/anchors#caf%C3%A9`; });
    // Minimal: the host only, fragment and all hidden with the path.
    await setSetting("minimalURL", "on");
    await until("minimal", async () => { await command("state"); return field()?.shown === host; });
    assert(state().toolbar.address === `${host}/anchors#caf%C3%A9`, `minimal changed the address: ${state().toolbar.address}`);
    await setSetting("minimalURL", "off");
    // View Source (⌥⌘U): `view-source:` in grey, then the inner host and the rest.
    await command("key u cmd opt keywin");
    await until("source tab", async () => { await command("state"); return activeTabState()?.url.startsWith(`view-source:${origin}/anchors`); });
    const source = activeTabState().url;
    const inner = source.slice("view-source:".length).replace(origin, "");
    await until("source address", async () => { await command("state"); return state().toolbar?.address === `view-source:${host}${inner}`; });
    assert(field().lead === "view-source:" && field().host === host && field().trail === inner,
      `view source: ${JSON.stringify(field())}`);
    if (process.env.SNAP_DIR) await command(`toolbarsnap ${join(process.env.SNAP_DIR, "toolbar-view-source.png")}`);
    // Judged by the inner URL: plain http on 127.0.0.1 is a dev host, so no lock; the sidebar pill names it too.
    assert(field().look === "local" && field().icon === false, `view source look: ${field().look}, icon ${field().icon}`);
    assert(state().address === `view-source:${host.split(":")[0]}`, `sidebar address shows ${state().address}`);
    await command("menu closeTab");
    await until("back on the page", async () => { await command("state"); return state().active === page; });
    // A host too long for the field loses its start, never its end, and the path gives way to it.
    const long = ["a", "b", "c", "d"].map((c) => c.repeat(60)).join(".") + ".localhost";
    const port = new URL(origin).port;
    await goTo(`http://${long}:${port}/anchors`);
    await until("long host", async () => { await command("state"); return field()?.host === `${long}:${port}`; });
    assert(field().elided === "head" && field().shown === `${long}:${port}`, `long host: ${JSON.stringify(field())}`);
    await command("menu closeTab");
    await until("anchors tab closed", async () => { await command("state"); return !state().tabs.some((t) => t.id === page); });
  },
  async "settings-loading-progress"() {
    await resetSettings();
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    // `silent`: nothing is meant to show of the load (no address bar, progress off), so just give it time.
    const loadSlow = async (tag, silent = false) => {
      const from = states.length;
      await goTo(`${origin}/slow?${tag}`);
      if (silent) {
        await sleep(2600);
      } else {
        await until("loading", () => states.slice(from).find((s) => s.toolbar?.field?.stopButton || s.pages?.progressLine), 5000, 25);
        await until("loaded", async () => { await command("state"); return state().toolbar?.field.stopButton === false || (state().toolbar === null && !state().pages.progressLine); }, 8000);
      }
      await command("state");
      return states.slice(from);
    };
    // On (the default): the address bar's wash shows during the load.
    let seen = await loadSlow("on");
    assert(seen.some((s) => s.toolbar?.field?.wash), "no wash with loading progress on");
    // Off: the load still shows as a stop button, but nothing is drawn for it, in the bar or on the page.
    await setSetting("loadingProgress", "off");
    seen = await loadSlow("off");
    assert(seen.some((s) => s.toolbar?.field?.stopButton), "the stop button went away with progress off");
    assert(!seen.some((s) => s.toolbar?.field?.wash), "a wash showed with loading progress off");
    assert(!seen.some((s) => s.pages?.progressLine), "the page's load line showed with loading progress off");
    // With the address bar off the page draws its own thin line instead; progress off stops that too.
    await command("menu toggleToolbar");
    await until("bar off", async () => { await command("state"); return state().toolbar === null; });
    seen = await loadSlow("page-off", true);
    assert(!seen.some((s) => s.pages?.progressLine), "the page's load line showed with loading progress off and no address bar");
    await setSetting("loadingProgress", "on");
    seen = await loadSlow("page-on");
    assert(seen.some((s) => s.pages?.progressLine), "no page load line with progress on and no address bar");
    await command("menu toggleToolbar");
    await until("bar on", async () => { await command("state"); return state().toolbar !== null; });
    await goTo(`${origin}/a`);
    await until("/a again", () => tabFor("/a"));
    await resetSettings();
  },
  async "settings-theme"() {
    await resetSettings();
    const theme = () => state().settings.theme;
    assert(theme().setting === "default" && theme().accent === "#8257E5" && theme().accentDark === "#A486F0", `default theme ${JSON.stringify(theme())}`);
    // White or black text, whichever has the higher contrast: the lavender is dark enough for white in light mode,
    // light enough for black in dark mode.
    assert(theme().foreground === "white" && theme().foregroundDark === "black", `default foreground ${JSON.stringify(theme())}`);
    const defaultWash = state().toolbar.field.washColor;
    await setSetting("theme", "#FFD60A");
    assert(theme().setting === "#FFD60A" && theme().accent === "#FFD60A" && theme().accentDark === "#FFD60A", `yellow ${JSON.stringify(theme())}`);
    assert(theme().foreground === "black" && theme().foregroundDark === "black", `a light colour should have black text: ${JSON.stringify(theme())}`);
    // Everything drawn with the accent follows at once.
    assert(state().pages.progressColor === "#FFD60A", `the page's load line is ${state().pages.progressColor}`);
    const yellowWash = state().toolbar.field.washColor;
    assert(yellowWash !== defaultWash, "the loading wash kept the old colour");
    await setSetting("theme", "#14146E");
    assert(theme().foreground === "white" && theme().foregroundDark === "white", `a dark colour should have white text: ${JSON.stringify(theme())}`);
    assert(state().pages.progressColor === "#14146E" && state().toolbar.field.washColor !== yellowWash, "the accent didn't follow the new colour");
    // The window shows it: a colour that is no swatch is the custom one; a preset's own swatch is selected.
    await command("settings open");
    await until("window open", async () => { await command("state"); return state().settingsWindow.open; });
    assert(state().settingsWindow.controls.theme === "#14146E" && state().settingsWindow.controls.themeSelected === 8, `custom ${JSON.stringify(state().settingsWindow.controls)}`);
    await setSetting("theme", "#12A594");
    await until("preset selected", async () => { await command("state"); return state().settingsWindow.controls.themeSelected === 2; });
    await closeSettingsWindow();
    // A value that isn't a colour is refused.
    const refused = await commandResult("setting theme red");
    assert(refused.startsWith("usage"), `setting theme red -> ${refused}`);
    assert(state().settings.theme.setting === "#12A594", "a bad colour changed the theme");
    await setSetting("theme", "default");
    // (The page's line is drawn in the window's own appearance, light or dark.)
    assert(theme().accent === "#8257E5" && [theme().accent, theme().accentDark].includes(state().pages.progressColor), `back to default: ${JSON.stringify(theme())} ${state().pages.progressColor}`);
    assert(state().toolbar.field.washColor === defaultWash, "the wash didn't come back to the default");
  },
  async "settings-zoom"() {
    await resetSettings();
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    const { sessionId } = await session("/a");
    const dpr = async () => evaluate(sessionId, `window.devicePixelRatio`);
    const base = await dpr();
    let zoomed = 0;
    assert(near(activeZoom(), 1), `starts at ${activeZoom()}`);
    // The default applies to the page on screen, and the page really is scaled by it.
    await setSetting("defaultZoom", "1.25");
    await until("default applied", async () => { await command("state"); return near(activeZoom(), 1.25); });
    await until("page scaled", async () => near((await dpr()) / base, 1.25));
    // A site the user zooms keeps its own level; a site they haven't gets the default on its navigation.
    await goTo(`${localOrigin}/b`, true);
    await until("localhost, default zoom", async () => { await command("state"); return activeTabState()?.url.startsWith(localOrigin) && near(activeZoom(), 1.25); });
    await command("zoom in");
    await until("user zoomed localhost", async () => { await command("state"); return (activeZoom() > 1.26 && (zoomed = activeZoom())) && state().settings.zoomedHosts.includes("localhost"); });
    await setSetting("defaultZoom", "2");
    await sleep(300);
    await command("state");
    assert(near(activeZoom(), zoomed), `the default changed a zoomed site: ${activeZoom()}`);
    // Another tab on a host the user hasn't zoomed follows the default, in either direction.
    await goTo(`${raytestOrigin}/b`, true);
    await until("ray.test, default zoom", async () => { await command("state"); return activeTabState()?.url.startsWith(raytestOrigin) && near(activeZoom(), 2); });
    await setSetting("defaultZoom", "0.75");
    await until("ray.test follows the new default", async () => { await command("state"); return near(activeZoom(), 0.75); });
    // Going to the zoomed host keeps its level, and coming back to an unzoomed one gets the default.
    await goTo(`${localOrigin}/h`);
    await until("localhost keeps its zoom", async () => { await command("state"); return activeTabState()?.url.startsWith(localOrigin) && near(activeZoom(), zoomed); });
    await sleep(300);
    await command("state");
    assert(near(activeZoom(), zoomed), `localhost lost its zoom: ${activeZoom()}`);
    await goTo(`${raytestOrigin}/h`);
    await until("ray.test default", async () => { await command("state"); return activeTabState()?.url.startsWith(raytestOrigin) && near(activeZoom(), 0.75); });
    assert(!state().settings.zoomedHosts.includes("ray.test"), "the default was taken for the user's zoom");
    // Reset (the site controls' button) hands a site back to the default.
    await goTo(`${localOrigin}/b`);
    await until("localhost again", async () => { await command("state"); return activeTabState()?.url.startsWith(localOrigin) && near(activeZoom(), zoomed); });
    await command("zoom reset");
    await until("localhost follows the default", async () => { await command("state"); return near(activeZoom(), 0.75) && !state().settings.zoomedHosts.includes("localhost"); });
    // The first tab (127.0.0.1) followed every change too.
    const first = state().tabs.find((t) => t.url.startsWith(origin));
    assert(first && near(first.zoom, 0.75), `127.0.0.1 is at ${first?.zoom}`);
    await setSetting("defaultZoom", "1");
    await until("all back to 100%", async () => { await command("state"); return state().tabs.every((t) => near(t.zoom, 1)); });
    for (const extra of state().tabs.filter((t) => !t.url.startsWith(origin))) await command(`rowaction close ${entryOfTab(extra.id).id}`);
    await until("zoom tabs closed", async () => { await command("state"); return state().tabs.every((t) => t.url.startsWith(origin)); });
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await resetSettings();
  },
  async "settings-private-zoom"() {
    // A private window reads the default but never writes its zoomed hosts to Settings.json.
    await resetSettings();
    await setSetting("defaultZoom", "1.25");
    await command("menu newPrivateWindow");
    await until("private window", async () => { await command("state"); return state().private === true && state().commandBar; });
    await command(`type ${origin}/b?pzoom`);
    await command("enter");
    await until("private page at the default", async () => { await command("state"); return state().private === true && near(activeZoom() ?? 0, 1.25); });
    await command("zoom in");
    await until("zoomed in the private window", async () => { await command("state"); return activeZoom() > 1.26; });
    await sleep(600);
    await command("state");
    assert(!state().settings.zoomedHosts.includes("127.0.0.1"), "a private window's zoom reached the settings");
    const file = readFileSync(join(dataDir, "Settings.json"), "utf8");
    assert(!file.includes("127.0.0.1"), "a private window's host was saved in Settings.json");
    await command("key w cmd");
    await until("private tab closed", async () => { await command("state"); return state().private === true && state().active === null; }, 5000);
    await command("key w cmd keywin");
    await until("back to the normal window", async () => { await command("state"); return state().private === false; }, 5000);
    await resetSettings();
    await until("normal tabs back to 100%", async () => { await command("state"); return state().tabs.every((t) => near(t.zoom, 1)); });
  },
  async "settings-new-tab-position"() {
    await resetSettings();
    await todayTabs(3);
    const today = () => state().sidebar.today.map((e) => e.id);
    const target = state().sidebar.today[1];
    await command(`row ${target.id}`);
    await until("middle tab active", () => state().activeEntry === target.id);
    // Off (the default): a new tab goes to the top of Today.
    await goTo(`${origin}/b?top`, true);
    await until("new tab at the top", () => state().sidebar.today[0]?.url.includes("?top"));
    // On: right after the active tab.
    await setSetting("newTabNextToActive", "on");
    await command(`row ${target.id}`);
    await until("middle tab active again", () => state().activeEntry === target.id);
    await goTo(`${origin}/b?next`, true);
    await until("new tab next to the active one", () => today().indexOf(state().sidebar.today.find((e) => e.url.includes("?next"))?.id) === today().indexOf(target.id) + 1);
    // From a tab that isn't in Today the new tab goes to the top as usual.
    for (const url of ["?top", "?next"]) {
      const e = state().sidebar.today.find((e) => e.url.includes(url));
      if (e) await command(`rowaction close ${e.id}`);
    }
    await resetSettings();
  },
  async "settings-recent-tab-cycling"() {
    await resetSettings();
    // Four tabs, used in a known order: T1, T2, T3, T4 (T4 most recent).
    await todayTabs(4);
    const tabs = state().sidebar.today.filter((e) => e.live).slice(0, 4);
    assert(tabs.length === 4, "need four open tabs in Today");
    const [t1, t2, t3, t4] = tabs;
    for (const t of [t1, t2, t3, t4]) {
      await command(`row ${t.id}`);
      await until("tab active", () => state().activeEntry === t.id);
      await sleep(30);
    }
    const key = async (extra, expect) => {
      await command(`key tab ctrl ${extra}keywin`.replace("  ", " "));
      await until(`tab ${expect.title}`, async () => { await command("state"); return state().activeEntry === expect.id; }, 4000);
    };
    // Holding Control, each press goes one further back, and ⇧ goes the other way.
    await key("", t3);
    await key("", t2);
    await key("", t1);
    await command("state");
    // (Every live tab is in the walk; earlier checks can leave more open than these four.)
    assert(state().tabCycle?.order.length >= 4, "no walk in progress while Control is held");
    await key("shift ", t2);
    await command("key ctrlup");
    await until("walk settled", async () => { await command("state"); return state().tabCycle === null; });
    // Settled on T2: it is now the most recent; the rest keep their order (T4, T3, T1).
    const ids = (list) => list.map((e) => e.tab);
    assert(JSON.stringify(state().recentOrder.slice(0, 4)) === JSON.stringify(ids([t2, t4, t3, t1])), `recent order ${state().recentOrder}, wanted ${ids([t2, t4, t3, t1])} first`);
    // A quick press and release goes back to the tab you were just on.
    await key("", t4);
    await command("key ctrlup");
    await until("walk settled", async () => { await command("state"); return state().tabCycle === null; });
    await key("", t2);
    await command("key ctrlup");
    await until("walk settled again", async () => { await command("state"); return state().tabCycle === null; });
    // Off: the sidebar's order.
    await setSetting("recentTabCycling", "off");
    const order = allEntries().filter((e) => e.live);
    const at = order.findIndex((e) => e.id === state().activeEntry);
    const next = order[(at + 1) % order.length];
    await key("", next);
    await command("key ctrlup");
    assert(state().tabCycle === null, "a walk started with recently used order off");
    await resetSettings();
  },
  async "settings-panes"() {
    // Direction G: every pane in the sidebar in its order (test builds list them all), rows from the catalog by pane,
    // ray://settings/<pane> opens the window at that pane, and Ray.app hides unbuilt rows and empty panes.
    await resetSettings();
    await closeSettingsWindow().catch(() => {});
    const win = () => state().settingsWindow;
    const all = ["general", "tabs", "appearance", "search", "privacy", "passwords", "autofill", "extensions", "shortcuts", "about"];
    await command("settings open appearance");
    await until("appearance", async () => { await command("state"); return win().open && win().pane === "appearance"; });
    assert(win().panes.join() === all.join() && win().sidebarPanes.join() === all.join(), `panes ${win().panes} / ${win().sidebarPanes}`);
    const rows = win().rows;
    assert(["theme", "appearanceMode", "minimalURL", "loadingProgress", "defaultZoom", "scrollBars"].every((id) => rows.appearance.includes(id)), `appearance rows ${rows.appearance}`);
    assert(rows.tabs.join() === "newTabNextToActive,recentTabCycling,showSidebarButton,showClearButton,hideAddressBarWhileScrolling,fadeUnloadedTabs,tabReorderHaptics,sidebarMediaControls,autoPictureInPicture" && rows.shortcuts.join() === "copyLinkShortcut,sidebarShortcut,undoReopensClosedTab,shortcuts", `rows ${JSON.stringify(rows)}`);
    assert(rows.about.includes("about.version") && rows.general.includes("onQuit"), `rows ${JSON.stringify(rows)}`);
    assert((await commandResult("settings open nonsense")) === "no such pane", "a pane that isn't there opened");
    // The new controls: segmented (scroll bars, a rare row under "More") and picture choices (light or dark).
    assert(win().more.appearance.page === false, `More is open: ${JSON.stringify(win().more)}`);
    await command("settings press scrollBars 2");
    await until("segment chose Always", async () => { await command("state"); return state().settings.scrollBars === "always" && win().controls.scrollBars === "Always"; });
    assert(win().controls.scrollBarsOptions.join() === "Automatic,When scrolling,Always", `segments ${win().controls.scrollBarsOptions}`);
    await command("settings press appearanceMode 2");
    await until("picture chose Dark", async () => { await command("state"); return state().settings.appearanceMode === "dark" && win().controls.appearanceModeSelected === 2; });
    await setSetting("appearanceMode", "light");
    await until("picture follows the setting", async () => { await command("state"); return win().controls.appearanceMode === "light" && win().controls.appearanceModeSelected === 1; });
    await setSetting("scrollBars", "default");
    await setSetting("appearanceMode", "default");
    // Live pictures follow their settings.
    assert(win().pictures.minimalURL?.minimalAddress === false && win().pictures.newTabNextToActive?.rows[0] === "new", `pictures ${JSON.stringify(win().pictures)}`);
    await setSetting("minimalURL", "on");
    await setSetting("newTabNextToActive", "on");
    await until("pictures follow", async () => { await command("state"); return win().pictures.minimalURL.minimalAddress === true && win().pictures.newTabNextToActive.rows.join() === "plain,active,new,plain"; });
    await resetSettings();
    if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "settings-appearance.png")}`);
    // ray://settings/<pane>: typed, it opens the window there and loads nothing.
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    const before = activeTabState().url;
    for (const pane of ["tabs", "shortcuts", "about", "general"]) {
      await closeSettingsWindow();
      await goTo(`ray://settings/${pane}`);
      await until(`ray://settings/${pane}`, async () => { await command("state"); return win().open && win().pane === pane; });
      await sleep(200);
      await command("state");
      assert(activeTabState().url === before, `ray://settings/${pane} changed the tab: ${activeTabState().url}`);
    }
    // ⌘, opens the pane last shown.
    await command("settings open about");
    await closeSettingsWindow();
    await command("menu showSettings");
    await until("last pane", async () => { await command("state"); return win().open && win().pane === "about"; });
    await closeSettingsWindow();
    // Chrome still draws Privacy and security: its address is Chrome's page, not the window (ray://settings/privacy is
    // Ray's Privacy pane: settings-privacy).
    const tabs = state().tabs.length;
    await goTo("chrome://settings/privacy", true);
    await until("Chrome's privacy page", async () => { await command("state"); return activeTabState()?.url.startsWith("chrome://settings/privacy"); }, 10000);
    assert(!win().open, "chrome://settings/privacy opened the window");
    await command("menu closeTab");
    await until("privacy tab closed", async () => { await command("state"); return state().tabs.length === tabs; });
    // As Ray.app shows it: unbuilt rows and panes with nothing to show are gone, from the sidebar and from routing.
    await command("settings asapp on");
    await command("settings open search");
    await until("Ray.app's panes", async () => { await command("state"); return win().open && win().looksLikeRayApp; });
    assert(win().panes.join() === "general,tabs,appearance,search,privacy,passwords,autofill,extensions,shortcuts,about" && win().sidebarPanes.join() === win().panes.join(), `Ray.app panes ${win().panes}`);
    assert(["jumpCloudRelay", "jumpCloudRelay.setup"].every(id => win().rows.passwords.includes(id)), `Ray.app passwords rows ${win().rows.passwords}`);
    // Every pane has content of its own now, so none is hidden; Search opens as itself.
    assert(win().pane === "search", `Search opened as ${win().pane}`);
    assert(!win().rows.appearance.includes("appIcon") && win().rows.appearance.includes("appearanceMode") && win().rows.appearance.includes("scrollBars") && win().rows.appearance.includes("minimalURL"), `Ray.app rows ${win().rows.appearance}`);
    assert(win().rows.tabs.join() === "newTabNextToActive,recentTabCycling,showSidebarButton,fadeUnloadedTabs,tabReorderHaptics", `Ray.app tabs rows ${win().rows.tabs}`);
    if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "settings-as-app.png")}`);
    await command("settings asapp off");
    await command("state");
    assert(win().panes.length === all.length && !win().looksLikeRayApp, `back to every pane: ${win().panes}`);
    await closeSettingsWindow();
  },
  async "settings-search"() {
    // The sidebar's search: results replace the panes while typing, ↑ ↓ ⏎ pick one, which opens its pane, scrolls to
    // its row and flashes it (120 ms in, 900 ms held, 700 ms out); Escape clears.
    await resetSettings();
    await command("settings open general");
    const win = () => state().settingsWindow;
    const search = () => win().search;
    await until("window", async () => { await command("state"); return win().open && win().pane === "general"; });
    await command("settings search zoom");
    await until("zoom results", async () => { await command("state"); return search().results.length > 0; });
    assert(search().results[0].id === "defaultZoom" && search().selected === 0, `zoom: ${JSON.stringify(search())}`);
    assert(win().sidebarPanes.length === 0, "the pane list stayed up while searching");
    // Page zoom sits below the window's fold: choosing it scrolls it into view.
    await command("settings key down");
    await command("settings key up");
    await command("state");
    assert(search().selected === 0, `↑ after ↓: ${search().selected}`);
    await command("settings key enter");
    const flashed = await until("flash", async () => { await command("state"); return win().flashing === "defaultZoom" && win(); }, 3000, 50);
    assert(flashed.pane === "appearance" && flashed.flashVisible, `flash ${JSON.stringify({ pane: flashed.pane, visible: flashed.flashVisible })}`);
    await until("flash over", async () => { await command("state"); return win().flashing === null; }, 4000);
    assert(win().lastFlash === "defaultZoom", `last flash ${win().lastFlash}`);
    // A rare row: its group's "More" opens first.
    await command("settings search scroll bars");
    await until("scroll bars", async () => { await command("state"); return search().results[0]?.id === "scrollBars"; });
    await command("settings choose 0");
    await until("rare row flashed", async () => { await command("state"); return win().lastFlash === "scrollBars" && win().more.appearance.page === true; });
    // Pane names, and a pane's own section (About Ray's version).
    await command("settings search shortcuts");
    await until("pane result", async () => { await command("state"); return search().results.some((r) => r.kind === "pane" && r.pane === "shortcuts"); });
    await command("settings search version");
    await until("section result", async () => { await command("state"); return search().results[0]?.id === "about.version"; });
    await command("settings key enter");
    await until("about", async () => { await command("state"); return win().pane === "about" && win().lastFlash === "about.version"; });
    // Nothing found; Escape clears and the panes come back.
    await command("settings search zzqqx");
    await until("no results", async () => { await command("state"); return search().query === "zzqqx" && search().results.length === 0; });
    await command("settings key escape");
    await until("cleared", async () => { await command("state"); return search().query === "" && win().sidebarPanes.length === win().panes.length; });
    // Ray.app doesn't find rows it doesn't show.
    await command("settings asapp on");
    await command("settings search app icon");
    await until("searched", async () => { await command("state"); return search().query === "app icon"; });
    assert(!search().results.some((r) => r.id === "appIcon"), `Ray.app found an unbuilt row: ${JSON.stringify(search().results)}`);
    await command("settings asapp off");
    await command("settings search");
    if (process.env.SNAP_DIR) {
      await command("settings search address");
      await command(`settings snap ${join(process.env.SNAP_DIR, "settings-search.png")}`);
      await command("settings search");
    }
    await closeSettingsWindow();
  },
  async "settings-bar"() {
    // ⌘T offers "Settings: …" for each shown setting and pane, after what you typed and the menu commands; one leads
    // only when named in full after "settings" and no page or host matches.
    await resetSettings();
    await closeSettingsWindow().catch(() => {});
    const barFor = async (text) => {
      await command("menu newTab");
      await until("bar open", async () => { await command("state"); return state().commandBar; });
      await command(`type ${text}`);
      return until(`rows for ${text}`, async () => { await command("state"); return state().commandBar?.query === text && state().commandBar; });
    };
    const settingRows = (bar) => bar.rows.filter((r) => r.kind === "setting");
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    let bar = await barFor("minimal url");
    let at = bar.rows.findIndex((r) => r.kind === "setting" && r.title === "Settings: Show only the site in the address bar");
    assert(at > 0 && bar.rows[at].detail === "Appearance › Address bar", `minimal url: ${JSON.stringify(bar.rows)}`);
    assert(bar.rows[0].kind === "search", `a partial setting name took the first row: ${JSON.stringify(bar.rows[0])}`);
    if (process.env.SNAP_DIR) await command(`barsnap ${join(process.env.SNAP_DIR, "command-bar-settings.png")}`);
    for (let i = 0; i < at; i++) await command("down");
    await command("enter");
    await until("window at the row", async () => { await command("state"); return state().commandBar === null && state().settingsWindow.open && state().settingsWindow.pane === "appearance" && state().settingsWindow.lastFlash === "minimalURL"; });
    await closeSettingsWindow();
    // Panes by name.
    bar = await barFor("appearance");
    assert(settingRows(bar).some((r) => r.title === "Settings: Appearance"), `appearance: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    // Named in full after "settings", with nothing else to go to: it leads and Enter opens it.
    bar = await barFor("settings theme colour");
    assert(bar.rows[0].kind === "setting" && bar.rows[0].title === "Settings: Theme colour", `exact: ${JSON.stringify(bar.rows)}`);
    await command("enter");
    await until("theme row", async () => { await command("state"); return state().commandBar === null && state().settingsWindow.lastFlash === "theme"; });
    await closeSettingsWindow();
    // A page that matches keeps the Enter row: a tab whose address has the same words.
    await goTo(`${origin}/b?settings-theme-colour`, true);
    await until("page", async () => { await command("state"); return activeTabState()?.url.endsWith("?settings-theme-colour"); });
    const page = state().active;
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active again", () => state().active === tabFor("/a").id);
    bar = await barFor("settings theme colour");
    assert(bar.rows[0].kind !== "setting" && settingRows(bar).length > 0, `a setting led over a page: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    await command(`rowaction close ${entryOfTab(page).id}`);
    await until("page closed", async () => { await command("state"); return !state().tabs.some((t) => t.id === page); });
    // An address is an address.
    bar = await barFor("settings.localhost");
    assert(bar.rows[0].kind === "url" && settingRows(bar).length === 0, `settings.localhost: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    // Rows Ray.app doesn't show aren't offered.
    await command("settings asapp on");
    bar = await barFor("app icon");
    assert(!settingRows(bar).some((r) => r.title === "Settings: App icon"), `Ray.app offered an unbuilt row: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    await command("settings asapp off");
    bar = await barFor("app icon");
    assert(settingRows(bar).some((r) => r.title === "Settings: App icon"), `a test build hid an unbuilt row: ${JSON.stringify(bar.rows)}`);
    await command("escape");
  },
  async "settings-colours"() {
    // The selected pane's wash and ink come from the profile's colour, readable in light and dark (4.5:1), and follow it.
    await resetSettings();
    await command("settings open appearance");
    const win = () => state().settingsWindow;
    await until("window", async () => { await command("state"); return win().open; });
    const colours = () => win().selectedRow;
    const readable = (c) => c.contrast >= 4.5 && c.contrastDark >= 4.5;
    const lavender = await until("selection drawn", async () => {
      await command("state");
      return [colours().fill, colours().fillDark].includes(colours().drawnFill) && colours();
    });
    assert(readable(lavender), `default selection unreadable: ${JSON.stringify(lavender)}`);
    assert(lavender.fill !== lavender.sidebar && lavender.fillDark !== lavender.sidebarDark, "the selection has no wash");
    for (const hex of ["#12A594", "#000000", "#FFD60A"]) {
      await setSetting("theme", hex);
      // The row on screen redraws in it too.
      const now = await until(`selection in ${hex}`, async () => {
        await command("state");
        const c = colours();
        return c.fill !== lavender.fill && [c.fill, c.fillDark].includes(c.drawnFill) && c;
      });
      assert(readable(now), `${hex}: ${JSON.stringify(now)}`);
    }
    // Teal washes teal: green and blue above red.
    await setSetting("theme", "#12A594");
    await until("teal", async () => { await command("state"); const [r, g, b] = [1, 3, 5].map((i) => parseInt(colours().fill.slice(i, i + 2), 16)); return g > r && b > r; });
    if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "settings-teal.png")}`);
    await resetSettings();
    await until("lavender again", async () => { await command("state"); return colours().fill === lavender.fill; });
    await closeSettingsWindow();
  },
  async "settings-shortcuts"() {
    await resetSettings();
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    assert(state().menuKeys.copyURL === "C" && state().menuKeys.toggleSidebar === "s", `menu keys ${JSON.stringify(state().menuKeys)}`);
    // ⇧⌘C copies the page's address.
    const urlA = activeTabState().url;
    await command("key c cmd shift");
    await until("copied", () => state().pasteboard === urlA);
    // Off: the item has no key and the key does nothing in Ray.
    await goTo(`${origin}/b?copy`);
    await until("/b?copy", () => tabFor("?copy"));
    await setSetting("copyLinkShortcut", "off");
    assert(state().menuKeys.copyURL === "", `⇧⌘C still on the menu: ${JSON.stringify(state().menuKeys)}`);
    await command("key c cmd shift");
    await sleep(600);
    await command("state");
    assert(state().pasteboard === urlA, `⇧⌘C copied with the setting off: ${state().pasteboard}`);
    await setSetting("copyLinkShortcut", "on");
    await command("key c cmd shift");
    await until("copies again", () => state().pasteboard === activeTabState().url && state().pasteboard.includes("?copy"));
    await goTo(`${origin}/a`);
    await until("/a again", () => tabFor("/a"));
    // ⌘S toggles the sidebar; off, the menu item has no key and ⌘S leaves the sidebar alone.
    await setSetting("sidebarShortcut", "off");
    assert(state().menuKeys.toggleSidebar === "", `⌘S still on the menu: ${JSON.stringify(state().menuKeys)}`);
    const hidden = state().sidebar.hidden;
    await command("key s cmd");
    await sleep(600);
    await command("state");
    assert(state().sidebar.hidden === hidden, "⌘S toggled the sidebar with the setting off");
    await command("menu toggleSidebar");
    await until("the menu item still works", async () => { await command("state"); return state().sidebar.hidden === !hidden; });
    await command("menu toggleSidebar");
    await until("sidebar back", async () => { await command("state"); return state().sidebar.hidden === hidden; });
    await setSetting("sidebarShortcut", "on");
    await command("key s cmd");
    await until("⌘S toggles again", async () => { await command("state"); return state().sidebar.hidden === !hidden; });
    await command("key s cmd");
    await until("⌘S toggles back", async () => { await command("state"); return state().sidebar.hidden === hidden; });
    await resetSettings();
  },
  async "jumpcloud-relay"() {
    // Settings › Passwords › Sign in with JumpCloud Go through Chrome (Host/JumpCloudRelay.swift), on an instance of
    // its own: console.jumpcloud.com maps to a local fixture (so the real host list is what triggers), and "Chrome" is
    // tests/jumpcloud-chrome-standin.mjs on the DevTools pipe. Off: nothing starts. On: Chrome starts headless with
    // its own profile (0700), a pipe (never a port) and ordinary Chrome's user agent, never brought forward; only
    // jumpcloud.com cookies land in Ray, replacing a stale session; the tab reloads; a private window never relays;
    // the loop guard; headless that doesn't finish falls back to a window (a note in full screen, in front otherwise);
    // the deadline, a silent Chrome and Set Up….
    const dir = mkdtempSync(join(tmpdir(), "ray-jumpcloud-"));
    const data = join(dir, "data");
    const standin = join(dir, "standin");
    mkdirSync(standin);
    const mode = (name) => writeFileSync(join(standin, "mode"), name);
    mode("success");
    const wrapper = join(dir, "chrome");
    writeFileSync(wrapper, `#!/bin/sh\nRAY_STANDIN_DIR=${JSON.stringify(standin)} exec ${JSON.stringify(process.execPath)} ` +
      `${JSON.stringify(join(root, "tests/jumpcloud-chrome-standin.mjs"))} "$@"\n`, { mode: 0o755 });
    const lines = (file) => existsSync(join(standin, file))
      ? readFileSync(join(standin, file), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
    const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
    const requests = [];
    const jc = createSecureServer({ key: readFileSync(join(dataDir, "fixture.key")), cert: readFileSync(join(dataDir, "fixture.crt")) }, (req, res) => {
      const url = new URL(req.url, "https://console.jumpcloud.com");
      requests.push({ path: url.pathname + url.search, cookie: req.headers.cookie ?? "" });
      if (url.pathname === "/seed") {
        res.writeHead(200, { "content-type": "text/html", "set-cookie": ["jcsession=stale; Path=/; Secure; HttpOnly; Max-Age=3600",
          "rayonly=1; Domain=jumpcloud.com; Path=/; Secure; Max-Age=3600"] });
        return res.end("<title>Seed</title><p>seed</p>");
      }
      if (url.pathname === "/login") {
        // As JumpCloud's console does: signed in (the relay's session), the page's script moves on to the console
        // without a new document; `stay` keeps it on the login page (a session JumpCloud doesn't take).
        const signedIn = /jcsession=relay-session/.test(req.headers.cookie ?? "") && !url.searchParams.has("stay");
        res.writeHead(200, { "content-type": "text/html" });
        // Signed out, the page still rewrites its own address once (as JumpCloud's login does with its step); that
        // mustn't stop the relay.
        return res.end("<title>JumpCloud</title><p>login</p>" + (signedIn
          ? `<script>history.replaceState(null, "", "/userconsole/")</script>`
          : `<script>history.replaceState(null, "", location.pathname + location.search + "&step=email")</script>`));
      }
      res.writeHead(404);
      res.end("not found");
    });
    await new Promise((r) => jc.listen(0, "127.0.0.1", r));
    const devPort = 9850 + Math.floor(Math.random() * 140);
    let log = "";
    const it = spawn(join(app, "Contents/MacOS/Ray"), [], {
      env: { ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_LOG_STATE: "1", RAY_DATA_DIR: data,
        RAY_DOWNLOADS_DIR: join(dir, "Downloads"), RAY_START_URL: `${origin}/a`, RAY_IGNORE_CERT_ERRORS: "1",
        RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}.jumpcloud`, RAY_REMOTE_DEBUGGING_PORT: String(devPort),
        RAY_HOST_RULES: `MAP console.jumpcloud.com 127.0.0.1:${jc.address().port}`,
        RAY_JUMPCLOUD_RELAY_CHROME: wrapper, RAY_JUMPCLOUD_RELAY_DEADLINE: "6",
        RAY_JUMPCLOUD_RELAY_HEADLESS_DEADLINE: "1.5", RAY_JUMPCLOUD_RELAY_SETTLE: "0.5", RAY_JUMPCLOUD_RELAY_CHROME_VERSION: "141.0.7390.123" },
      stdio: ["pipe", "ignore", "pipe"],
    });
    const exit = new Promise((r) => it.on("exit", (code, signal) => r(code ?? signal)));
    it.stdin.on("error", () => {});
    it.stderr.setEncoding("utf8");
    it.stderr.on("data", (chunk) => { log += chunk; });
    const run = async (line) => {
      const marker = `[ray-test] ${line} -> `;
      const from = log.length;
      it.stdin.write(line + "\n");
      return until(`command ${line}`, () => {
        const at = log.indexOf(marker, from);
        return at >= 0 ? log.slice(at + marker.length).split("\n")[0] : null;
      }, 25000, 100);
    };
    const ok = async (line) => assert((await run(line)) === "ok", `${line} didn't run`);
    const latest = () => {
      const done = log.slice(0, log.lastIndexOf("\n"));
      const at = done.lastIndexOf("[ray-state] ");
      return at < 0 ? null : JSON.parse(done.slice(at + "[ray-state] ".length).split("\n")[0]);
    };
    const now = async () => { await ok("state"); await sleep(50); return latest(); };
    const relay = async () => (await now()).jumpCloudRelay;
    const goTo = async (path, newTab = false) => {
      await ok(newTab ? "menu newTab" : "menu focusAddress");
      await ok(`type https://console.jumpcloud.com${path}`);
      await ok("enter");
      await until(`request ${path}`, () => requests.some((r) => r.path === path), 10000);
    };
    let socket;
    try {
      await until("the relay instance", async () => (await now())?.tabs?.length > 0, 20000);
      const version = await until("its DevTools", async () => {
        try { return await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json(); } catch { return null; }
      }, 20000);
      socket = new WebSocket(version.webSocketDebuggerUrl);
      await new Promise((r, j) => ((socket.onopen = r), (socket.onerror = j)));
      let seq = 1;
      const replies = new Map();
      socket.onmessage = (m) => { const msg = JSON.parse(m.data); replies.get(msg.id)?.(msg); replies.delete(msg.id); };
      const cdp = (method, params = {}) => new Promise((r) => { const id = seq++; replies.set(id, r); socket.send(JSON.stringify({ id, method, params })); });
      const rayCookies = async () => (await cdp("Storage.getCookies")).result.cookies;
      // Signed out of JumpCloud in Ray again, so the next login page relays rather than moving on by itself.
      const signOut = () => cdp("Storage.clearCookies");
      const jumpcloudIn = (cookies) => cookies.filter((c) => /(^|\.)jumpcloud\.com$/.test(c.domain.replace(/^\./, "")));

      // A stale session in Ray, which the relay must replace (the engine's import keeps cookies Ray already has).
      await goTo("/seed");
      await until("stale cookie", async () => (await rayCookies()).some((c) => c.name === "jcsession" && c.value === "stale"));
      assert((await relay()).launches === 0 && (await relay()).lastResult === "none", "the relay started on its own");

      // Off (the default): the login page loads in Ray and nothing starts.
      await goTo("/login?n=off");
      await sleep(1000);
      assert((await relay()).launches === 0 && lines("launches.jsonl").length === 0, "Chrome started with the setting off");

      // On, without JumpCloud Go in Ray's Chrome profile: a note pointing to Set Up, no Chrome.
      await ok("setting jumpCloudRelay on");
      await goTo("/login?n=nosetup");
      await until("not set up", async () => (await relay()).lastResult === "notSetUp");
      assert(latest().toast.includes("Set up JumpCloud Go") && latest().jumpCloudRelay.launches === 0, `not set up: ${latest().toast}`);
      const profile = join(data, "JumpCloud Relay");
      mkdirSync(join(profile, "Default/Extensions/jdoahkhfkeipblhbhppmcbdgapeoaopa/3.3.5_0"), { recursive: true });

      // Signed in, headless: Chrome without a window (never brought forward) on the console's own login page (not the
      // app's flow) as ordinary Chrome 141, then only jumpcloud.com cookies come over, the stale session goes, and
      // the tab reloads with the new one.
      const base = [`--user-data-dir=${profile}`, "--remote-debugging-pipe", "--no-first-run", "--no-default-browser-check",
        "--no-startup-window"];
      const agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
      const callsOf = (pid) => lines("cdp.jsonl").filter((c) => c.pid === pid);
      await goTo("/login?n=1");
      await until("signed in", async () => (await relay()).lastResult === "signedIn", 10000);
      let state = await relay();
      assert(state.launches === 1 && state.cookiesImported === 2 && state.directoryMode === "700" && state.directory === profile &&
        state.lastMode === "headless" && state.activations === 0 && state.fallbacks === 0, `relay ${JSON.stringify(state)}`);
      const [launch] = lines("launches.jsonl");
      assert(JSON.stringify(launch.argv) === JSON.stringify([...base, "--headless=new", `--user-agent=${agent}`]),
        `Chrome's arguments: ${JSON.stringify(launch.argv)}`);
      assert(!launch.argv.some((a) => /headless/i.test(a) && a.startsWith("--user-agent")), "the user agent says headless");
      const calls = () => callsOf(launch.pid);
      const methods = calls().map((c) => c.method);
      const created = calls().find((c) => c.method === "Target.createTarget");
      assert(created.params.url === "about:blank" && created.params.newWindow === undefined && created.params.width === undefined,
        `createTarget ${JSON.stringify(created.params)}`);
      const attach = calls().find((c) => c.method === "Target.attachToTarget");
      assert(attach?.params.flatten === true, `attach ${JSON.stringify(attach)}`);
      const override = calls().find((c) => c.method === "Emulation.setUserAgentOverride");
      const brands = override?.params.userAgentMetadata?.brands ?? [];
      assert(override?.sessionId === "S1" && override.params.userAgent === agent &&
        brands.map((b) => `${b.brand};${b.version}`).join() === "Google Chrome;141,Not?A_Brand;8,Chromium;141" &&
        override.params.userAgentMetadata.platform === "macOS" &&
        !JSON.stringify(override.params).includes("Headless"), `user agent override ${JSON.stringify(override?.params)}`);
      const navigate = calls().find((c) => c.method === "Page.navigate");
      assert(navigate?.sessionId === "S1" && navigate.params.url === "https://console.jumpcloud.com/login" &&
        methods.indexOf("Emulation.setUserAgentOverride") < methods.indexOf("Page.navigate"), `navigate ${JSON.stringify(navigate)}`);
      assert(!methods.includes("Browser.setWindowBounds") && !methods.includes("Browser.getWindowForTarget"),
        `a headless relay placed a window: ${methods}`);
      assert(methods.includes("Storage.getCookies") && methods.includes("Browser.close"), `calls ${methods}`);
      await until("relay Chrome gone (and reaped)", () => !alive(launch.pid), 8000);
      assert(!lines("cdp.jsonl").some((c) => c.pid === launch.pid && c.signal), "the relay Chrome had to be killed after Browser.close");
      const reloads = await until("tab reloaded", () => {
        const seen = requests.filter((r) => r.path.startsWith("/login?n=1"));
        return seen.length >= 2 && seen;
      }, 8000);
      const sent = reloads.at(-1).cookie;
      assert(sent.includes("jcsession=relay-session-1") && sent.includes("jcuser=relay-user-1") && !sent.includes("stale") &&
        !sent.includes("rayonly"), "the reload didn't carry Chrome's JumpCloud session alone");
      const cookies = await rayCookies();
      const ours = jumpcloudIn(cookies);
      assert(ours.map((c) => c.name).sort().join() === "jcsession,jcuser", `JumpCloud cookies in Ray: ${ours.map((c) => c.name)}`);
      const session = ours.find((c) => c.name === "jcsession");
      assert(session.value === "relay-session-1" && session.session === true && session.httpOnly && session.domain === "console.jumpcloud.com",
        "the session cookie didn't come over as Chrome had it");
      assert(!cookies.some((c) => ["other", "lookalike", "suffix"].includes(c.name)), "a cookie from another site came over");
      state = await relay();
      assert(state.state === "idle" && state.chromeRunning === false, `after: ${JSON.stringify(state)}`);

      // Signed in already: the login page moves on by itself, so nothing relays.
      await goTo("/login?n=2");
      await sleep(3000);
      state = await relay();
      assert(state.launches === 1 && state.lastResult === "signedIn", `relayed while signed in: ${JSON.stringify(state)}`);

      // A login page JumpCloud keeps showing: a second try relays (and reloads, landing on it again), the third is a
      // note, not another Chrome.
      await goTo("/login?n=loop&stay=1");
      await until("second relay", async () => (await relay()).launches === 2, 15000);
      await until("loop guard", async () => (await relay()).lastResult === "loopGuard", 20000);
      assert(latest().jumpCloudRelay.launches === 2 && latest().toast.includes("Still not signed in"), `loop: ${latest().toast}`);

      // Never from a private window.
      await ok("menu newPrivateWindow");
      await until("private window", async () => (await now()).private === true && latest().commandBar);
      await ok("type https://console.jumpcloud.com/login?n=private");
      await ok("enter");
      await until("private login page", () => requests.some((r) => r.path === "/login?n=private"), 10000);
      await sleep(1000);
      state = await relay();
      assert(state.launches === 2 && state.lastResult === "loopGuard", `a private window relayed: ${JSON.stringify(state)}`);
      await ok("closewindow private");
      await until("back to the normal window", async () => (await now()).private === false, 8000);

      // Headless never gets there, Ray in full screen: headless Chrome closes, a visible one opens the 440×620 window,
      // and Ray says so with a button instead of leaving its Space; the button brings Chrome forward.
      mode("headlessNever");
      await ok("jumpcloud fullscreen on");
      let before = lines("launches.jsonl").length;
      await signOut();
      await goTo("/login?n=fb", true);
      // Headless shows no window, so Ray says it is signing in until the relay ends.
      await until("signing-in note", async () => (await now()).toast.includes("Signing in with JumpCloud Go"), 6000, 50);
      await until("fallback note", async () => (await now()).toast.includes("Finish signing in to JumpCloud in Chrome"), 8000, 50);
      state = latest().jumpCloudRelay;
      assert(state.fallbacks === 1 && state.mode === "window" && state.activations === 0 && state.launches === before + 2,
        `full-screen fallback ${JSON.stringify(state)}`);
      const [headlessRun, windowRun] = lines("launches.jsonl").slice(before);
      assert(headlessRun.argv.includes("--headless=new") && JSON.stringify(windowRun.argv) === JSON.stringify(base),
        `fallback arguments ${JSON.stringify([headlessRun.argv, windowRun.argv])}`);
      assert(callsOf(headlessRun.pid).some((c) => c.method === "Browser.close"), "headless Chrome wasn't closed");
      const shown = callsOf(windowRun.pid).find((c) => c.method === "Target.createTarget");
      assert(shown.params.url === "https://console.jumpcloud.com/login" && shown.params.newWindow === true &&
        shown.params.width === 440 && shown.params.height === 620, `fallback createTarget ${JSON.stringify(shown.params)}`);
      const placed = callsOf(windowRun.pid).find((c) => c.method === "Browser.setWindowBounds");
      assert(placed?.params.bounds.width === 440 && placed.params.bounds.height === 620, `window bounds ${JSON.stringify(placed)}`);
      await ok("jumpcloud showchrome");
      assert((await relay()).activations === 1, "the note's button didn't bring Chrome forward");
      await until("signed in through the window", async () => (await relay()).lastResult === "signedIn", 10000);
      assert(latest().jumpCloudRelay.cookiesImported === 2 && latest().jumpCloudRelay.lastMode === "window", "fallback import");
      await until("fallback Chromes gone", () => !alive(headlessRun.pid) && !alive(windowRun.pid), 10000);
      assert(!lines("cdp.jsonl").some((c) => c.pid === headlessRun.pid && c.signal), "headless Chrome had to be killed");

      // Not in full screen: the fallback window comes forward by itself, as before.
      await ok("jumpcloud fullscreen off");
      before = lines("launches.jsonl").length;
      await signOut();
      await goTo("/login?n=fb2", true);
      await until("fallback in front", async () => (await relay()).fallbacks === 2 && latest().jumpCloudRelay.activations === 2, 8000, 50);
      await until("signed in again", async () => (await relay()).lastResult === "signedIn", 10000);
      for (const started of lines("launches.jsonl").slice(before)) await until("Chrome gone", () => !alive(started.pid), 10000);

      // The user never finishes: headless, then the window, then the deadline closes Chrome and says so.
      mode("never");
      before = lines("launches.jsonl").length;
      await signOut();
      await goTo("/login?n=3", true);
      await until("timed out", async () => (await relay()).lastResult === "timedOut", 12000);
      assert(latest().toast.includes("didn't finish") && latest().jumpCloudRelay.launches === before + 2, `deadline: ${latest().toast}`);
      for (const never of lines("launches.jsonl").slice(before)) await until("timed-out Chrome gone", () => !alive(never.pid), 10000);

      // A Chrome that never answers its pipe (policy RemoteDebuggingAllowed off): given up on, and killed; headless
      // first, then once more with a window.
      mode("silent");
      before = lines("launches.jsonl").length;
      await signOut();
      await goTo("/login?n=4", true);
      await until("no answer", async () => (await relay()).lastResult === "noAnswer", 12000);
      assert(latest().toast.includes("didn't answer") && latest().jumpCloudRelay.launches === before + 2,
        `silent: ${latest().toast} ${JSON.stringify(latest().jumpCloudRelay)}`);
      const silent = lines("launches.jsonl").slice(before);
      assert(silent[0].argv.includes("--headless=new") && !silent[1].argv.includes("--headless=new"), "silent fallback arguments");
      for (const quiet of silent) await until("silent Chrome gone", () => !alive(quiet.pid), 10000);

      // Set Up…: the Web Store page at Chrome's own size; Chrome quits when its window closes.
      mode("setup");
      await ok("settings open passwords");
      await until("passwords pane", async () => (await now()).settingsWindow.pane === "passwords");
      const rows = latest().settingsWindow.rows.passwords;
      assert(rows.includes("jumpCloudRelay") && rows.includes("jumpCloudRelay.setup"), `passwords rows ${rows}`);
      assert(latest().jumpCloudRelay.status.includes("installed"), `status ${latest().jumpCloudRelay.status}`);
      await ok("settings close");
      before = lines("launches.jsonl").length;
      await ok("jumpcloud setup");
      await until("setup", async () => (await relay()).lastResult === "setup" && latest().jumpCloudRelay.launches === before + 1);
      const setup = lines("launches.jsonl")[before];
      assert(JSON.stringify(setup.argv) === JSON.stringify(base), `setup arguments ${JSON.stringify(setup.argv)}`);
      const setupCalls = lines("cdp.jsonl").filter((c) => c.pid === setup.pid);
      const store = setupCalls.find((c) => c.method === "Target.createTarget");
      assert(store.params.url === "https://chromewebstore.google.com/detail/jdoahkhfkeipblhbhppmcbdgapeoaopa" &&
        store.params.width === undefined && !setupCalls.some((c) => c.method === "Browser.setWindowBounds"), `setup ${JSON.stringify(store.params)}`);
      await until("setup Chrome quit after its window closed", async () => !alive(setup.pid) && !(await relay()).chromeRunning, 10000);

      // The signature check: Ray's own test app isn't Google Chrome; the real one (when installed) is.
      assert((await run(`jumpcloud verify ${app}`)) === "invalid", "Ray's test app passed as Google Chrome");
      if (existsSync("/Applications/Google Chrome.app"))
        assert((await run("jumpcloud verify /Applications/Google Chrome.app")) === "valid", "Google Chrome failed its own check");

      await ok("setting jumpCloudRelay off");
      it.stdin.write("menu quit\n");
      assert((await Promise.race([exit, sleep(15000).then(() => "timeout")])) !== "timeout", "the instance didn't quit within 15 s");
      for (const started of lines("launches.jsonl")) assert(!alive(started.pid), "a stand-in Chrome outlived Ray");
    } finally {
      socket?.close();
      jc.close();
      if (it.exitCode === null && it.signalCode === null) it.kill("SIGKILL");
      for (const started of lines("launches.jsonl")) if (alive(started.pid)) process.kill(started.pid, "SIGKILL");
      rmSync(dir, { recursive: true, force: true });
    }
  },
  async "settings-appearance-mode"() {
    // Light, Dark or Automatic: NSApp's appearance, which the window (and every view of Ray's) takes, and which pages
    // hear as prefers-color-scheme, as Chrome's do.
    await resetSettings();
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    const { sessionId } = await session("/a");
    const pageDark = () => evaluate(sessionId, `matchMedia("(prefers-color-scheme: dark)").matches`);
    const looks = () => state().looks;
    assert(looks().appearance === "auto", `the default isn't automatic: ${JSON.stringify(looks())}`);
    for (const mode of ["dark", "light", "dark"]) {
      await setSetting("appearanceMode", mode);
      await until(`${mode} app`, async () => { await command("state"); return looks().appearance === mode && looks().effective === mode && looks().window === mode; });
      await until(`${mode} page`, async () => (await pageDark()) === (mode === "dark"), 5000);
    }
    if (process.env.SNAP_DIR) await command(`toolbarsnap ${join(process.env.SNAP_DIR, "toolbar-forced-dark.png")}`);
    await setSetting("appearanceMode", "auto");
    await until("automatic", async () => { await command("state"); return looks().appearance === "auto" && looks().window === looks().effective; });
    await resetSettings();
  },
  async "settings-scroll-bars"() {
    // Always: classic scroll bars that take room in the page; When scrolling: overlay ones that take none. Open pages
    // switch at once (Chromium reads NSScroller's preferred style and hears its change notice).
    await resetSettings();
    await goTo(`${origin}/long?scrollbars`, true);
    await until("long page", async () => { await command("state"); return activeTabState()?.url.includes("/long?scrollbars"); });
    const { sessionId } = await session("/long?scrollbars");
    const room = () => evaluate(sessionId, `innerWidth - document.documentElement.clientWidth`);
    await setSetting("scrollBars", "always");
    await until("legacy scrollers", async () => { await command("state"); return state().looks.scrollers === "legacy"; });
    await until("the page has a scroll bar", async () => (await room()) > 0, 5000);
    await setSetting("scrollBars", "scrolling");
    await until("overlay scrollers", async () => { await command("state"); return state().looks.scrollers === "overlay"; });
    await until("the page's scroll bar takes no room", async () => (await room()) === 0, 5000);
    await setSetting("scrollBars", "system");
    await send("Target.closeTarget", { targetId: (await targets()).find((t) => t.url.includes("/long?scrollbars")).targetId });
    await until("long page closed", async () => { await command("state"); return !tabFor("/long?scrollbars"); });
    await resetSettings();
  },
  async "settings-page-address-bar"() {
    // One setting for every window; View › Show Address Bar on Page flips it. An older Sidebar.json's choice moves in.
    await resetSettings();
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", async () => { await command("state"); return state().active === tabFor("/a").id && state().toolbar !== null; });
    await setSetting("pageAddressBar", "off");
    await until("bar off", async () => { await command("state"); return state().toolbar === null && state().sidebarAddressShown === true; });
    await command("menu toggleToolbar");
    await until("the menu turned the setting on", async () => { await command("state"); return state().settings.pageAddressBar === true && state().toolbar !== null; });
    await command("menu toggleToolbar");
    await until("and off", async () => { await command("state"); return state().settings.pageAddressBar === false && state().toolbar === null; });
    await resetSettings();
    await until("bar back", async () => { await command("state"); return state().toolbar !== null; });

    const dir = mkdtempSync(join(tmpdir(), "ray-page-address-bar-"));
    const sidebarFile = join(dir, "Sidebar.json");
    writeFileSync(sidebarFile, JSON.stringify({ favorites: [], pinned: [], today: [], sidebarHidden: false, pageToolbar: false }));
    let log = "";
    const it = spawn(join(app, "Contents/MacOS/Ray"), [], {
      env: { ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_LOG_STATE: "1", RAY_DATA_DIR: dir,
        RAY_DOWNLOADS_DIR: join(dir, "Downloads"), RAY_START_URL: `${origin}/a`,
        RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}.pagebar` },
      stdio: ["pipe", "ignore", "pipe"],
    });
    const exit = new Promise((r) => it.on("exit", (code, signal) => r(code ?? signal)));
    it.stdin.on("error", () => {});
    it.stderr.setEncoding("utf8");
    it.stderr.on("data", (chunk) => { log += chunk; });
    try {
      const marker = "[ray-test] settings catalog -> ";
      const from = log.length;
      it.stdin.write("settings catalog\n");
      const line = await until("catalog", () => { const at = log.indexOf(marker, from); return at >= 0 ? log.slice(at + marker.length).split("\n")[0] : null; }, 25000, 150);
      const value = JSON.parse(line).find((k) => k.id === "pageAddressBar").value;
      assert(value === "off", `an older Sidebar.json's address bar off became ${value}`);
      await until("moved out of Sidebar.json", () => !("pageToolbar" in JSON.parse(readFileSync(sidebarFile, "utf8"))), 5000);
      await until("saved in Settings.json", () => existsSync(join(dir, "Settings.json")) && JSON.parse(readFileSync(join(dir, "Settings.json"), "utf8")).pageAddressBar === false, 5000);
    } finally {
      it.kill("SIGTERM");
      await Promise.race([exit, sleep(10000)]);
      rmSync(dir, { recursive: true, force: true });
    }
  },
  async "settings-sidebar-button"() {
    // Off: no sidebar button in the sidebar's top row, nor in the address bar while the sidebar is hidden (back,
    // forward and reload move up a place); ⌘S still toggles the sidebar.
    await needsFrames();
    await resetSettings();
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", async () => { await command("state"); return state().active === tabFor("/a").id && state().toolbar !== null; });
    const field = () => state().toolbar.field;
    const hiddenBar = async (shown) => {
      await command("key s cmd keywin");
      await until("sidebar hidden", async () => { await command("state"); return state().sidebar.hidden && state().toolbar.navigationProgress === 1; }, 4000, 50);
      assert(field().sidebarButton === shown, `sidebar button ${field().sidebarButton}, wanted ${shown}`);
      assert(Math.abs(field().backX - (shown ? 56 : 21)) <= 1 && field().addressX === (shown ? 145 : 110), `back at ${field().backX}, address at ${field().addressX}`);
      await command("key s cmd keywin");
      await until("sidebar back", async () => { await command("state"); return !state().sidebar.hidden && state().toolbar.navigationProgress === 0; }, 4000, 50);
    };
    assert(state().sidebarFrames.toggleShown === "1", "no sidebar button by default");
    await hiddenBar(true);
    await setSetting("showSidebarButton", "off");
    await until("button gone", async () => { await command("state"); return state().sidebarFrames.toggleShown === "0"; });
    await hiddenBar(false);
    await setSetting("showSidebarButton", "on");
    await until("button back", async () => { await command("state"); return state().sidebarFrames.toggleShown === "1"; });
    await resetSettings();
  },
  async "settings-fade-unloaded"() {
    // On: a tab whose page isn't loaded (here a pinned tab closed back to its row) shows its icon faded; off (the
    // default, Arc's look), nothing is.
    await resetSettings();
    await send("Target.createTarget", { url: `${origin}/b?fade` });
    const tab = await until("fade tab", () => tabFor("?fade"));
    const entry = await until("fade row", () => entryOfTab(tab.id));
    const pinnedEntry = () => state().sidebar.pinned.find((e) => e.id === entry.id);
    const faded = () => (state().sidebarFrames.fadedIcons ?? "").split(",").filter(Boolean);
    await command(`rowaction pin ${entry.id}`);
    await until("pinned", () => pinnedEntry());
    // Unloaded as when its page closes itself (the row's − would also put it in Recently Closed).
    await send("Target.closeTarget", { targetId: (await targets()).find((t) => t.url.includes("?fade")).targetId });
    await until("unloaded", async () => { await command("state"); return pinnedEntry()?.live === false; });
    await settle();
    assert(faded().length === 0, `icons faded with the setting off: ${faded()}`);
    await setSetting("fadeUnloadedTabs", "on");
    await until("faded", async () => { await command("state"); return faded().includes(entry.id); });
    assert(faded().every((id) => !allEntries().find((e) => e.id === id)?.live), `a live tab faded: ${faded()}`);
    await command(`row ${entry.id}`);
    await until("loaded again, whole", async () => { await command("state"); return pinnedEntry()?.live && !faded().includes(entry.id); });
    await command(`rowaction unpin ${entry.id}`);
    await until("unpinned", () => !pinnedEntry());
    await send("Target.closeTarget", { targetId: (await targets()).find((t) => t.url.includes("?fade")).targetId });
    await until("closed", async () => { await command("state"); return !tabFor("?fade"); });
    await resetSettings();
  },
  async "settings-reorder-haptics"() {
    // On (the default): a tick each time a dragged tab moves to a new place; off: none.
    try {
      await resetSettings();
      await todayTabs(3);
      const dragFirstBelowThird = async () => {
        const [first, , third] = state().sidebar.today;
        const a = frameOf(first.id);
        await command(`press ${a.cx} ${a.cy}`);
        await command(`move ${a.cx} ${a.cy + 10}`);
        await settle();
        const c = frameOf(third.id);
        await command(`move ${a.cx} ${c.cy + 4}`);
        await command(`release ${a.cx} ${c.cy + 4}`);
        await until("moved down", () => state().sidebar.today.findIndex((e) => e.id === first.id) > 0);
        await settle();
      };
      const before = state().hapticTicks;
      await dragFirstBelowThird();
      assert(state().hapticTicks > before, `no tick while reordering (${before} -> ${state().hapticTicks})`);
      await setSetting("tabReorderHaptics", "off");
      const off = state().hapticTicks;
      await dragFirstBelowThird();
      assert(state().hapticTicks === off, `ticked with the setting off (${off} -> ${state().hapticTicks})`);
      await resetSettings();
    } catch (error) {
      // Keys and clicks stop reaching a window the user's Space switch left behind (known noise, CLAUDE.md).
      await resetSettings().catch(() => {});
      if (state()?.windowOnActiveSpace === false) throw new Skip("the test window left the active Space mid-check");
      throw error;
    }
  },
  async "settings-undo-reopens"() {
    // On: ⌘Z outside text reopens the last closed tab (again: the one before), through ⇧⌘T's list; in an editable
    // element of the page it still undoes typing. Off (the default): Edit › Undo is AppKit's own.
    try {
      await resetSettings();
      const undo = () => state().undo;
      const open = async (tag) => {
        await send("Target.createTarget", { url: `${origin}/b?${tag}` });
        return until(tag, async () => { await command("state"); const t = tabFor(`?${tag}`); return t && entryOfTab(t.id) && t; });
      };
      const select = async (tag) => {
        await command(`row ${entryOfTab(tabFor(`?${tag}`).id).id}`);
        await until(`${tag} active`, async () => { await command("state"); return state().active === tabFor(`?${tag}`)?.id; });
      };
      const closeActive = async (tag) => {
        await command("key w cmd keywin");
        await until(`${tag} closed`, async () => { await command("state"); return !tabFor(`?${tag}`); }, 5000);
      };
      const cmdZ = () => command("key z cmd keywin");
      const back = (tag) => until(`${tag} back`, async () => { await command("state"); return tabFor(`?${tag}`) && state().active === tabFor(`?${tag}`).id; }, 5000);
      await command("state");
      const closedBefore = state().recentlyClosed.items.length;
      for (const tag of ["undoOne", "undoTwo", "undoStay"]) await open(tag);
      await select("undoOne");
      await closeActive("undoOne");
      await select("undoStay");
      assert(undo().target === false && undo().reopens === false && undo().title === "Undo", `off: ${JSON.stringify(undo())}`);
      const tabs = state().tabs.length;
      await cmdZ();
      await sleep(600);
      await command("state");
      assert(state().tabs.length === tabs && !tabFor("?undoOne"), "⌘Z reopened a tab with the setting off");

      await setSetting("undoReopensClosedTab", "on");
      await until("Edit › Undo is Ray's", async () => { await command("state"); return undo().target && undo().reopens && undo().title === "Undo Close Tab"; });
      await cmdZ();
      await back("undoOne");
      // Two closed: ⌘Z brings the last one back, ⌘Z again the one before.
      await closeActive("undoOne");
      await select("undoTwo");
      await closeActive("undoTwo");
      await select("undoStay");
      await cmdZ();
      await back("undoTwo");
      await cmdZ();
      await back("undoOne");

      // Typing in the page: ⌘Z undoes it and reopens nothing.
      await select("undoOne");
      await closeActive("undoOne");
      await select("undoStay");
      const { sessionId } = await session("?undoStay");
      assert(await evaluate(sessionId, `(() => { const f = document.createElement("input"); f.id = "undoField"; document.body.append(f); f.focus(); return document.activeElement === f; })()`), "the field didn't take focus");
      await send("Input.insertText", { text: "typed" }, sessionId);
      await until("typed", async () => (await evaluate(sessionId, `document.getElementById("undoField").value`)) === "typed");
      await until("the page edits text", async () => { await command("state"); return undo().editsText === true && undo().reopens === false && undo().title === "Undo"; }, 5000);
      await cmdZ();
      await until("typing undone", async () => (await evaluate(sessionId, `document.getElementById("undoField").value`)) === "", 5000);
      await command("state");
      assert(!tabFor("?undoOne"), "⌘Z in a text field reopened a tab");
      // Out of the field, ⌘Z reopens again.
      await evaluate(sessionId, `document.getElementById("undoField").blur()`);
      await until("no text focused", async () => { await command("state"); return undo().editsText === false && undo().reopens === true; }, 5000);
      await cmdZ();
      await back("undoOne");

      // Ray's own text: in the command bar ⌘Z is the field's.
      await command("menu focusAddress");
      await until("command bar", async () => { await command("state"); return state().commandBar; });
      assert(undo().editsText === true && undo().reopens === false, `the command bar: ${JSON.stringify(undo())}`);
      await command("escape");
      await setSetting("undoReopensClosedTab", "off");
      await until("Edit › Undo is AppKit's again", async () => { await command("state"); return undo().target === false && undo().title === "Undo"; });
      // Closed as a page closes itself, so Recently Closed (which reopen-closed-tab counts) gets nothing more.
      for (const tag of ["undoOne", "undoTwo", "undoStay"]) {
        const target = (await targets()).find((t) => t.url.includes(`?${tag}`));
        if (target) await send("Target.closeTarget", { targetId: target.targetId });
        await until(`${tag} closed`, async () => { await command("state"); return !tabFor(`?${tag}`); }, 5000);
      }
      assert(state().recentlyClosed.items.length === closedBefore, `the check left ${state().recentlyClosed.items.length - closedBefore} closed tabs behind`);
      await resetSettings();
    } catch (error) {
      // Keys and clicks stop reaching a window the user's Space switch left behind (known noise, CLAUDE.md).
      await resetSettings().catch(() => {});
      if (state()?.windowOnActiveSpace === false) throw new Skip("the test window left the active Space mid-check");
      throw error;
    }
  },
  async "settings-shortcut-editor"() {
    // Settings › Shortcuts lists Ray's menu commands by menu; a field records the next key press (⌘ or ⌃ with a key, or
    // a function key), which the menu, the command bar and the reserved-key routing then follow. A key another command
    // has asks to Replace it; macOS's keys and the locked commands' are refused; Delete leaves none; Reset All brings
    // Ray's keys back.
    const editor = async () => JSON.parse(await commandResult("shortcuts state"));
    const keys = () => state().shortcuts.keys;
    const saved = () => state().settings.shortcuts ?? {};
    const row = (ed, id) => ed.rows.find((r) => r.id === id);
    const openPane = async () => {
      await command("settings open shortcuts");
      await until("shortcuts pane", async () => { await command("state"); return state().settingsWindow.open && state().settingsWindow.pane === "shortcuts"; });
    };
    let tab = null;
    try {
      await resetSettings();
      await openPane();
      let ed = await editor();
      for (const group of ["Ray", "File", "Edit", "View", "History", "Window"]) assert(ed.groups.includes(group), `groups ${ed.groups}`);
      for (const id of ["newTab", "closeTab", "copyURL", "toggleSidebar", "reopenClosedTab", "zoomIn", "selectTab1", "nextTab"])
        assert(row(ed, id), `${id} isn't listed: ${ed.rows.map((r) => r.id)}`);
      // macOS's own items aren't listed (their keys stay theirs); Quit and Settings are, and can't change.
      assert(!ed.rows.some((r) => ["Copy", "Paste", "Undo", "Minimize", "Hide Ray", "Enter Full Screen"].includes(r.title)), `system items listed: ${ed.rows.map((r) => r.title)}`);
      assert(row(ed, "quit").locked && row(ed, "showSettings").locked && !row(ed, "newTab").locked, "locked rows");
      assert((await commandResult("shortcuts record quit")) === "no such command", "Quit started recording");
      assert(row(ed, "copyURL").field === "⇧⌘C" && row(ed, "zoomIn").field === "⌘+" && !ed.resetAllEnabled, `fields ${JSON.stringify(row(ed, "copyURL"))}`);
      if (process.env.SNAP_DIR) {
        await command("shortcuts scroll");
        await command(`settings snap ${join(process.env.SNAP_DIR, "shortcut-editor.png")}`);
      }
      // Search by title.
      await command("shortcuts search zoom");
      ed = await editor();
      assert(ed.rows.length >= 2 && ed.rows.every((r) => /zoom/i.test(`${r.title} ${r.menu}`)) && row(ed, "zoomIn"), `zoom: ${ed.rows.map((r) => r.title)}`);
      await command("shortcuts search zzqqx");
      ed = await editor();
      assert(ed.rows.length === 0 && ed.empty, `nothing matches: ${JSON.stringify(ed.rows)}`);
      await command("shortcuts search");

      // Record ⌃⌘K for Copy URL. A key without ⌘ or ⌃, macOS's ⌘Q and Edit's ⌘C are refused; it keeps listening.
      await command("shortcuts record copyURL");
      ed = await editor();
      assert(ed.recording === "copyURL" && row(ed, "copyURL").field === "Type Shortcut", `recording ${JSON.stringify(ed)}`);
      if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "shortcut-recording.png")}`);
      for (const [press, says] of [["k", "⌘ or ⌃"], ["k opt", "⌘ or ⌃"], ["q cmd", "macOS"], ["c cmd", "Copy"], ["3 cmd shift", "screenshot"]]) {
        await command(`shortcuts type ${press}`);
        ed = await editor();
        assert(ed.recording === "copyURL" && ed.notice?.kind === "problem" && ed.notice.text.includes(says), `${press}: ${JSON.stringify(ed.notice)}`);
      }
      await command("state");
      assert(keys().copyURL === "⇧⌘C" && !("copyURL" in saved()), `a refused key changed Copy URL: ${keys().copyURL}`);
      await command("shortcuts type k ctrl cmd");
      await until("⌃⌘K saved", async () => { await command("state"); return saved().copyURL === "ctrl+cmd+k" && keys().copyURL === "⌃⌘K"; });
      ed = await editor();
      assert(ed.recording === null && ed.notice === null && row(ed, "copyURL").customized && row(ed, "copyURL").field === "⌃⌘K" && ed.resetAllEnabled, `after recording ${JSON.stringify(ed)}`);
      assert(state().menuKeys.copyURL === "k", `the menu item's key ${state().menuKeys.copyURL}`);

      // The new key copies the page's address; ⇧⌘C no longer does.
      await closeSettingsWindow();
      await goTo(`${origin}/b?editorA`, true);
      tab = await until("tab", async () => { await command("state"); return activeTabState()?.url.endsWith("?editorA") && activeTabState(); });
      const urlA = activeTabState().url;
      await command("key k ctrl cmd");
      await until("⌃⌘K copied", async () => { await command("state"); return state().pasteboard === urlA; });
      await goTo(`${origin}/b?editorB`);
      await until("editorB", async () => { await command("state"); return activeTabState()?.url.endsWith("?editorB"); });
      await command("key c cmd shift");
      await sleep(600);
      await command("state");
      assert(state().pasteboard === urlA, `⇧⌘C still copied: ${state().pasteboard}`);
      // The command bar shows Copy URL's new key.
      await command("menu newTab");
      await until("bar open", async () => { await command("state"); return state().commandBar; });
      await command("type copy url");
      const bar = await until("copy url row", async () => { await command("state"); return state().commandBar?.query === "copy url" && state().commandBar; });
      const action = bar.rows.find((r) => r.kind === "action" && r.title === "Copy URL");
      assert(action?.detail === "⌃⌘K", `the command bar shows ${JSON.stringify(action)}`);
      await command("escape");
      await until("bar closed", async () => { await command("state"); return state().commandBar === null; });

      // Conflict → Replace: ⌃⌘K for New Folder takes it from Copy URL, which then has none.
      await openPane();
      await command("shortcuts record newFolder");
      await command("shortcuts type k ctrl cmd");
      ed = await editor();
      assert(ed.notice?.kind === "conflict" && ed.notice.holder === "copyURL" && ed.notice.combo === "⌃⌘K" && ed.recording === null, `conflict ${JSON.stringify(ed.notice)}`);
      await command("state");
      assert(saved().copyURL === "ctrl+cmd+k" && !("newFolder" in saved()), "the conflict changed a key before Replace");
      if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "shortcut-conflict.png")}`);
      await command("shortcuts replace");
      await until("replaced", async () => { await command("state"); return saved().newFolder === "ctrl+cmd+k" && saved().copyURL === "none" && keys().newFolder === "⌃⌘K" && keys().copyURL === ""; });
      // Cancel leaves both: ⌘D is Pin Tab's (by default).
      await command("shortcuts record reload");
      await command("shortcuts type d cmd");
      ed = await editor();
      assert(ed.notice?.kind === "conflict" && ed.notice.holder === "togglePin", `⌘D: ${JSON.stringify(ed.notice)}`);
      await command("shortcuts cancel");
      ed = await editor();
      await command("state");
      assert(ed.notice === null && keys().reload === "⌘R" && keys().togglePin === "⌘D" && !("reload" in saved()), `after Cancel ${JSON.stringify(keys())}`);
      // Replacing a default: Pin Tab's ⌘D yields while Reload has it, and is back once Reload is reset.
      await command("shortcuts record reload");
      await command("shortcuts type d cmd");
      await command("shortcuts replace");
      await until("⌘D is Reload's", async () => { await command("state"); return keys().reload === "⌘D" && keys().togglePin === "" && saved().reload === "cmd+d" && !("togglePin" in saved()); });
      await command("shortcuts reset reload");
      await until("Reload reset", async () => { await command("state"); return keys().reload === "⌘R" && keys().togglePin === "⌘D" && !("reload" in saved()); });

      // Delete leaves a command with none; Escape changes nothing.
      await command("shortcuts record find");
      await command("shortcuts type delete");
      await until("Find has none", async () => { await command("state"); return saved().find === "none" && keys().find === ""; });
      ed = await editor();
      assert(row(ed, "find").field === "None" && ed.recording === null, `Find's field ${JSON.stringify(row(ed, "find"))}`);
      await command("shortcuts record findNext");
      await command("shortcuts type esc");
      ed = await editor();
      await command("state");
      assert(ed.recording === null && keys().findNext === "⌘G" && !("findNext" in saved()), "Escape changed Find Next");

      // Reserved keys follow their command: New Tab on ⌃⌘J reaches Ray before the page; ⌘T is the page's.
      await command("shortcuts record newTab");
      await command("shortcuts type j ctrl cmd");
      await until("New Tab on ⌃⌘J", async () => { await command("state"); return keys().newTab === "⌃⌘J" && state().shortcuts.reserved.includes("⌃⌘J") && !state().shortcuts.reserved.includes("⌘T"); });
      await closeSettingsWindow();
      await command("key j ctrl cmd keywin");
      await until("⌃⌘J opened the command bar", async () => { await command("state"); return state().commandBar; }, 5000);
      await command("escape");
      await until("bar closed", async () => { await command("state"); return state().commandBar === null; });
      await command("key t cmd keywin");
      await sleep(600);
      await command("state");
      assert(state().commandBar === null, "⌘T still opened the command bar");

      // Reset All: Ray's own keys again, reserved ones too.
      await openPane();
      await command("shortcuts resetall");
      await until("reset", async () => {
        await command("state");
        return Object.keys(saved()).length === 0 && keys().copyURL === "⇧⌘C" && keys().find === "⌘F" && keys().newTab === "⌘T" &&
          keys().newFolder === "⌥⌘N" && state().shortcuts.reserved.includes("⌘T") && !state().shortcuts.reserved.includes("⌃⌘J");
      });
      ed = await editor();
      assert(!ed.resetAllEnabled && !ed.rows.some((r) => r.customized), "Reset All left a customized row");
      await closeSettingsWindow();
    } finally {
      await command("shortcuts search").catch(() => {});
      await resetSettings().catch(() => {});
      await closeSettingsWindow().catch(() => {});
      if (tab) {
        // Closed as a page closes itself, so Recently Closed (which reopen-closed-tab counts) gets nothing more.
        const target = (await targets()).find((t) => t.url.includes("?editorB") || t.url.includes("?editorA"));
        if (target) await send("Target.closeTarget", { targetId: target.targetId });
        await until("editor tab closed", async () => { await command("state"); return !state().tabs.some((t) => t.id === tab.id); });
      }
    }
  },
  async "reopen-closed-tab"() {
    const today = () => state().sidebar.today;
    const indexOf = (urlPart) => today().findIndex((e) => e.url.includes(urlPart));
    const closed = () => state().recentlyClosed;
    const shiftCmdT = () => command("key t cmd shift keywin");
    const closeActive = async (urlPart) => {
      const before = state().tabs.length;
      await command("key w cmd keywin");
      await until(`${urlPart} closed`, async () => { await command("state"); return state().tabs.length === before - 1 && indexOf(urlPart) < 0; }, 5000);
    };
    const select = async (urlPart) => {
      const entry = today().find((e) => e.url.includes(urlPart));
      await command(`row ${entry.id}`);
      await until(`${urlPart} active`, () => state().activeEntry === entry.id && state().active !== null);
    };
    // Back in the sidebar (at this index, when given), live, active and the one page showing.
    const reopened = (urlPart, index) => until(`${urlPart} back at ${index}`, async () => {
      await command("state");
      const at = indexOf(urlPart);
      const entry = today()[at];
      return at >= 0 && (index === undefined || at === index) && entry.live && state().activeEntry === entry.id && oneVisibleActive() && entry;
    }, 8000);

    // Two Today tabs, X and then Y; X has back history (/h, then /b).
    await send("Target.createTarget", { url: `${origin}/h?reopenX` });
    await until("X", () => tabFor("?reopenX"));
    const x = await session("?reopenX");
    await evaluate(x.sessionId, `location.href = ${JSON.stringify(origin + "/b?reopenX")}`);
    await until("X has history", async () => { await command("state"); return tabFor("/b?reopenX")?.canGoBack; });
    await send("Target.createTarget", { url: `${origin}/c?reopenY` });
    await until("Y", () => tabFor("?reopenY") && indexOf("?reopenY") >= 0);
    await select("?reopenX");
    const atX = indexOf("?reopenX");
    const atY = indexOf("?reopenY");
    assert(atX >= 0 && atY >= 0 && today().length > 2, `X at ${atX}, Y at ${atY}`);

    // ⌘W, then ⇧⌘T: back in its place, active, with its history.
    await closeActive("?reopenX");
    assert(closed().reopenEnabled === true, "Reopen Closed Tab is off with a tab to reopen");
    const listed = closed().items[0];
    assert(listed?.title === "Page B" && listed.tooltip === "127.0.0.1", `Recently Closed lists ${JSON.stringify(listed)}`);
    await shiftCmdT();
    await reopened("?reopenX", atX);
    await until("history restored", async () => { await command("state"); return activeTabState()?.canGoBack; });
    await command("menu goBack");
    await until("back to /h", async () => { await command("state"); return activeTabState()?.url.includes("/h?reopenX"); });
    await command("menu goForward");
    await until("forward to /b", async () => { await command("state"); return activeTabState()?.url.includes("/b?reopenX"); });

    // Close X, then Y: ⇧⌘T brings Y back first, then X, and both are where they were.
    await closeActive("?reopenX");
    await select("?reopenY");
    await closeActive("?reopenY");
    assert(JSON.stringify(closed().items.slice(0, 2).map((i) => i.title)) === JSON.stringify(["Page C", "Page B"]),
      `Recently Closed ${JSON.stringify(closed().items)}`);
    await shiftCmdT();
    await reopened("?reopenY");
    await shiftCmdT();
    await reopened("?reopenX", atX);
    assert(indexOf("?reopenY") === atY, `Y at ${indexOf("?reopenY")}, was ${atY}`);

    // From History › Recently Closed: X, the older of the two, comes back before Y.
    await closeActive("?reopenX");
    await select("?reopenY");
    await closeActive("?reopenY");
    await command("closed 1");
    await reopened("?reopenX", atX);
    assert(closed().items[0]?.title === "Page C", `Recently Closed after reopening X ${JSON.stringify(closed().items)}`);
    await command("closed 0");
    const yEntry = await reopened("?reopenY");

    // A pinned tab: closing unloads its row; ⇧⌘T brings that same row back on the page it was on.
    const pinnedId = yEntry.id;
    await command(`rowaction pin ${pinnedId}`);
    await until("pinned", () => state().sidebar.pinned.find((e) => e.id === pinnedId));
    const y = await session("?reopenY");
    await evaluate(y.sessionId, `location.href = ${JSON.stringify(origin + "/a?reopenAway")}`);
    await until("pinned tab away", () => state().sidebar.pinned.find((e) => e.id === pinnedId)?.away);
    await command(`rowaction unload ${pinnedId}`);
    await until("pinned row unloaded", () => state().sidebar.pinned.find((e) => e.id === pinnedId)?.live === false);
    await shiftCmdT();
    await until("pinned row back on its page", async () => {
      await command("state");
      const e = state().sidebar.pinned.find((e) => e.id === pinnedId);
      return e?.live && e.url.includes("?reopenAway") && state().activeEntry === pinnedId && activeTabState()?.canGoBack;
    });
    await command(`rowaction unpin ${pinnedId}`);
    await until("unpinned", () => !state().sidebar.pinned.some((e) => e.id === pinnedId));

    // With the window closed, ⇧⌘T brings it back (with its tabs), then the tabs closed before it.
    await select("?reopenX");
    await closeActive("?reopenX");
    await command("closewindow");
    await until("window closed", async () => (await commandResult("windows")) === "0", 10000);
    // (With no window, `state` logs nothing; the reopened window's first log is new.)
    await sleep(300);
    const count = states.length;
    await command("menu reopenClosedTab");
    await until("window back", async () => { await command("state"); return states.length > count && state().sidebar; }, 8000);
    assert(!today().some((e) => e.url.includes("?reopenX")), "reopening the window reopened a closed tab too");
    await shiftCmdT();
    await until("X back after the window", async () => {
      await command("state");
      const e = today().find((e) => e.url.includes("?reopenX"));
      return e?.live && state().activeEntry === e.id;
    });

    // Deleting a page from history takes its closed tab out of Recently Closed too.
    await closeActive("?reopenX");
    const listedBefore = closed().items.length;
    assert(closed().items[0]?.title === "Page B", `Recently Closed ${JSON.stringify(closed().items)}`);
    await command(`historydelete ${origin}/b?reopenX`);
    await until("closed tab gone with its history", async () => { await command("state"); return closed().items.length === listedBefore - 1; }, 5000);

    // A private window: its own list, empty to begin with; what it closes never reaches the normal window's.
    const listedNow = () => JSON.stringify(closed().items.map((i) => [i.title, i.tooltip, i.icon]));
    const normalItems = listedNow();
    await command("menu newPrivateWindow");
    await until("private window", async () => { await command("state"); return state().private === true && state().commandBar; });
    assert(closed().reopenEnabled === false && closed().items.length === 0, `a new private window has closed tabs ${JSON.stringify(closed())}`);
    await command(`type ${origin}/b?privateReopen`);
    await command("enter");
    await until("private page", async () => { await command("state"); return state().private === true && tabFor("?privateReopen"); });
    await command("key w cmd");
    await until("private tab closed", async () => { await command("state"); return state().private === true && state().active === null; }, 5000);
    assert(closed().reopenEnabled === true && closed().items[0]?.title === "Page B", `private Recently Closed ${JSON.stringify(closed())}`);
    // ⇧⌘T in a window with no tab left.
    await shiftCmdT();
    await until("private tab back", async () => {
      await command("state");
      return state().private === true && tabFor("?privateReopen") && state().active === tabFor("?privateReopen").id;
    });
    assert(closed().reopenEnabled === false, "Reopen Closed Tab is on with nothing left to reopen");
    const tabs = state().tabs.length;
    await shiftCmdT();
    await sleep(500);
    await command("state");
    assert(state().tabs.length === tabs, "⇧⌘T with nothing to reopen opened a tab");
    await command("key w cmd");
    await until("private tab closed again", async () => { await command("state"); return state().private === true && state().active === null; }, 5000);
    await command("key w cmd keywin");
    await until("back to the normal window", async () => { await command("state"); return state().private === false; }, 5000);
    assert(listedNow() === normalItems,
      `a private tab reached the normal window's Recently Closed: ${JSON.stringify(closed().items)} vs ${normalItems}`);
    await sleep(800);
    const saved = existsSync(join(dataDir, "Sidebar.json")) ? readFileSync(join(dataDir, "Sidebar.json"), "utf8") : "";
    assert(!saved.includes("privateReopen"), "a closed private tab was written to Sidebar.json");
  },
  async "settings-routes"() {
    await resetSettings();
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    const before = activeTabState().url;
    const tabCount = state().tabs.length;
    // Typed addresses open the window and never load the page.
    for (const typed of ["ray://settings/appearance", "chrome://settings/appearance"]) {
      await closeSettingsWindow().catch(() => {});
      await goTo(typed);
      await until(`${typed} opens the window`, async () => { await command("state"); return state().settingsWindow.open; });
      await sleep(300);
      await command("state");
      assert(activeTabState().url === before && state().tabs.length === tabCount, `${typed} changed the tab: ${activeTabState().url}`);
      assert(!state().commandBar, "the command bar stayed open");
      await closeSettingsWindow();
    }
    // The same from a new tab: no tab appears.
    await goTo("ray://settings/appearance", true);
    await until("window from a new tab", async () => { await command("state"); return state().settingsWindow.open; });
    await sleep(300);
    await closeSettingsWindow();
    assert(!state().tabs.some((t) => t.url.includes("settings/appearance")), "a tab loaded Chrome's Appearance page");
    // All Settings… opens Chrome's own settings in a tab.
    await command("settings open");
    await command("settings link");
    await until("settings tab", async () => { await command("state"); return activeTabState()?.url.startsWith("chrome://settings"); }, 10000);
    const chromeSettings = await session("chrome://settings");
    await until("settings page loaded", async () => (await evaluate(chromeSettings.sessionId, `document.readyState`)) === "complete");
    const settingsTab = state().active;
    // Chrome's page moving itself to Appearance (its left menu does) opens the window and goes back.
    await closeSettingsWindow();
    await evaluate(chromeSettings.sessionId, `history.pushState({}, "", "/appearance")`);
    await until("window opened from the page", async () => { await command("state"); return state().settingsWindow.open; });
    await until("tab left Appearance", async () => { await command("state"); return !state().tabs.some((t) => t.url.includes("/appearance")); }, 6000);
    assert(state().tabs.some((t) => t.id === settingsTab), "the settings tab closed instead of going back");
    // A navigation to it (not in place) is the same.
    await closeSettingsWindow();
    await until("on chrome settings", async () => { await command("state"); return activeTabState()?.url.startsWith("chrome://settings"); });
    const again = await session("chrome://settings");
    await evaluate(again.sessionId, `location.href = "chrome://settings/appearance"`);
    await until("window opened by navigation", async () => { await command("state"); return state().settingsWindow.open; });
    await until("tab left Appearance again", async () => { await command("state"); return !state().tabs.some((t) => t.url.includes("/appearance")); }, 6000);
    await closeSettingsWindow();
    await command(`rowaction close ${entryOfTab(settingsTab).id}`);
    await until("settings tab closed", async () => { await command("state"); return !state().tabs.some((t) => t.id === settingsTab); });
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
  },
  async "settings-trimmed"() {
    // The engine's settings page has no Profiles, Appearance and behavior or Search engine (tools/trim-settings-pak.py):
    // Ray's own Settings window has them (Appearance, and the Search pane).
    await resetSettings();
    await closeSettingsWindow().catch(() => {});
    const tabCount = state().tabs.length;
    await send("Target.createTarget", { url: "chrome://settings/" });
    const page = await session("chrome://settings");
    const sid = page.sessionId;
    // Every element matching a selector, through every shadow root: the page is all web components.
    const deep = `const deep = (root, sel, out = []) => { for (const el of root.querySelectorAll("*")) if (el.shadowRoot) deep(el.shadowRoot, sel, out); root.querySelectorAll(sel).forEach((e) => out.push(e)); return out; };`;
    await until("settings page drawn", async () => (await evaluate(sid, `(() => { ${deep} return deep(document, "a[role=menuitem]").length > 0 && deep(document, "settings-main").length > 0; })()`)) === true, 15000);
    const read = () => evaluate(sid, `(() => { ${deep}
      const main = deep(document, "settings-main")[0];
      return {
        menu: deep(document, "a[role=menuitem]").map((a) => ({ id: a.id, href: a.getAttribute("href"), text: a.textContent.trim().replace(/\\s+/g, " "), shown: !a.hidden && a.offsetWidth > 0 })),
        views: [...main.shadowRoot.querySelectorAll("[slot=view]")].map((v) => v.id),
        last: main.lastRoute_ && main.lastRoute_.path,
        removed: deep(document, "settings-appearance-page-index, settings-appearance-page, settings-people-page-index, settings-people-page, settings-manage-profile").length,
        searchPage: deep(document, "settings-search-page-index, settings-search-page, settings-search-engines-page, settings-search-engines-list").length,
        path: location.pathname,
        shown: (() => { const v = [...main.shadowRoot.querySelectorAll("[slot=view]")].find((e) => e.classList.contains("active") && getComputedStyle(e).display !== "none"); const rows = v ? deep(v, "settings-toggle-button, cr-link-row").filter((e) => e.offsetHeight > 20) : []; return v ? { id: v.id, rows: rows.length } : null; })(),
      };
    })()`);
    const found = await read();
    const shownMenu = found.menu.filter((m) => m.shown);
    for (const gone of ["people", "appearance", "search"])
      assert(!found.menu.some((m) => m.id === gone || m.href === `/${gone}`), `the settings menu still has ${gone}: ${JSON.stringify(found.menu.map((m) => m.id))}`);
    for (const label of ["Profiles", "Appearance and behavior", "Search engine"])
      assert(!found.menu.some((m) => m.text === label), `the settings menu still says ${label}`);
    assert(shownMenu.length >= 8 && ["privacy", "performance", "system"].every((id) => shownMenu.some((m) => m.id === id)),
      `the rest of the menu went too: ${JSON.stringify(shownMenu.map((m) => m.id))}`);
    assert(!["people", "appearance", "search"].some((id) => found.views.includes(id)), `sections on the page: ${found.views}`);
    assert(found.views.includes("privacy") && found.views.includes("performance"), `other sections went: ${found.views}`);
    assert(found.removed === 0, `${found.removed} Appearance or Profiles elements on the page`);
    assert(found.searchPage === 0, `${found.searchPage} Search engine elements on the page`);
    // The bare address lands on Performance (the first page after Privacy that draws on the bare route) and it has content.
    assert(found.last === "/performance", `the page opened on ${found.last}`);
    await until("the landing page drawn", async () => { const r = await read(); return r.shown?.id === "performance" && r.shown.rows > 0; }, 8000);
    if (process.env.SNAP_DIR) {
      // The section's rows load when the page is idle; a picture is only worth taking once they're there.
      await until("rows drawn", async () => (await evaluate(sid, `(() => { ${deep} return deep(document, "cr-link-row").length > 0; })()`)) === true, 8000).catch(() => {});
      const shot = await send("Page.captureScreenshot", { format: "png" }, sid);
      writeFileSync(join(process.env.SNAP_DIR, "settings-trimmed.png"), Buffer.from(shot.data, "base64"));
    }
    // Typing in the page's own search field: how many matches it reports, and what is stamped afterwards.
    const searchFor = async (query) => {
      const detail = await evaluate(sid, `(async () => { ${deep}
        const field = deep(document, "cr-toolbar-search-field")[0];
        const done = new Promise((res) => document.addEventListener("search-finished", (e) => res(e.detail.matchCount), { once: true }));
        field.setValue(${JSON.stringify(query)});
        return await Promise.race([done, new Promise((r) => setTimeout(() => r("timeout"), 5000))]);
      })()`);
      return { matches: detail, ...(await read()) };
    };
    // Search can't bring them back, and the removed section has nothing for it to find.
    assert((await searchFor("memory saver")).matches > 0, "settings search finds nothing for a setting that is there");
    for (const query of ["theme", "profile", "bookmarks bar", "search engine", "default search engine", "manage search engines"]) {
      const result = await searchFor(query);
      assert(result.matches !== "timeout", `searching "${query}" never finished`);
      assert(result.removed === 0 && result.searchPage === 0 && !["people", "appearance", "search"].some((id) => result.views.includes(id)), `searching "${query}" brought them back`);
      if (query.includes("search engine")) assert(result.matches === 0, `searching "${query}" found ${result.matches} matches`);
    }
    await searchFor("");
    // A navigation to the Profiles page opens Ray's window and the tab goes back to the settings page it came from.
    const settingsTab = state().active;
    await evaluate(sid, `location.href = "chrome://settings/people"`);
    await until("window opened for the Profiles page", async () => { await command("state"); return state().settingsWindow.open; });
    await until("tab left Profiles", async () => { await command("state"); return !state().tabs.some((t) => t.url.includes("/people")); }, 6000);
    await closeSettingsWindow();
    await until("tab back on the settings page", async () => { await command("state"); return state().tabs.find((t) => t.id === settingsTab)?.url === "chrome://settings/"; }, 6000);
    // Search engine is Ray's Search pane: its addresses open the window there, from a navigation in the page (the tab
    // goes back to the settings page) and typed (ray:// or chrome://, loading nothing).
    const noSearchPage = async (why) => {
      await command("state");
      // Only settings addresses count: earlier checks can leave the fixture's own /search page open.
      assert(state().tabs.length === tabCount + 1 && !state().tabs.some((t) => /^chrome:\/\/settings\/search/i.test(t.url)), `${why}: ${state().tabs.map((t) => t.url)}`);
      assert(state().settingsWindow.open && state().settingsWindow.pane === "search", `${why} didn't open the Search pane`);
      const r = await read();
      assert(r.searchPage === 0 && !r.views.includes("search"), `${why} shows ${r.last} ${r.views}`);
    };
    for (const path of ["/searchEngines", "/search"]) {
      await closeSettingsWindow().catch(() => {});
      await evaluate(sid, `location.href = "chrome://settings${path}"`);
      await until(`window for ${path}`, async () => { await command("state"); return state().settingsWindow.open; });
      await until(`tab left ${path}`, async () => { await command("state"); return state().tabs.find((t) => t.id === settingsTab)?.url === "chrome://settings/"; }, 6000);
      await until(`settings page back after ${path}`, async () => (await read().catch(() => null))?.menu.length > 0, 10000);
      await noSearchPage(`navigating to ${path}`);
    }
    for (const typed of ["ray://settings/search", "chrome://settings/searchEngines"]) {
      await closeSettingsWindow();
      await goTo(typed);
      await until(`window for ${typed}`, async () => { await command("state"); return state().settingsWindow.open; });
      await sleep(300);
      await noSearchPage(`typing ${typed}`);
      assert(state().tabs.find((t) => t.id === settingsTab)?.url === "chrome://settings/", `typing ${typed} loaded a page`);
    }
    await closeSettingsWindow();
    await command(`rowaction close ${entryOfTab(settingsTab).id}`);
    await until("settings tab closed", async () => { await command("state"); return !state().tabs.some((t) => t.id === settingsTab); });
    // Typed, it opens the window and loads nothing.
    await goTo("ray://settings/people");
    await until("window opened for the typed Profiles address", async () => { await command("state"); return state().settingsWindow.open; });
    await sleep(300);
    await command("state");
    assert(state().tabs.length === tabCount && !state().tabs.some((t) => t.url.includes("/people")), "typing the Profiles address loaded a page");
    await closeSettingsWindow();
  },
  async "settings-privacy"() {
    // Settings › Privacy, all the normal profile's: sites with a permission of their own (one granted, one denied from
    // the page's own prompt) with their permissions, Reset and Clear Site Data (asked first, the full origin, no click in
    // its first half second); the sites you zoomed, with Reset; Chrome's Site settings addresses open the pane while
    // its Privacy and security page stays Chrome's; a private window's sites never show.
    await resetSettings();
    await closeSettingsWindow().catch(() => {});
    const win = () => state().settingsWindow;
    const pane = async () => JSON.parse(await commandResult("privacy list"));
    const site = async (o) => (await pane()).sites.find((s) => s.origin === o);
    // A private window's sites are its own: a permission set there never shows in the pane (first, while no sheet
    // has made the normal window key).
    await command("menu newPrivateWindow");
    await until("private window", async () => { await command("state"); return state().private === true && state().commandBar; });
    await command(`type ${raytestOrigin}/b?private-privacy`);
    await command("enter");
    await until("private page", async () => { await command("state"); return state().private === true && activeTabState()?.url.includes("private-privacy"); });
    await command("menu toggleSiteControls");
    await until("private panel", async () => { await command("state"); return state().private === true && state().siteControls !== null; });
    await command("site set camera allow");
    await until("allowed in private", async () => { await command("state"); return state().siteControls?.settings.find((s) => s.title === "Camera")?.value === "Allowed"; });
    await command("menu toggleSiteControls");
    await command("key w cmd");
    await until("private tab closed", async () => { await command("state"); return state().private === true && state().active === null; }, 5000);
    await command("key w cmd keywin");
    await until("back to the normal window", async () => { await command("state"); return state().private === false; }, 5000);
    await command("settings open privacy");
    await until("privacy pane", async () => { await command("state"); return win().open && win().pane === "privacy"; });
    let p = await until("lists loaded", async () => { const p = await pane(); return p.loaded && p; });
    assert(!p.sites.some((s) => s.origin === raytestOrigin), `a private window's permission is in the pane: ${JSON.stringify(p.sites)}`);
    assert(p.empty.apps === "No apps yet Sites appear here after you let them always open an app, such as a meeting link opening its app.", `apps: ${JSON.stringify(p.empty)}`);
    if (p.sites.length === 0) assert(p.empty.sites === "No sites yet Sites appear here after you allow or block something for them.", `empty sites: ${JSON.stringify(p.empty)}`);
    const ask = async (url, answer) => {
      await goTo(url, true);
      await until(`${url} open`, async () => { await command("state"); return activeTabState()?.url === url; });
      const { sessionId } = await session(url);
      await until("loaded", async () => (await evaluate(sessionId, `document.readyState`)) === "complete");
      await evaluate(sessionId, `window.answer = null; Notification.requestPermission().then((r) => window.answer = r); 0`);
      await until("prompt", async () => { await command("state"); return state().permission?.ready; }, 5000);
      await command(`perm ${answer}`);
      await until("answered", async () => (await evaluate(sessionId, `window.answer`)) === (answer === "allow" ? "granted" : "denied"));
      return sessionId;
    };
    // Granted on localhost, denied on ray.test: both show up on their own, the pane open behind.
    const local = await ask(`${localOrigin}/b?privacy`, "allow");
    const secure = await ask(`${secureOrigin}/b?privacy`, "block");
    p = await until("both sites listed", async () => {
      const p = await pane();
      return p.sites.find((s) => s.origin === localOrigin)?.permissions.notifications === "allow"
        && p.sites.find((s) => s.origin === secureOrigin)?.permissions.notifications === "block" && p;
    }, 8000);
    const order = p.sites.map((s) => s.origin);
    assert(order.indexOf(localOrigin) < order.indexOf(secureOrigin), `sites out of order: ${order}`);
    assert(p.sites.find((s) => s.origin === secureOrigin).title === secureOrigin.replace("https://", "") && p.sites.find((s) => s.origin === localOrigin).title === localOrigin, `titles ${JSON.stringify(p.sites)}`);
    // Site controls' Site Settings… opens the pane at its site.
    await command("menu toggleSiteControls");
    await until("panel open", async () => { await command("state"); return state().siteControls !== null; });
    await command("site press siteSettings");
    await until("pane at the site", async () => { await command("state"); return win().pane === "privacy" && (await site(secureOrigin))?.open; });
    await command("state");
    assert(state().siteControls === null, "the panel stayed open");
    if (process.env.SNAP_DIR) { await sleep(300); await command(`settings snap ${join(process.env.SNAP_DIR, "settings-privacy.png")}`); }
    // A permission changed in the pane is what the page sees.
    await command(`privacy open ${localOrigin}`);
    assert(await commandResult(`privacy set ${localOrigin} notifications block`) === "ok", "no notifications pop-up for localhost");
    await until("blocked from the pane", async () => (await site(localOrigin))?.permissions.notifications === "block");
    await until("the page sees it", async () => (await evaluate(local, `Notification.permission`)) === "denied");
    // Reset hands the site back to the defaults and takes it off the list.
    assert(await commandResult(`privacy reset ${localOrigin}`) === "ok", "no Reset for localhost");
    await until("localhost gone", async () => !(await site(localOrigin)), 5000);
    await until("the page sees the default", async () => (await evaluate(local, `Notification.permission`)) === "default");
    // Clear Site Data asks first with the full origin; Cancel keeps everything, Clear deletes cookies and storage.
    await evaluate(secure, `document.cookie = "ray=1; max-age=3600; secure"; localStorage.setItem("ray", "1"); 0`);
    assert((await evaluate(secure, `document.cookie`)).includes("ray=1"), "no cookie to clear");
    await command(`privacy clear ${secureOrigin}`);
    const q = await until("asked", async () => (await pane()).confirm);
    assert(q.message === `Clear cookies and site data for ${secureOrigin}?`, `question ${JSON.stringify(q)}`);
    assert(await commandResult("privacy confirm accept") === "not ready", "Clear took a click in its first half second");
    await command("privacy confirm cancel");
    await until("question gone", async () => (await pane()).confirm === null);
    assert((await evaluate(secure, `document.cookie`)).includes("ray=1"), "Cancel cleared the cookie");
    await command(`privacy clear ${secureOrigin}`);
    await until("asked again", async () => (await pane()).confirm?.ready === true, 3000);
    assert(await commandResult("privacy confirm accept") === "ok", "Clear didn't take the click");
    await until("cleared", async () => (await pane()).cleared[secureOrigin] !== undefined, 8000);
    await until("cookie gone", async () => !(await evaluate(secure, `document.cookie`)).includes("ray=1"), 5000);
    await evaluate(secure, `location.reload(); 0`);
    await sleep(500);
    const again = await session(`${secureOrigin}/b?privacy`);
    await until("reloaded", async () => (await evaluate(again.sessionId, `document.readyState`)) === "complete");
    assert(await evaluate(again.sessionId, `localStorage.getItem("ray")`) === null, "storage survived Clear Site Data");
    assert((await site(secureOrigin))?.permissions.notifications === "block", "Clear Site Data took the permission too");
    await command(`privacy reset ${secureOrigin}`);
    await until("ray.test gone", async () => !(await site(secureOrigin)), 5000);
    // Zoom levels: a site you zoom shows with its level; Reset hands it back to the default, as Site controls' does.
    await goTo(`${raytestOrigin}/h?privacy`);
    await until("ray.test page", async () => { await command("state"); return activeTabState()?.url.startsWith(raytestOrigin); });
    await command("zoom in");
    await until("zoomed", async () => { await command("state"); return state().settings.zoomedHosts.includes("ray.test"); });
    await until("listed at 110%", async () => (await pane()).zoom.some((z) => z.host === "ray.test" && z.percent === 110), 5000);
    assert(await commandResult("privacy zoomreset ray.test") === "ok", "no Reset for ray.test");
    await until("reset", async () => { await command("state"); return !state().settings.zoomedHosts.includes("ray.test") && near(activeZoom(), 1); });
    p = await until("off the list", async () => { const p = await pane(); return !p.zoom.some((z) => z.host === "ray.test") && p; });
    if (p.zoom.length === 0) assert(p.empty.zoom?.startsWith("No zoomed sites"), `empty zoom: ${JSON.stringify(p.empty)}`);
    // Clear browsing data: Chrome's dialog, in the normal window.
    assert(await commandResult("privacy clearbrowsing") === "ok", "no Clear browsing data button");
    await until("clear data page", async () => { await command("state"); return activeTabState()?.url === "chrome://settings/clearBrowserData"; });
    await command("menu closeTab");
    // Chrome's Site settings pages and ray://settings/privacy open the pane and load nothing; its Privacy and security
    // page is still Chrome's.
    for (const address of ["chrome://settings/content", "ray://settings/privacy", "chrome://settings/content/all"]) {
      await closeSettingsWindow();
      await command(`row ${entryOfTab(tabFor("/a").id).id}`);
      await until("/a active", () => state().active === tabFor("/a").id);
      const before = activeTabState().url;
      await goTo(address);
      await until(`${address} opens the pane`, async () => { await command("state"); return win().open && win().pane === "privacy"; });
      await sleep(200);
      await command("state");
      assert(activeTabState().url === before, `${address} changed the tab: ${activeTabState().url}`);
    }
    await closeSettingsWindow();
    const tabs = state().tabs.length;
    await goTo("chrome://settings/privacy", true);
    await until("Chrome's privacy page", async () => { await command("state"); return activeTabState()?.url.startsWith("chrome://settings/privacy"); }, 10000);
    assert(!win().open, "chrome://settings/privacy opened the window");
    await command("menu closeTab");
    await until("privacy tab closed", async () => { await command("state"); return state().tabs.length === tabs; });
    for (const extra of state().tabs.filter((t) => t.url.includes("privacy"))) await command(`rowaction close ${entryOfTab(extra.id).id}`);
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await resetSettings();
  },
  async "settings-extensions"() {
    // Settings › Extensions on a local unpacked fixture (nothing from the Web Store): load it from a folder, its row
    // (icon, name, version, description, switch), site access, private windows, Options, Reload and Remove (asked
    // first, its name and ID, no click in its first half second); ray://settings/extensions opens the pane.
    await resetSettings();
    await closeSettingsWindow().catch(() => {});
    const win = () => state().settingsWindow;
    const dir = join(dataDir, "settings-extension");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({
      manifest_version: 3, name: "Ray Settings Fixture", version: "2.1", description: "Checks the Extensions pane.",
      icons: { 48: "icon.png" }, options_page: "options.html", host_permissions: ["<all_urls>"],
    }));
    writeFileSync(join(dir, "icon.png"), solidPNG(48));
    writeFileSync(join(dir, "options.html"), `<!doctype html><title>Fixture options</title><body>options</body>`);
    const pane = async () => JSON.parse(await commandResult("extpane list"));
    const fixture = async () => (await pane()).extensions.find((e) => e.name === "Ray Settings Fixture");
    await command("settings open extensions");
    await until("extensions pane", async () => { await command("state"); return win().open && win().pane === "extensions"; });
    await until("list loaded", async () => (await pane()).loaded);
    // Load unpacked sits under More; Add from a link isn't built (test builds show it).
    await command("extpane more");
    const more = await pane();
    assert(more.more && more.linkRow, `More: ${JSON.stringify(more)}`);
    await command(`extpane unpacked ${dir}`);
    const item = await until("installed and listed", async () => fixture(), 15000);
    const id = item.id;
    assert(item.enabled && item.switchOn === true && item.version === "2.1" && item.hasIcon && item.unpacked && item.options && item.open,
      `the row: ${JSON.stringify(item)}`);
    assert(item.detail === "Version 2.1 · Checks the Extensions pane.", `the row's line: ${item.detail}`);
    assert(item.siteAccess === "ON_ALL_SITES" && item.access === "allSites", `site access ${item.siteAccess} / ${item.access}`);
    if (process.env.SNAP_DIR) { await sleep(300); await command(`settings snap ${join(process.env.SNAP_DIR, "settings-extensions.png")}`); }
    // Site access, both ways.
    assert(await commandResult(`extpane access ${id} onClick`) === "ok", "no site access pop-up");
    await until("on click", async () => (await fixture()).siteAccess === "ON_CLICK");
    await command(`extpane access ${id} allSites`);
    await until("all sites again", async () => (await fixture()).siteAccess === "ON_ALL_SITES");
    // Private windows, both ways.
    await command(`extpane private ${id}`);
    await until("allowed in private windows", async () => (await fixture()).incognito === true);
    await command(`extpane private ${id}`);
    await until("not in private windows", async () => (await fixture()).incognito === false);
    // Chrome reloads an extension when its private-window access changes: let it come back first.
    await sleep(800);
    await until("back after the reload", async () => (await fixture())?.enabled === true, 5000);
    // Off and on again: the engine's own state, and the row follows.
    await command(`extpane toggle ${id}`);
    await until("off", async () => { const e = await fixture(); return e.enabled === false && e.switchOn === false; }, 5000)
      .catch(async (e) => { throw new Error(`${e.message}: ${JSON.stringify(await fixture())}`); });
    await command(`extpane toggle ${id}`);
    await until("on", async () => { const e = await fixture(); return e.enabled === true && e.switchOn === true; });
    // Options: the extension's own page, in a tab of the normal window.
    assert(await commandResult(`extpane options ${id}`) === "ok", "no Options button");
    await until("options tab", async () => { await command("state"); return activeTabState()?.url.startsWith(`chrome-extension://${id}/options.html`); });
    assert(state().private === false, "Options opened in a private window");
    await command("menu closeTab");
    assert(await commandResult(`extpane reload ${id}`) === "ok", "no Reload for an unpacked extension");
    await until("still there after Reload", async () => (await fixture())?.enabled === true);
    // Remove asks first, naming it and its ID; Cancel keeps it.
    await command(`extpane remove ${id}`);
    const q = await until("asked", async () => (await pane()).confirm);
    assert(q.message === "Remove “Ray Settings Fixture”?" && q.detail.includes(id), `question ${JSON.stringify(q)}`);
    assert(await commandResult("extpane confirm accept") === "not ready", "Remove took a click in its first half second");
    await command("extpane confirm cancel");
    await until("question gone", async () => (await pane()).confirm === null);
    assert(await fixture(), "Cancel removed it");
    await command(`extpane remove ${id}`);
    await until("asked again", async () => (await pane()).confirm?.ready === true, 3000);
    assert(await commandResult("extpane confirm accept") === "ok", "Remove didn't take the click");
    await until("removed", async () => !(await fixture()), 8000);
    // ray://settings/extensions opens the pane and loads nothing.
    await closeSettingsWindow();
    await command(`row ${entryOfTab(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    const before = activeTabState().url;
    await goTo("ray://settings/extensions");
    await until("pane from its address", async () => { await command("state"); return win().open && win().pane === "extensions"; });
    await sleep(200);
    await command("state");
    assert(activeTabState().url === before, `ray://settings/extensions changed the tab: ${activeTabState().url}`);
    await closeSettingsWindow();
  },
  async "sidebar-toggle"() {
    await needsFrames();
    const x = () => Number(state().cardFrame.match(/-?[\d.]+/g)[0]);
    assert(x() > 200, `card starts at ${x()}`);
    await command("menu toggleSidebar");
    await until("sidebar hidden", () => state().sidebar.hidden);
    await until("card slid left", async () => { await command("state"); return x() < 20; }, 3000, 50);
    // The address bar's buttons ride the sidebar's spring in, rather than popping in when it's gone.
    await until("buttons in", async () => { await command("state"); return state().toolbar.navigationProgress === 1; }, 3000, 50);
    assert(state().toolbar.navigationSteps >= 3, `the address bar's buttons came in over ${state().toolbar.navigationSteps} frames`);
    assert(state().toolbar.navigationProgress === 1, `buttons stopped at ${state().toolbar.navigationProgress}`);
    await command("peek on");
    await until("peeking", () => state().sidebar.peeking);
    assert(x() < 20, "peeking moved the page");
    assert(state().sidebarOverToolbar === true, "the peeking sidebar is under the address bar");
    await command("peek off");
    await until("peek ended", () => !state().sidebar.peeking);
    await command("menu toggleSidebar");
    await until("sidebar shown", () => !state().sidebar.hidden);
    await until("card back", async () => { await command("state"); return x() > 200; }, 3000, 50);
  },
  async "peek-zones"() {
    await needsFrames();
    await command("menu toggleSidebar");
    await until("hidden", () => state().sidebar.hidden);
    await sleep(500);
    await command("pointer 30 300");
    await sleep(200);
    await command("state");
    assert(!state().sidebar.peeking, "30 pt in shouldn't reveal");
    await command("pointer 12 300");
    await until("inside strip reveals", () => state().sidebar.peeking);
    await command("pointer 280 300");
    await sleep(250);
    await command("state");
    assert(state().sidebar.peeking, "within the 24 pt slack it should stay");
    await command("pointer 320 300");
    await until("leaving the slack hides", () => !state().sidebar.peeking);
    await sleep(300);
    await command("pointer -20 300");
    await until("outside reach reveals", () => state().sidebar.peeking);
    await command("pointer 400 300");
    await until("hides again", () => !state().sidebar.peeking);
    await sleep(300);
    await command("pointer -30 300");
    await sleep(200);
    await command("state");
    assert(!state().sidebar.peeking, "beyond 24 pt outside shouldn't reveal");
    await command("menu toggleSidebar");
    await until("shown", () => !state().sidebar.hidden);
  },
  async clear() {
    await command("menu clearToday");
    await until("today cleared", () => state().sidebar.today.length === 0);
    await command("menu toggleSidebar");
    await until("hidden", () => state().sidebar.hidden);
    for (const e of [...state().sidebar.favorites, ...state().sidebar.pinned].filter((e) => e.live)) {
      await command("rowaction unload " + e.id);
    }
    await until("nothing open forces the sidebar out", () => state().active === null && state().sidebar.peeking);
    await command("pointer 600 300");
    await sleep(400);
    await command("state");
    assert(state().sidebar.peeking, "the forced sidebar hid when the pointer left");
    const reopen = state().sidebar.favorites[0]?.id ?? state().sidebar.pinned.find((e) => e.kind !== "folder")?.id;
    await command(`row ${reopen}`);
    await until("a tab is open", () => state().active !== null);
    await command("pointer 600 300");
    await until("sidebar hides again", () => !state().sidebar.peeking);
    await command("menu toggleSidebar");
    await until("shown", () => !state().sidebar.hidden);
    assert(state().tabs.length === state().sidebar.pinned.filter((e) => e.live).length + state().sidebar.favorites.filter((e) => e.live).length, "today tabs still loaded");
  },
  async "window-lights"() {
    await needsFrames();
    // The previous check may have just shown the sidebar; hit-test once it has finished sliding in.
    await until("sidebar docked", async () => {
      await command("state");
      return Number(state().cardFrame.match(/-?[\d.]+/g)[0]) >= 267;
    }, 3000, 50);
    assert(state().realLightsHidden === true, "the real traffic lights show in windowed mode");
    for (const [x, kind] of [[22, "close"], [45, "minimize"], [68, "zoom"]]) {
      const from = stderr.length;
      child.stdin.write(`hit ${x} 26\n`);
      const hit = await until(`hit ${kind}`, () => {
        const at = stderr.indexOf(`[ray-test] hit ${x} 26 -> `, from);
        return at >= 0 ? stderr.slice(at).split("\n")[0] : null;
      });
      assert(hit.includes("WindowLightButton"), `${kind}: ${hit}`);
    }
    const from = stderr.length;
    child.stdin.write("hit 104 26\n");
    const toggle = await until("hit toggle", () => {
      const at = stderr.indexOf("[ray-test] hit 104 26 -> ", from);
      return at >= 0 ? stderr.slice(at).split("\n")[0] : null;
    });
    assert(toggle.includes("HoverIconButton"), `toggle: ${toggle}`);
  },
  async "toggle-keeps-page-still"() {
    await send("Target.createTarget", { url: `${origin}/long` });
    await until("long page", () => tabFor("/long") && state().active === tabFor("/long").id);
    const { sessionId } = await session("/long");
    await until("loaded", async () => (await evaluate(sessionId, `document.readyState`)) === "complete");
    const probe = `JSON.stringify({ y: scrollY, h: innerHeight, top: document.getElementById("p0").getBoundingClientRect().top })`;
    const before = JSON.parse(await evaluate(sessionId, probe));
    for (let i = 0; i < 4; i++) {
      const was = state().sidebar.hidden;
      await command("key s cmd");
      await until("toggled", async () => { await command("state"); return state().sidebar.hidden !== was; }, 3000, 50);
      await sleep(700);
      await command("state");
      assert(state().pages.contentLayerMatches === true, `chrome content layer drifted from the page after toggle ${i + 1}`);
    }
    const after = JSON.parse(await evaluate(sessionId, probe));
    assert(JSON.stringify(after) === JSON.stringify(before), `page moved: ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
  },
  async "arc-import"() {
    // A small Arc sidebar in Arc's format (as Ardia's importer fixture builds it); never the user's real one.
    const tab = (id, parent, url, title, rename = null) => ({ id, parentID: parent, childrenIds: [], title: rename, data: { tab: { savedURL: url, savedTitle: title } } });
    const folder = (id, parent, name, children) => ({ id, parentID: parent, childrenIds: children, title: name, data: { list: {} } });
    const box = (id, children) => ({ id, parentID: null, childrenIds: children, title: null, data: { itemContainer: {} } });
    const items = [
      box("P-PIN", ["T-1", "F-1", "SV-1", "T-J"]),
      tab("T-1", "P-PIN", "https://calendar.example/", "Calendar", "Cal"),
      folder("F-1", "P-PIN", "Reading", ["T-2", "F-2"]),
      tab("T-2", "F-1", "https://blog.example/post", "A blog post"),
      folder("F-2", "F-1", "Later", ["T-3"]),
      tab("T-3", "F-2", "https://later.example/", "Later"),
      { id: "SV-1", parentID: "P-PIN", childrenIds: ["T-4", "T-5"], title: null, data: { splitView: {} } },
      tab("T-4", "SV-1", "https://left.example/", "Left"),
      tab("T-5", "SV-1", "https://right.example/", "Right"),
      tab("T-J", "P-PIN", "javascript:alert(1)", "Sneaky"),
      box("W-PIN", ["T-8"]),
      tab("T-8", "W-PIN", "https://jira.example/", "Board"),
      box("FAV", ["T-10", "T-11", "F-3"]),
      tab("T-10", "FAV", "https://mail.example.com/", "Mail"),
      tab("T-11", "FAV", "https://music.example/", "Music", "Tunes"),
      folder("F-3", "FAV", "Fav folder", ["T-12"]),
      tab("T-12", "F-3", "https://maps.example/", "Maps"),
    ];
    const spaces = [
      { id: "S-1", title: "Personal", newContainerIDs: [{ pinned: {} }, "P-PIN"] },
      { id: "S-2", title: "Work", containerIDs: ["pinned", "W-PIN"] },
    ];
    const flat = (list) => list.flatMap((o) => [o.id, o]);
    mkdirSync(join(dataDir, "Arc"), { recursive: true });
    writeFileSync(join(dataDir, "Arc", "StorableSidebar.json"), JSON.stringify({ sidebar: { containers: [
      { global: {} }, { spaces: flat(spaces), items: flat(items), topAppsContainerIDs: [{ default: true }, "FAV"] },
    ] } }));
    await command("menu importFromArc");
    const asked = await until("asked", () => state().arcImport);
    assert(asked.favorites === 3 && asked.tabs === 6 && asked.folders === 4, `counted ${JSON.stringify(asked)}`);
    await command("arcimport accept");
    await until("imported", () => state().arcImport === null && state().sidebar.pinned.some((e) => e.title === "Personal"));
    const { favorites, pinned } = state().sidebar;
    const find = (title) => pinned.find((e) => e.title === title);
    assert(["Mail", "Tunes", "Maps"].every((t) => favorites.some((e) => e.title === t)), "favorites missing");
    const personal = find("Personal"), work = find("Work"), reading = find("Reading"), later = find("Later");
    assert(personal?.kind === "folder" && work?.kind === "folder", "spaces didn't become folders");
    assert(find("Cal")?.parent === personal.id && find("Left")?.parent === personal.id, "tabs not in their space");
    assert(reading?.parent === personal.id && find("A blog post")?.parent === reading.id && later?.parent === reading.id, "nesting lost");
    assert(find("Board")?.parent === work.id, "work tab misplaced");
    assert(find("Cal")?.customTitle === "Cal" && find("Cal").pageTitle === "Calendar", `Arc's name: ${JSON.stringify(find("Cal"))}`);
    const tunes = favorites.find((e) => e.title === "Tunes");
    assert(tunes?.customTitle === "Tunes" && tunes.pageTitle === "Music", `Arc's favorite name: ${JSON.stringify(tunes)}`);
    assert(find("A blog post")?.customTitle === null, "a tab Arc never renamed got a name");
    assert(![...favorites, ...pinned].some((e) => e.url.startsWith("javascript:")), "a javascript: link came in");
    assert([...favorites, ...pinned].filter((e) => e.url.includes(".example")).every((e) => !e.live), "imported tabs loaded");
    const count = pinned.length + favorites.length;
    await command("menu importFromArc");
    await until("asked again", () => state().arcImport);
    await command("arcimport accept");
    await until("second import done", () => state().arcImport === null);
    await settle();
    assert(state().sidebar.pinned.length + state().sidebar.favorites.length === count, "importing twice added duplicates");
  },
  async onboarding() {
    // The first run's welcome and File › Import from Browser…, on the real ImportSession over the importer's fixtures
    // (RAY_IMPORT_SOURCE_DIR; no RAY_IMPORT_SECRET, so the key-locked items fail as a denied Keychain prompt would,
    // and nothing touches the Keychain), in instances of their own on a new data dir (RAY_ONBOARDING: test builds
    // otherwise never show it, so this main instance starts plain). SNAP_DIR=<dir> also saves each step, light and dark.
    await command("state");
    assert(state().onboarding === null, "a test instance showed the onboarding without RAY_ONBOARDING");
    const dir = mkdtempSync(join(tmpdir(), "ray-onboarding-"));
    const support = join(root, "Importer/fixtures/home/Library/Application Support");
    const shots = process.env.SNAP_DIR;
    if (shots) mkdirSync(shots, { recursive: true });
    const running = [];
    const start = (dataDir = dir) => {
      const it = { log: "", states: [] };
      let partial = "";
      it.proc = spawn(join(app, "Contents/MacOS/Ray"), [], {
        env: { ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_LOG_STATE: "1", RAY_ONBOARDING: "1",
          RAY_IMPORT_SOURCE_DIR: support, RAY_DATA_DIR: dataDir, RAY_DOWNLOADS_DIR: join(dataDir, "Downloads"), RAY_START_URL: `${origin}/a`,
          RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}.onboarding` },
        stdio: ["pipe", "ignore", "pipe"],
      });
      it.proc.stdin.on("error", () => {});
      it.proc.stderr.setEncoding("utf8");
      it.proc.stderr.on("data", (chunk) => {
        it.log += chunk;
        const lines = (partial + chunk).split("\n");
        partial = lines.pop();
        for (const line of lines) {
          const at = line.indexOf(stateMarker);
          if (at >= 0) it.states.push(JSON.parse(line.slice(at + stateMarker.length)));
        }
      });
      it.exit = new Promise((r) => it.proc.on("exit", (code, signal) => r(code ?? signal)));
      running.push(it);
      return it;
    };
    const run = async (it, line, expect = "ok") => {
      const marker = `[ray-test] ${line} -> `;
      const from = it.log.length;
      it.proc.stdin.write(line + "\n");
      const result = await until(`command ${line}`, () => {
        const at = it.log.indexOf(marker, from);
        return at >= 0 ? it.log.slice(at + marker.length).split("\n")[0] : null;
      }, 20000);
      assert(result === expect, `${line}: ${result}`);
    };
    const probe = async (it) => { await run(it, "state"); return it.states.at(-1); };
    const flow = async (it) => (await probe(it))?.onboarding;
    const reach = (it, what, fn, ms = 8000) => until(what, async () => { const o = await flow(it); return o && fn(o) ? o : null; }, ms, 150);
    const gone = (it) => until("onboarding gone", async () => (await probe(it))?.onboarding === null, 5000, 150);
    // Snapshots wait for the step's slide and the card's spring to settle.
    const snap = async (it, name) => { if (shots) { await sleep(700); await run(it, `onboarding snap ${join(shots, `${name}.png`)}`); } };
    const stop = async (it) => {
      it.proc.stdin.write("menu quit\n");
      const code = await Promise.race([it.exit, sleep(15000).then(() => "timeout")]);
      assert(code !== "timeout", "an onboarding instance didn't quit within 15 s");
    };
    try {
      // 1. A new data dir: the welcome, over the window, with the keyboard.
      const first = start();
      let o = await reach(first, "welcome", (o) => o.step === "welcome", 25000);
      assert(o.mode === "firstRun" && o.dots === 6 && o.dot === 0 && o.primary === "Get started" && o.back === null, `welcome ${JSON.stringify(o)}`);
      const [, , cardW, cardH] = o.cardFrame.split(",").map(Number);
      assert(cardW === 460 && cardH >= 400 && o.cardInWindow, `card frame ${o.cardFrame}`);
      assert(o.focused, "the overlay doesn't have the keyboard");
      await snap(first, "1-welcome");
      // Escape never ends the first run; ⌘T opens nothing under the veil.
      await run(first, "onboarding escape");
      await run(first, "menu newTab");
      await sleep(500);
      const afterKeys = await probe(first);
      assert(afterKeys.onboarding?.step === "welcome" && !afterKeys.onboarding.closing, "Escape dismissed the first run");
      assert(afterKeys.commandBar === null, "the command bar opened under the onboarding");
      // 2. Where from: the browsers found (off the main thread), Arc first, recommended and chosen, its profiles in a picker.
      await run(first, "onboarding next");
      o = await reach(first, "source step", (o) => o.step === "source" && o.sourcesLoaded && o.sources[0]?.summary, 15000);
      assert(o.sources[0].id === "arc" && o.sources[0].recommended && o.source === "arc" && o.sources.filter((s) => s.recommended).length === 1,
        `sources ${JSON.stringify(o.sources)}`);
      assert(o.sources[0].summary === "2 spaces, 6 pinned tabs · 2 profiles", `Arc's summary ${o.sources[0].summary}`);
      const arcProfiles = o.sources[0].profiles;
      assert(arcProfiles.length === 2 && o.profilePicker && o.profile === arcProfiles[0] && o.freshLink && o.back === "Back" && o.dot === 1,
        `source step ${JSON.stringify(o)}`);
      // However many browsers, the card fits the window with room around it (the list scrolls if it must).
      o = await reach(first, "source card settled", (o) => o.cardMargin >= 40 && o.sourceList?.selectedVisible, 3000);
      assert(o.cardInWindow && o.sourceList.offset === 0, `source card ${o.cardFrame} margin ${o.cardMargin} list ${JSON.stringify(o.sourceList)}`);
      await snap(first, "2-source");
      const single = o.sources.find((s) => s.profiles.length === 1);
      if (single) {
        await run(first, `onboarding choose ${single.id}`);
        o = await reach(first, `${single.id} chosen`, (o) => o.source === single.id);
        assert(!o.profilePicker, "a one-profile browser shows a profile picker");
        await run(first, "onboarding choose arc");
      }
      await run(first, `onboarding profile ${arcProfiles[1]}`);
      await reach(first, "Arc's other profile", (o) => o.source === "arc" && o.profile === arcProfiles[1]);
      await run(first, `onboarding profile ${arcProfiles[0]}`);
      // 3. What to bring: all Arc gives, ticked but extensions (nothing installs them yet: "coming later", and it can't
      // be ticked), counts where the preview has them; the unlock note follows the key-locked ticks.
      await run(first, "onboarding next");
      o = await reach(first, "items step", (o) => o.step === "items" && o.profile === arcProfiles[0]);
      assert(o.title === "Bring from Arc" && o.items.length === 9 && o.checked.join() === o.items.filter((i) => i !== "extensions").join()
        && o.unlockNote && o.primary === "Import", `items step ${JSON.stringify(o)}`);
      assert(o.counts.pinnedTabs === 6 && o.counts.favorites === 3 && o.counts.autofill === undefined, `counts ${JSON.stringify(o.counts)}`);
      assert(o.itemDetails.extensions === "coming later" && o.itemDetails.pinnedTabs === "6", `item details ${JSON.stringify(o.itemDetails)}`);
      await snap(first, "3-items");
      await run(first, "onboarding toggle extensions", "coming later");
      for (const item of ["passwords", "cookies", "autofill"]) await run(first, `onboarding toggle ${item}`);
      o = await flow(first);
      assert(!o.unlockNote && !o.checked.includes("passwords"), `unlock note without locked items ${JSON.stringify(o)}`);
      for (const item of ["passwords", "cookies", "autofill", "history"]) await run(first, `onboarding toggle ${item}`);
      o = await flow(first);
      assert(o.unlockNote && o.checked.length === 7 && !o.checked.includes("extensions") && !o.checked.includes("history"), `ticks ${JSON.stringify(o.checked)}`);
      // Back and forth keeps the choice.
      await run(first, "onboarding back");
      await reach(first, "back to source", (o) => o.step === "source");
      await run(first, "onboarding next");
      o = await reach(first, "items again", (o) => o.step === "items");
      const chosen = o.checked;
      assert(chosen.length === 7 && !chosen.includes("history") && !chosen.includes("extensions"), `ticks after going back ${JSON.stringify(chosen)}`);
      // 4. Moving in: Arc's sidebar lands in the window's sidebar; the key-locked items fail quietly (no key); then Continue.
      const favoritesBefore = (await probe(first)).sidebar.favorites.length;
      await run(first, "onboarding import");
      o = await reach(first, "importing", (o) => o.step === "importing");
      assert(o.back === null && o.rows.map((r) => r.item).join() === chosen.join(), `while importing ${JSON.stringify(o)}`);
      await snap(first, "4-moving-in");
      o = await reach(first, "import done", (o) => o.imported, 60000);
      assert(o.rows.length === 7 && o.progress === 1 && o.primaryEnabled && o.primary === "Continue", `after import ${JSON.stringify(o)}`);
      const row = (item) => o.rows.find((r) => r.item === item);
      assert(row("pinnedTabs").state === "done" && row("pinnedTabs").count === 6 && row("favorites").state === "done" && row("favorites").count === 3,
        `rows ${JSON.stringify(o.rows)}`);
      assert(o.rows.every((r) => r.state === "done" || (r.state === "failed" && r.reason)), `rows ${JSON.stringify(o.rows)}`);
      assert(["passwords", "cookies"].every((item) => row(item).state === "failed"), `key-locked rows without the key ${JSON.stringify(o.rows)}`);
      assert(row("pinnedTabs").text === "6" && row("favorites").text === "3", `row texts ${JSON.stringify(o.rows)}`);
      // A reason shows on one line, cut if long; the whole of it is the row's tooltip.
      assert(o.rowTips.length === o.rows.length && o.rows.every((r, i) => r.state === "failed" ? o.rowTips[i].tip === r.reason : o.rowTips[i].tip === null),
        `row tooltips ${JSON.stringify(o.rowTips)} rows ${JSON.stringify(o.rows)}`);
      const imported = await probe(first);
      assert(imported.sidebar.favorites.length === favoritesBefore + 3 && imported.sidebar.pinned.some((e) => e.kind === "folder" && e.title === "Personal"),
        `the sidebar after the import ${JSON.stringify(imported.sidebar)}`);
      await snap(first, "5-moved-in");
      // 5. Colour: a swatch goes through Settings › Theme's own call, so the profile's colour follows.
      await run(first, "onboarding next");
      await reach(first, "theme step", (o) => o.step === "theme");
      // A black profile colour: the card's marks (dots, ticks, the progress line, links) stay visible on the dark card.
      await run(first, "setting theme #000000");
      o = await reach(first, "black theme", (o) => o.markContrast.dark >= 3);
      assert(o.markContrast.light >= 3 && o.markContrast.dark >= 3, `mark contrast with black ${JSON.stringify(o.markContrast)}`);
      await snap(first, "6-theme-black");
      await run(first, "onboarding swatch 1");
      const themed = await probe(first);
      assert(themed.settings.theme.setting === "#2F6BEA" && themed.settings.theme.accent === "#2F6BEA" && themed.onboarding.swatch === "#2F6BEA",
        `theme ${JSON.stringify(themed.settings.theme)}`);
      await snap(first, "6-theme");
      // 6. Three keys; Start browsing ends it, for good.
      await run(first, "onboarding next");
      o = await reach(first, "keys step", (o) => o.step === "keys");
      assert(o.keys.join(" ") === "⌘T ⌘S ⇧⌘C" && o.primary === "Start browsing" && o.dot === 5, `keys ${JSON.stringify(o)}`);
      await snap(first, "7-keys");
      await run(first, "onboarding finish");
      await gone(first);
      const saved = JSON.parse(readFileSync(join(dir, "Settings.json"), "utf8"));
      assert(saved.onboarded === true && saved.theme === "#2F6BEA", `Settings.json ${JSON.stringify(saved)}`);
      await stop(first);
      // The same data dir again: no welcome. File › Import from Browser… is the import steps alone, and Escape leaves it.
      const second = start();
      await until("second instance", async () => (await probe(second))?.sidebar, 25000, 200);
      await sleep(1000);
      assert((await probe(second)).onboarding === null, "the welcome showed again on the same data dir");
      await run(second, "menu importFromBrowser");
      o = await reach(second, "import from browser", (o) => o.step === "source" && o.sourcesLoaded, 15000);
      assert(o.mode === "importOnly" && o.dots === 3 && o.dot === 0 && !o.freshLink && o.back === "Cancel" && o.source === "arc",
        `import from browser ${JSON.stringify(o)}`);
      await snap(second, "8-import-from-browser");
      // The smallest window: the card shrinks to fit with 40 pt to spare and the browsers scroll, Arc on top and chosen;
      // choosing the last one scrolls it into view.
      await run(second, "winsize 720 460");
      o = await reach(second, "small window", (o) => o.sourceList?.scrollable && Number(o.cardFrame.split(",")[3]) <= 380);
      assert(o.cardMargin >= 40 && o.cardInWindow && o.source === "arc" && o.sourceList.selectedVisible && o.sourceList.offset === 0,
        `small window card ${o.cardFrame} margin ${o.cardMargin} list ${JSON.stringify(o.sourceList)}`);
      await snap(second, "8b-source-small-window");
      await run(second, `onboarding choose ${o.sources.at(-1).id}`);
      o = await reach(second, "last source in view", (o) => o.source === o.sources.at(-1).id && o.sourceList.selectedVisible && o.sourceList.offset > 0);
      await run(second, "onboarding choose arc");
      await run(second, "onboarding escape");
      await gone(second);
      // Ray › Show Welcome Again (⌥ over Settings…) replays the first run on an onboarded profile.
      const replay = await probe(second);
      assert(replay.welcomeAgainItem?.alternate && replay.welcomeAgainItem.option && replay.welcomeAgainItem.key === ","
        && replay.welcomeAgainItem.after === "Settings…", `Show Welcome Again item ${JSON.stringify(replay.welcomeAgainItem)}`);
      await run(second, "menu showWelcomeAgain");
      o = await reach(second, "welcome again", (o) => o.step === "welcome");
      assert(o.mode === "firstRun" && o.dots === 6 && o.cardMargin >= 40, `welcome again ${JSON.stringify(o)}`);
      // Importing what's already in the sidebar says so, rather than 0.
      await run(second, "onboarding next");
      await reach(second, "source again", (o) => o.step === "source" && o.sourcesLoaded && o.source === "arc");
      await run(second, "onboarding next");
      await reach(second, "items again", (o) => o.step === "items");
      for (const item of ["history", "bookmarks", "passwords", "cookies", "autofill"]) await run(second, `onboarding toggle ${item}`);
      await run(second, "onboarding import");
      o = await reach(second, "import again done", (o) => o.step === "importing" && o.imported, 60000);
      const againRow = (item) => o.rows.find((r) => r.item === item);
      assert(againRow("pinnedTabs").count === 0 && againRow("pinnedTabs").existing === 6 && againRow("pinnedTabs").text === "6 already here"
        && againRow("favorites").text === "3 already here", `already here rows ${JSON.stringify(o.rows)}`);
      await snap(second, "8c-already-here");
      await run(second, "onboarding next");
      await reach(second, "theme again", (o) => o.step === "theme");
      await run(second, "onboarding next");
      await reach(second, "keys again", (o) => o.step === "keys");
      await run(second, "onboarding finish");
      await gone(second);
      // Start fresh goes straight to the colour; a key Settings turned off isn't offered.
      await run(second, "setting copyLinkShortcut off");
      await run(second, "onboarding show");
      await reach(second, "welcome on demand", (o) => o.step === "welcome");
      await run(second, "onboarding next");
      await reach(second, "source", (o) => o.step === "source");
      await run(second, "onboarding fresh");
      await reach(second, "fresh to the colour", (o) => o.step === "theme" && o.dot === 4);
      await run(second, "onboarding back");
      await reach(second, "back to source", (o) => o.step === "source");
      await run(second, "onboarding fresh");
      await reach(second, "the colour again", (o) => o.step === "theme");
      await run(second, "onboarding next");
      o = await reach(second, "keys without ⇧⌘C", (o) => o.step === "keys");
      assert(o.keys.join(" ") === "⌘T ⌘S", `keys with copy link off ${JSON.stringify(o.keys)}`);
      await run(second, "onboarding finish");
      await gone(second);
      await stop(second);
      rmSync(dir, { recursive: true, force: true });
      // A profile from before the welcome existed (Ray 0.2.0 and earlier: Settings.json without `onboarded`) gets it
      // once; one that finished it doesn't.
      for (const [settings, shows] of [[{ theme: "#A486F0" }, true], [{ theme: "#A486F0", onboarded: true }, false]]) {
        const old = mkdtempSync(join(tmpdir(), "ray-onboarding-old-"));
        writeFileSync(join(old, "Settings.json"), JSON.stringify(settings));
        const it = start(old);
        if (shows) {
          await reach(it, "welcome for an older profile", (o) => o.step === "welcome" && o.mode === "firstRun", 25000);
        } else {
          await until("window up", async () => (await probe(it))?.sidebar, 25000, 150);
          await sleep(800);
          assert((await probe(it))?.onboarding === null, "a profile that finished the welcome saw it again");
        }
        await stop(it);
        rmSync(old, { recursive: true, force: true });
      }
    } finally {
      for (const it of running) if (it.proc.exitCode === null && it.proc.signalCode === null) it.proc.kill("SIGKILL");
    }
  },
  async "close-last-window"() {
    // Closing the only window leaves Ray running; the Dock icon brings it back with its tabs.
    const ids = (sidebar) => JSON.stringify(["favorites", "pinned", "today"].map((k) => sidebar[k].map((e) => e.id)));
    await command("state");
    const before = ids(state().sidebar);
    const count = states.length;
    await command("closewindow");
    await sleep(2000);
    assert(exitCode === null, "Ray quit when its last window closed");
    await command("reopen");
    await until("window back", async () => { await command("state"); return states.length > count + 1 && state().sidebar; }, 8000);
    assert(ids(state().sidebar) === before, "the reopened window lost tabs");
  },
  async "tab-rename"() {
    // Any tab gets a name of its own (Arc's Rename…): from its row's menu or a double click on its title, kept over
    // navigations, page title changes and relaunches; an empty name goes back to the page's title.
    const entry = (id) => allEntries().find((e) => e.id === id);
    const fresh = async (path) => {
      const before = new Set(allEntries().map((e) => e.id));
      await send("Target.createTarget", { url: `${origin}${path}` });
      return until(`tab ${path}`, async () => {
        await command("state");
        return allEntries().find((e) => !before.has(e.id) && e.url.includes(path) && e.live && e.pageTitle?.startsWith("Page"));
      });
    };
    const renaming = (id) => until(`renaming ${id}`, async () => { await command("state"); return state().sidebarFrames.renaming === id; }, 3000);
    const named = (id, name, what) => until(what, async () => { await command("state"); return entry(id)?.customTitle === name && state().sidebarFrames.renaming === ""; });
    const t = (await fresh("/a?rename-today")).id;
    let p = (await fresh("/b?rename-pinned")).id;
    let f = (await fresh("/c?rename-favorite")).id;
    await command(`rowaction pin ${p}`);
    await until("pinned", () => entry(p)?.kind === "pinned");
    await command(`rowaction favorite ${f}`);
    await until("favorite", () => entry(f)?.kind === "favorite");
    for (const id of [t, p, f]) {
      const items = JSON.parse(await commandResult(`rowmenu ${id}`));
      assert(items[0] === "Rename…" && !items.includes("Use Page Title"), `${entry(id).kind} menu: ${items}`);
    }
    assert(entry(t).customTitle === null && entry(t).title === "Page A", `before renaming: ${JSON.stringify(entry(t))}`);

    // A Today tab, from its menu: the field starts on the page's title, all selected; Enter keeps what was typed.
    await command(`row ${t}`);
    await until("today tab active", () => state().activeEntry === t);
    await command(`rowaction rename ${t}`);
    await renaming(t);
    // The active row's close button hides under the field (it showed through Done), and the text doesn't move.
    assert(state().sidebarFrames.renameLook === "0,0.0,0.0", `rename field look ${state().sidebarFrames.renameLook}`);
    await command("type Reading");
    await command("enter");
    await named(t, "Reading", "today tab named");
    assert(entry(t).title === "Reading" && entry(t).pageTitle === "Page A", `named today tab: ${JSON.stringify(entry(t))}`);
    assert(JSON.parse(await commandResult(`rowmenu ${t}`)).includes("Use Page Title"), "a named tab's menu has no Use Page Title");

    // A pinned tab, by a double click on its title; Escape keeps the old name, Done the new one.
    await settle();
    const row = frameOf(p);
    await command(`press ${row.cx} ${row.cy} 1`);
    await command(`release ${row.cx} ${row.cy} 1`);
    await command(`press ${row.cx} ${row.cy} 2`);
    await command(`release ${row.cx} ${row.cy} 2`);
    await renaming(p);
    await command("type Work stuff");
    await command("renamedone");
    await named(p, "Work stuff", "pinned tab named by Done");
    await command(`rowaction rename ${p}`);
    await renaming(p);
    await command("type Nope");
    await command("escape");
    await until("escape cancelled", async () => { await command("state"); return state().sidebarFrames.renaming === ""; });
    assert(entry(p).customTitle === "Work stuff", `escape changed the name to ${entry(p).customTitle}`);

    // A favorite: its tile has no title, so a lifted row under it holds the field; its tip is the name.
    await command(`rowaction rename ${f}`);
    await renaming(f);
    await command("type Fav");
    await command("enter");
    await named(f, "Fav", "favorite named");

    // The page moves on and retitles itself: the name stays, only the page's title follows.
    await command(`row ${t}`);
    await until("today tab active again", () => state().activeEntry === t);
    const page = await session("?rename-today");
    await evaluate(page.sessionId, `location.href = ${JSON.stringify(`${origin}/b?rename-today-2`)}`);
    await until("navigated", async () => { await command("state"); return entry(t)?.url.includes("rename-today-2") && entry(t).pageTitle === "Page B"; });
    const moved = await session("?rename-today-2");
    await evaluate(moved.sessionId, `document.title = "Retitled by the page"`);
    await until("page retitled", async () => { await command("state"); return entry(t)?.pageTitle === "Retitled by the page"; });
    assert(entry(t).customTitle === "Reading" && entry(t).title === "Reading", `the page renamed the tab: ${JSON.stringify(entry(t))}`);

    // The command bar shows the name, and finds the tab by it or by its page's title.
    await command(`row ${p}`);
    await until("pinned tab active", () => state().activeEntry === p);
    for (const query of ["Readi", "Retitled"]) {
      await command("menu newTab");
      await command(`type ${query}`);
      await until(`bar row for ${query}`, async () => {
        await command("state");
        return state().commandBar?.rows?.some((r) => r.kind === "tab" && r.tab === entry(t).tab && r.title === "Reading");
      });
      await command("escape");
      await until("bar closed", async () => { await command("state"); return state().commandBar === null; });
    }

    // Very long names are cut; an empty one (or the page's own title) goes back to the page's title.
    await command(`rename ${t} ${"x".repeat(250)}`);
    await until("long name", async () => { await command("state"); return entry(t)?.customTitle?.length === 200; });
    await command(`rename ${t} Reading`);
    await named(t, "Reading", "named again");
    await command(`rowaction rename ${f}`);
    await renaming(f);
    await command("type ");
    await command("enter");
    await named(f, null, "favorite's name cleared");
    assert(entry(f).title === entry(f).pageTitle && entry(f).title === "Page C", `cleared favorite: ${JSON.stringify(entry(f))}`);

    // Recently Closed and ⇧⌘T: a closed Today tab keeps its name, and comes back with it.
    const gone = (await fresh("/c?rename-closed")).id;
    await command(`rename ${gone} Gone soon`);
    await named(gone, "Gone soon", "closing tab named");
    await command(`rowaction close ${gone}`);
    await until("closed", async () => { await command("state"); return !entry(gone) && state().recentlyClosed?.items?.[0]?.title === "Gone soon"; });
    await command("closed 0");
    await until("back with its name", async () => {
      await command("state");
      return allEntries().some((e) => e.url.includes("rename-closed") && e.customTitle === "Gone soon" && e.live);
    });

    // Unloading keeps it; Sidebar.json has it (the restore check finds every name again after the relaunch).
    await command(`rowaction unload ${p}`);
    await until("pinned tab unloaded", async () => { await command("state"); return entry(p)?.live === false; });
    assert(entry(p).title === "Work stuff", `unloaded pinned tab: ${JSON.stringify(entry(p))}`);
    // A double click on an unloaded tab: the first click loads it, and its page doesn't take the field's keys.
    await settle();
    const unloaded = frameOf(p);
    await command(`press ${unloaded.cx} ${unloaded.cy} 1`);
    await command(`release ${unloaded.cx} ${unloaded.cy} 1`);
    await command(`press ${unloaded.cx} ${unloaded.cy} 2`);
    await command(`release ${unloaded.cx} ${unloaded.cy} 2`);
    await renaming(p);
    await until("loaded", async () => { await command("state"); return entry(p)?.live && entry(p).pageTitle === "Page B"; });
    await sleep(500);
    await command("state");
    assert(state().sidebarFrames.renaming === p, "the page took the rename field's focus as it loaded");
    await command("escape");
    await until("escaped", async () => { await command("state"); return state().sidebarFrames.renaming === ""; });
    assert(entry(p).customTitle === "Work stuff", `escape changed the name to ${entry(p).customTitle}`);
    const file = join(dataDir, "Sidebar.json");
    await until("saved", () => {
      const saved = JSON.parse(readFileSync(file, "utf8"));
      return saved.pinned.some((e) => e.id === p && e.customTitle === "Work stuff") && saved.today.some((e) => e.id === t && e.customTitle === "Reading")
        && saved.favorites.some((e) => e.id === f && e.customTitle === undefined);
    }, 4000);
  },
  async "settings-general"() {
    // Settings › General: the default-browser strip, open at login, quitting and closing, downloads, updates, import.
    // Test builds answer from fakes (GeneralSystem): nothing here changes the Mac's default browser or login items.
    const win = () => state().settingsWindow;
    const gen = () => state().general;
    const pane = () => gen().pane;
    const seen = (what, fn, ms) => until(what, async () => { await command("state"); return fn(); }, ms);
    for (const [name, value] of [["warnBeforeQuitting", "default"], ["warnBeforeClosingWindow", "default"], ["onQuit", "default"]])
      await setSetting(name, value);
    await command("general default no");
    await command("general accept yes");
    await command("settings open general");
    await seen("general pane", () => win().open && win().pane === "general" && pane());
    assert(win().rows.general.join() === "general.openAtLogin,warnBeforeQuitting,warnBeforeClosingWindow,onQuit,general.downloads,general.updates,general.import",
      `general rows ${win().rows.general}`);
    assert(state().settings.warnBeforeQuitting === false && state().settings.warnBeforeClosingWindow === true && state().settings.onQuit === "keep",
      `defaults ${JSON.stringify(state().settings)}`);
    assert(win().controls.onQuitOptions.join() === "Keep tabs and windows,Start fresh" && win().controls.onQuit === "Keep tabs and windows",
      `when Ray quits ${JSON.stringify(win().controls)}`);

    // Make Default asks macOS for http and https (a fake here); declined, the strip stays; accepted, it goes, and
    // comes back when the default changes elsewhere (System Settings), seen as Ray comes forward.
    assert(pane().stripShown === true && gen().isDefault === false, `strip ${JSON.stringify(gen())}`);
    await command("general accept no");
    await command("general cta");
    await seen("asked macOS", () => gen().defaultRequests.length === 2 && !gen().asking);
    assert(gen().defaultRequests.join() === "http,https" && gen().isDefault === false && pane().stripShown === true, `declined ${JSON.stringify(gen())}`);
    await command("general accept yes");
    await command("general cta");
    await seen("strip gone", () => gen().isDefault && pane().stripShown === false);
    assert((await commandResult("general cta")) === "no strip", "the strip's button still answers while it's hidden");
    await command("general default no");
    await seen("strip back", () => pane().stripShown === true);

    // Open at login: the switch shows SMAppService's status (a fake here), including "waiting for approval".
    assert(gen().loginStatus === "off" && pane().login === false, `login ${JSON.stringify(gen())}`);
    await command("general login");
    await seen("login on", () => gen().loginStatus === "enabled" && pane().login === true);
    await command("general login");
    await seen("login off", () => gen().loginStatus === "off" && pane().login === false);
    await command("general approval yes");
    await command("general login");
    await seen("login waits for approval", () => gen().loginStatus === "approval" && pane().login === true && pane().loginDetail.includes("Login Items"));
    await command("general approval no");
    await command("general login");
    await seen("login off again", () => gen().loginStatus === "off");
    assert(gen().loginCalls.join() === "register,unregister,register,unregister", `login calls ${gen().loginCalls}`);
    await command("general loginstatus enabled");
    await seen("turned on in System Settings", () => pane().login === true);
    await command("general loginstatus off");
    await seen("turned off in System Settings", () => pane().login === false);

    // Downloads: the engine's folder and "ask where to save", as Chrome's page has them.
    await seen("downloads loaded", () => gen().downloads.loaded && pane().folderEnabled);
    const original = gen().downloads.folder;
    const folder = mkdtempSync(join(tmpdir(), "ray-general-downloads-"));
    try {
      await command(`general folder ${folder}`);
      await seen("folder changed", () => gen().downloads.folder === folder && pane().folder === folder);
      assert((await commandResult("general folder relative/path")).startsWith("usage"), "a relative folder was taken");
      await command("general ask");
      await seen("ask on", () => gen().downloads.ask === true && pane().ask === true);
      await command("general ask");
      await seen("ask off", () => gen().downloads.ask === false && pane().ask === false);
    } finally {
      await command(`general folder ${original}`);
      await seen("folder back", () => gen().downloads.folder === original);
      rmSync(folder, { recursive: true, force: true });
    }
    if (original.startsWith(homedir() + "/")) assert(pane().folder.startsWith("~/"), `home folder shown as ${pane().folder}`);

    // Updates: both switches on (Info.plist's defaults); installing needs checking; Check Now asks Sparkle (a fake
    // here: test builds never run the updater). A build without an updater shows the version alone.
    const version = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", join(app, "Contents/Info.plist")], { encoding: "utf8" })).CFBundleShortVersionString;
    assert(gen().updates?.kind === "fake" && pane().updateRows.length === 3 && pane().updateRows[2].startsWith(`Ray ${version}`), `update rows ${JSON.stringify(pane().updateRows)}`);
    assert(pane().autoCheck && pane().autoInstall && pane().autoInstallEnabled && pane().checkNowShown, `updates ${JSON.stringify(pane())}`);
    await command("general autoinstall");
    await seen("install off", () => gen().updates.autoInstall === false && pane().autoInstall === false);
    await command("general autoinstall");
    await command("general autocheck");
    await seen("checks off", () => gen().updates.autoCheck === false && pane().autoInstall === false && !pane().autoInstallEnabled);
    assert((await commandResult("general autoinstall")) === "disabled", "install switched while checks are off");
    await command("general autocheck");
    await seen("checks on", () => pane().autoCheck && pane().autoInstall && pane().autoInstallEnabled);
    assert(pane().versionDetail === "Not checked yet.", `version detail ${pane().versionDetail}`);
    await command("general checknow");
    await seen("checked", () => gen().updates.checks === 1 && pane().versionDetail.startsWith("Last checked"));
    await command("general updater none");
    await seen("no updater", () => pane().updateRows.length === 1 && !pane().checkNowShown && pane().versionDetail === "Updates aren't set up for this build.");
    if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "settings-general-no-updater.png")}`);
    await command("general updater fake");
    await seen("updater back", () => pane().updateRows.length === 3);

    // Search finds the pane's own rows; Ray.app lists General with all of them (every row here is built).
    await command("settings search login");
    await seen("login found", () => win().search.results[0]?.id === "general.openAtLogin");
    await command("settings search download folder");
    await seen("downloads found", () => win().search.results[0]?.id === "general.downloads");
    await command("settings search");
    await command("settings asapp on");
    await command("settings open general");
    await seen("Ray.app's general", () => win().looksLikeRayApp && win().pane === "general");
    assert(win().panes.includes("general") && win().rows.general.length === 7, `Ray.app general ${JSON.stringify(win().rows.general)}`);
    await command("settings asapp off");
    await command("settings open general");
    await seen("general again", () => !win().looksLikeRayApp && win().pane === "general");
    if (process.env.SNAP_DIR) {
      await command(`settings snap ${join(process.env.SNAP_DIR, "settings-general.png")}`);
      // The rest of the pane: scrolled to Updates by a search, once its flash is over.
      await command("settings search check for updates now");
      await seen("updates found", () => win().search.results[0]?.id === "general.updates");
      await command("settings choose 0");
      await seen("flash over", () => win().lastFlash === "general.updates" && win().flashing === null, 5000);
      await command("settings search");
      await command(`settings snap ${join(process.env.SNAP_DIR, "settings-general-lower.png")}`);
    }

    // Import from another browser… is File › Import from Browser…: the welcome's import steps over the window.
    await command("general import");
    await seen("import steps", () => state().onboarding?.mode === "importOnly");
    await command("onboarding escape");
    await seen("import closed", () => state().onboarding === null, 5000);
    await command("general default no");
    await closeSettingsWindow();
  },
  async "warn-before-closing-window"() {
    // On by default: a private window with two or more tabs asks before closing (its tabs go with it); Cancel keeps
    // it, "Don't ask again" closes it and turns the setting off. The normal window keeps its tabs, so it never asks
    // (close-last-window).
    const gen = () => state().general;
    const windows = async () => Number(await commandResult("windows"));
    await setSetting("warnBeforeClosingWindow", "default");
    const before = await windows();
    await command("menu newPrivateWindow");
    await until("private window", async () => { await command("state"); return state().private === true && state().commandBar; });
    await command(`type ${origin}/b?warn1`);
    await command("enter");
    await until("first private tab", async () => { await command("state"); return state().private && state().tabs.some((t) => t.url.includes("warn1")); });
    await command("menu newTab");
    await until("command bar", async () => { await command("state"); return state().private && state().commandBar; });
    await command(`type ${origin}/c?warn2`);
    await command("enter");
    await until("second private tab", async () => { await command("state"); return state().private && state().tabs.some((t) => t.url.includes("warn2")); });
    await command("closewindow private");
    await until("warning", async () => { await command("state"); return gen().warning.showing === "close"; });
    assert(gen().warning.last.title === "Close 2 tabs?", `warning ${JSON.stringify(gen().warning)}`);
    await sleep(400);
    assert((await windows()) === before + 1, "the window closed before the warning was answered");
    await command("warning cancel");
    await until("cancelled", async () => { await command("state"); return gen().warning.showing === null && gen().warning.last.answer === "cancelled"; });
    await sleep(400);
    assert((await windows()) === before + 1, "Cancel closed the window");
    await command("closewindow private");
    await until("warning again", async () => { await command("state"); return gen().warning.showing === "close"; });
    await command("warning suppress");
    await until("private window closed", async () => (await windows()) === before, 8000);
    await command("state");
    assert(state().settings.warnBeforeClosingWindow === false && gen().warning.last.answer === "suppressed", `after Don't ask again ${JSON.stringify(gen().warning)}`);
    await setSetting("warnBeforeClosingWindow", "default");
  },
  async "warn-before-quitting"() {
    // In instances of their own (they quit). Off by default. On: ⌘Q shows "Quit Ray?" over the window and Ray keeps
    // running until it's answered; Cancel keeps it; ⌘Q again quits; "Don't ask again" quits and turns it off. Also
    // When Ray quits › Start fresh: the next launch has no Today tabs (⇧⌘T brings them back), pinned tabs stay.
    const dir = mkdtempSync(join(tmpdir(), "ray-quit-"));
    writeFileSync(join(dir, "Settings.json"), JSON.stringify({ warnBeforeQuitting: true }));
    const running = [];
    const start = () => {
      const it = { log: "", states: [] };
      let partial = "";
      it.proc = spawn(join(app, "Contents/MacOS/Ray"), [], {
        env: { ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_LOG_STATE: "1", RAY_DATA_DIR: dir,
          RAY_DOWNLOADS_DIR: join(dir, "Downloads"), RAY_START_URL: `${origin}/a?start`,
          RAY_PASTEBOARD: `dev.shanus.ray.checks.${process.pid}.quit` },
        stdio: ["pipe", "ignore", "pipe"],
      });
      it.proc.stdin.on("error", () => {});
      it.proc.stderr.setEncoding("utf8");
      it.proc.stderr.on("data", (chunk) => {
        it.log += chunk;
        const lines = (partial + chunk).split("\n");
        partial = lines.pop();
        for (const line of lines) {
          const at = line.indexOf(stateMarker);
          if (at >= 0) it.states.push(JSON.parse(line.slice(at + stateMarker.length)));
        }
      });
      it.exit = new Promise((r) => it.proc.on("exit", (code, signal) => r(code ?? signal)));
      running.push(it);
      return it;
    };
    const run = async (it, line) => {
      const marker = `[ray-test] ${line} -> `;
      const from = it.log.length;
      it.proc.stdin.write(line + "\n");
      return until(`command ${line}`, () => {
        const at = it.log.indexOf(marker, from);
        return at >= 0 ? it.log.slice(at + marker.length).split("\n")[0] : null;
      }, 20000, 100);
    };
    const probe = async (it) => { await run(it, "state"); return it.states.at(-1); };
    const reach = (it, what, fn, ms = 10000) => until(what, async () => { const s = await probe(it); return s && fn(s) ? s : null; }, ms, 150);
    const exited = async (it, what) => assert((await Promise.race([it.exit, sleep(15000).then(() => "timeout")])) !== "timeout", what);
    try {
      // First launch: the start page, two links from other apps (Today tabs) and one of them pinned.
      const first = start();
      await reach(first, "first window", (s) => s.sidebar && s.tabs.some((t) => t.url.includes("?start")), 25000);
      await run(first, `appopen link ${origin}/b?fresh1`);
      await run(first, `appopen link ${origin}/c?fresh2`);
      let s = await reach(first, "links open", (s) => ["fresh1", "fresh2"].every((p) => s.sidebar.today.some((e) => e.url.includes(p) && e.live)));
      const pin = s.sidebar.today.find((e) => e.url.includes("fresh2"));
      assert((await run(first, `rowaction pin ${pin.id}`)) === "ok", "pin");
      await reach(first, "pinned", (s) => s.sidebar.pinned.some((e) => e.id === pin.id));
      assert((await run(first, "setting onQuit fresh")) === "ok", "onQuit fresh");
      // ⌘Q: the warning, and Ray still running; Cancel keeps it running.
      await run(first, "menu quit");
      s = await reach(first, "quit warning", (s) => s.general.warning.showing === "quit");
      assert(s.general.warning.last.title === "Quit Ray?" && s.general.warning.last.message.includes("Today's tabs close"), `warning ${JSON.stringify(s.general.warning)}`);
      await sleep(500);
      assert(first.proc.exitCode === null, "Ray quit before the warning was answered");
      assert((await run(first, "warning cancel")) === "ok", "cancel");
      await reach(first, "cancelled", (s) => s.general.warning.showing === null && s.general.warning.last.answer === "cancelled");
      await sleep(500);
      assert(first.proc.exitCode === null, "Cancel quit Ray");
      // Don't ask again: quits, and the setting is off for next time.
      await run(first, "menu quit");
      await reach(first, "quit warning again", (s) => s.general.warning.showing === "quit");
      first.proc.stdin.write("warning suppress\n");
      await exited(first, "Quit with Don't ask again didn't quit within 15 s");
      const saved = JSON.parse(readFileSync(join(dir, "Settings.json"), "utf8"));
      assert(saved.warnBeforeQuitting === false && saved.onQuit === "fresh", `Settings.json ${JSON.stringify(saved)}`);

      // Second launch, Start fresh: Today holds only the start page; the pinned tab stays; ⇧⌘T brings the old one back.
      writeFileSync(join(dir, "Settings.json"), JSON.stringify({ ...saved, warnBeforeQuitting: true }));
      const second = start();
      s = await reach(second, "fresh window", (s) => s.sidebar && s.tabs.some((t) => t.url.includes("?start")), 25000);
      assert(s.sidebar.today.length === 1 && s.sidebar.today[0].url.includes("?start"), `fresh today ${JSON.stringify(s.sidebar.today.map((e) => e.url))}`);
      assert(s.sidebar.pinned.some((e) => e.id === pin.id && !e.live), `pinned after a fresh start ${JSON.stringify(s.sidebar.pinned)}`);
      assert(s.recentlyClosed.items.some((i) => i.title === "Page B" || i.tooltip.includes("fresh1")), `recently closed ${JSON.stringify(s.recentlyClosed)}`);
      assert((await run(second, "menu reopenClosedTab")) === "ok", "reopen");
      await reach(second, "old tab back", (s) => s.sidebar.today.some((e) => e.url.includes("fresh1")));
      // ⌘Q twice: the second one quits.
      await run(second, "menu quit");
      await reach(second, "quit warning", (s) => s.general.warning.showing === "quit");
      second.proc.stdin.write("menu quit\n");
      await exited(second, "⌘Q again didn't quit within 15 s");

      // Third launch, keeping tabs (the default): what was open comes back.
      writeFileSync(join(dir, "Settings.json"), JSON.stringify({ onQuit: "keep" }));
      const third = start();
      s = await reach(third, "kept window", (s) => s.sidebar?.today.some((e) => e.url.includes("fresh1")), 25000);
      assert(s.general.warning.showing === null, "a warning showed at launch");
      third.proc.stdin.write("menu quit\n");
      await exited(third, "a quit with the warning off didn't quit within 15 s");
    } finally {
      for (const it of running) if (it.proc.exitCode === null && it.proc.signalCode === null) it.proc.kill("SIGKILL");
      rmSync(dir, { recursive: true, force: true });
    }
  },
  async "search-engine"() {
    // Settings › Search: the engines with Make Default; the command bar's typed search, its rows and its suggestions
    // follow the chosen one (suggestions from the fixture, `engine` says whose asked); Kagi has none, so nothing is asked.
    await resetSettings();
    await command("setting searchEngine default");
    await command("setting searchSuggestions on");
    await command("settings open search");
    await until("search pane", async () => { await command("state"); return state().settingsWindow.open && state().settingsWindow.pane === "search"; });
    const pane = async () => JSON.parse(await commandResult("searchpane state"));
    let p = await pane();
    assert(p.engines.map((e) => e.id).join() === "google,duckduckgo,bing,brave,ecosia,kagi,startpage,perplexity", `engines ${JSON.stringify(p.engines)}`);
    assert(p.engines.filter((e) => e.default).map((e) => e.id).join() === "google", `default ${JSON.stringify(p.engines)}`);
    assert(state().settingsWindow.rows.search.join() === "searchEngine,searchSuggestions,siteSearches", `rows ${state().settingsWindow.rows.search}`);
    await command("searchpane default duckduckgo");
    await until("DuckDuckGo chosen", async () => { await command("state"); return state().settings.searchEngine === "duckduckgo"; });
    p = await pane();
    assert(p.engines.find((e) => e.id === "duckduckgo").default && !p.engines.find((e) => e.id === "google").default, `after Make Default ${JSON.stringify(p.engines)}`);
    assert(p.template === "https://duckduckgo.com/?q=%s", `template ${p.template}`);
    assert((await commandResult("searchpane default duckduckgo")) === "no such engine", "Make Default offered on the default");
    if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "settings-search-pane.png")}`);
    await closeSettingsWindow();
    const rowsFor = async (text, ready) => {
      await command("menu newTab");
      await until("bar open", async () => { await command("state"); return state().commandBar; });
      await command(`type ${text}`);
      return until(`rows for ${text}`, async () => { await command("state"); const bar = state().commandBar; return bar?.query === text && ready(bar) && bar; });
    };
    let asked = suggestRequests.length;
    let bar = await rowsFor("zzduck", (b) => b.rows.some((r) => r.suggested));
    assert(bar.rows[0].kind === "search" && bar.rows[0].detail === "Search DuckDuckGo" && bar.rows[0].url === "https://duckduckgo.com/?q=zzduck", `typed row ${JSON.stringify(bar.rows[0])}`);
    assert(bar.rows.filter((r) => r.suggested).every((r) => r.url.startsWith("https://duckduckgo.com/?q=zzduck")), `suggestion rows ${JSON.stringify(bar.rows)}`);
    const sent = suggestRequests.slice(asked);
    assert(sent.some((r) => r.q === "zzduck") && sent.every((r) => r.engine === "duckduckgo"), `asked ${JSON.stringify(sent)}`);
    await command("escape");
    // Kagi has no suggestions: nothing is asked and none show.
    await setSetting("searchEngine", "kagi");
    asked = suggestRequests.length;
    await rowsFor("zzkagi", (b) => b.rows[0]?.detail === "Search Kagi");
    await sleep(500);
    await command("state");
    assert(!state().commandBar.rows.some((r) => r.suggested) && state().commandBar.rows[0].url === "https://kagi.com/search?q=zzkagi", `Kagi rows ${JSON.stringify(state().commandBar.rows)}`);
    assert(suggestRequests.length === asked, `Kagi asked ${JSON.stringify(suggestRequests.slice(asked))}`);
    await command("escape");
    // Back to Google (the fixture stands in for it).
    await setSetting("searchEngine", "default");
    bar = await rowsFor("zzgoogle", (b) => b.rows.some((r) => r.suggested));
    assert(bar.rows[0].detail === "Search Google" && bar.rows[0].url === `${origin}/search?q=zzgoogle`, `Google row ${JSON.stringify(bar.rows[0])}`);
    assert(bar.rows.filter((r) => r.suggested).every((r) => r.url.startsWith(`${origin}/search?q=zzgoogle`)), `Google's suggestions ${JSON.stringify(bar.rows)}`);
    await command("escape");
  },
  async "search-suggestions-off"() {
    // Search suggestions off: nothing typed in the command bar goes to the engine, and no suggestion rows.
    await resetSettings();
    await command("setting searchEngine default");
    await setSetting("searchSuggestions", "off");
    const asked = suggestRequests.length;
    await command("menu newTab");
    await until("bar open", async () => { await command("state"); return state().commandBar; });
    await command("type zzoff");
    await until("rows", async () => { await command("state"); return state().commandBar?.query === "zzoff"; });
    await command("type  more");
    await sleep(600);
    await command("state");
    const bar = state().commandBar;
    assert(bar.rows[0].kind === "search" && !bar.rows.some((r) => r.suggested), `rows with suggestions off ${JSON.stringify(bar.rows)}`);
    assert(suggestRequests.length === asked, `sent with suggestions off: ${JSON.stringify(suggestRequests.slice(asked))}`);
    await command("escape");
    // The pane's switch turns them back on.
    await command("settings open search");
    await until("search pane", async () => { await command("state"); return state().settingsWindow.pane === "search"; });
    assert(state().settingsWindow.controls.searchSuggestions === false, `switch ${state().settingsWindow.controls.searchSuggestions}`);
    await command("settings press searchSuggestions");
    await until("on", async () => { await command("state"); return state().settings.searchSuggestions === true && state().settingsWindow.controls.searchSuggestions === true; });
    await closeSettingsWindow();
    await command("menu newTab");
    await command("type zzon");
    await until("suggestions back", async () => { await command("state"); return state().commandBar?.rows.some((r) => r.suggested); });
    assert(suggestRequests.slice(asked).some((r) => r.q === "zzon"), "suggestions on asked nothing");
    await command("escape");
  },
  async "site-search"() {
    // Site searches: added in the pane's editor (bad ones refused with the reason), a keyword then Tab or a space
    // scopes the command bar (a chip, one row, nothing sent for suggestions), Enter searches the site, Delete with
    // nothing typed leaves the scope; edit and remove.
    await resetSettings();
    await command("setting searchEngine default");
    await command("setting searchSuggestions on");
    await command("setting siteSearches default");
    await command("settings open search");
    await until("search pane", async () => { await command("state"); return state().settingsWindow.open && state().settingsWindow.pane === "search"; });
    const pane = async () => JSON.parse(await commandResult("searchpane state"));
    let p = await pane();
    assert(p.sites.empty && p.sites.rows.length === 0 && !p.sites.editorOpen, `empty list ${JSON.stringify(p.sites)}`);
    await command("searchpane add");
    const template = `${origin}/find?q=%s`;
    for (const [fields, why] of [
      [{ name: "", keyword: "fx", url: template }, "Enter a name."],
      [{ name: "Fixture", keyword: "f x", url: template }, "one short word"],
      [{ name: "Fixture", keyword: "google.com", url: template }, "already searches Google"],
      [{ name: "Fixture", keyword: "fx", url: `${origin}/find?q=` }, "Put %s"],
      [{ name: "Fixture", keyword: "fx", url: "javascript:alert(1)//%s" }, "starts with https://"],
      [{ name: "Fixture", keyword: "fx", url: "file:///etc/%s" }, "starts with https://"],
      [{ name: "Fixture", keyword: "fx", url: "https://%s.example.com/" }, "starts with https://"],
    ]) {
      await command(`searchpane fill ${JSON.stringify(fields)}`);
      await command("searchpane save");
      p = await pane();
      assert(p.sites.editorOpen && p.sites.problem?.includes(why), `${JSON.stringify(fields)}: ${JSON.stringify(p.sites)}`);
    }
    await command("state");
    assert(state().settings.siteSearches.length === 0, `a refused site search was saved: ${JSON.stringify(state().settings.siteSearches)}`);
    if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "settings-search-editor.png")}`);
    await command(`searchpane fill ${JSON.stringify({ name: " Fixture ", keyword: "FX", url: template })}`);
    await command("searchpane save");
    const saved = await until("saved", async () => { await command("state"); return state().settings.siteSearches.length === 1 && state().settings.siteSearches[0]; });
    assert(saved.name === "Fixture" && saved.keyword === "fx" && saved.url === template, `saved ${JSON.stringify(saved)}`);
    p = await pane();
    assert(!p.sites.editorOpen && p.sites.rows.join() === "fx" && !p.sites.empty, `after adding ${JSON.stringify(p.sites)}`);
    // A keyword names one site search.
    await command("searchpane add");
    await command(`searchpane fill ${JSON.stringify({ name: "Other", keyword: "fx", url: template })}`);
    await command("searchpane save");
    p = await pane();
    assert(p.sites.problem?.includes("already the keyword for Fixture"), `duplicate ${JSON.stringify(p.sites)}`);
    await command("searchpane cancel");
    if (process.env.SNAP_DIR) await command(`settings snap ${join(process.env.SNAP_DIR, "settings-search-sites.png")}`);
    await closeSettingsWindow();
    // The keyword is offered ("Search Fixture", Tab), and Tab scopes the bar.
    const asked = suggestRequests.length;
    const bar = async (ready) => until("bar", async () => { await command("state"); const b = state().commandBar; return b && ready(b) && b; });
    await command("menu newTab");
    await command("type fx");
    let shown = await bar((b) => b.query === "fx" && b.rows.some((r) => r.kind === "scope"));
    assert(shown.rows[1].kind === "scope" && shown.rows[1].title === "Search Fixture" && shown.rows[1].detail === "Tab" && shown.scope === null, `keyword rows ${JSON.stringify(shown.rows)}`);
    await command("tab");
    shown = await bar((b) => b.scope?.name === "Fixture");
    assert(shown.query === "" && shown.rows.length === 0, `scoped ${JSON.stringify(shown)}`);
    await command("type zzsite query");
    shown = await bar((b) => b.query === "zzsite query" && b.rows.length === 1);
    assert(shown.scope?.keyword === "fx" && shown.rows[0].kind === "search" && shown.rows[0].detail === "Search Fixture" &&
      shown.rows[0].url === `${origin}/find?q=zzsite%20query`, `scoped row ${JSON.stringify(shown)}`);
    await sleep(400);
    assert(!suggestRequests.slice(asked).some((r) => r.q.startsWith("zzsite")), `a scoped search was sent for suggestions: ${JSON.stringify(suggestRequests.slice(asked))}`);
    if (process.env.SNAP_DIR) await command(`barsnap ${join(process.env.SNAP_DIR, "command-bar-site-search.png")}`);
    const before = state().tabs.length;
    await command("enter");
    const tab = await until("site search tab", async () => {
      await command("state");
      return state().tabs.length === before + 1 && state().tabs.find((t) => t.id === state().active && t.url === `${origin}/find?q=zzsite%20query`);
    });
    await command(`rowaction close ${entryOfTab(tab.id).id}`);
    await until("site search tab closed", async () => { await command("state"); return !state().tabs.some((t) => t.id === tab.id); });
    // A space after the keyword scopes it too; Delete with nothing typed leaves, the keyword back in the field.
    await command("menu newTab");
    await command("type fx ");
    shown = await bar((b) => b.scope?.keyword === "fx");
    assert(shown.query === "", `after a space: ${JSON.stringify(shown)}`);
    await command("backspace");
    await bar((b) => b.scope === null && b.query === "fx");
    await command("escape");
    // Typed in one go, the rest is the query.
    await command("menu newTab");
    await command("type FX two words");
    await bar((b) => b.scope?.keyword === "fx" && b.query === "two words");
    await command("escape");
    // Not a keyword: Tab moves down, as before; a built-in engine's host scopes to that engine.
    await command("menu newTab");
    await command("type fxx");
    await bar((b) => b.query === "fxx");
    await command("tab");
    await command("state");
    assert(state().commandBar.scope === null, `fxx scoped ${JSON.stringify(state().commandBar.scope)}`);
    await command("escape");
    await command("menu newTab");
    await command("type duckduckgo.com");
    await bar((b) => b.query === "duckduckgo.com");
    await command("tab");
    await bar((b) => b.scope?.name === "DuckDuckGo");
    await command("type zzdd");
    shown = await bar((b) => b.query === "zzdd" && b.rows.length === 1);
    assert(shown.rows[0].url === "https://duckduckgo.com/?q=zzdd", `DuckDuckGo scope ${JSON.stringify(shown.rows)}`);
    await command("escape");
    // Edit the keyword, then remove it: the old keyword scopes nothing.
    await command("settings open search");
    await until("search pane", async () => { await command("state"); return state().settingsWindow.pane === "search"; });
    await command("searchpane edit fx");
    await command(`searchpane fill ${JSON.stringify({ keyword: "fy" })}`);
    await command("searchpane save");
    await until("edited", async () => { await command("state"); return state().settings.siteSearches.length === 1 && state().settings.siteSearches[0].keyword === "fy"; });
    await command("searchpane remove fy");
    await until("removed", async () => { await command("state"); return state().settings.siteSearches.length === 0; });
    p = await pane();
    assert(p.sites.empty && p.sites.rows.length === 0, `after removing ${JSON.stringify(p.sites)}`);
    await closeSettingsWindow();
    await command("menu newTab");
    await command("type fy ");
    await bar((b) => b.query === "fy ");
    await command("state");
    assert(state().commandBar.scope === null, "a removed keyword still scopes");
    await command("escape");
    await command("setting siteSearches default");
  },
  async "settings-persist"() {
    // Non-default values for every setting; the next launch (the restore check) must find them as they were.
    await resetSettings();
    for (const [name, value] of [["minimalURL", "on"], ["loadingProgress", "off"], ["theme", "#E5589D"], ["defaultZoom", "1.25"],
      ["newTabNextToActive", "on"], ["recentTabCycling", "off"], ["copyLinkShortcut", "off"], ["sidebarShortcut", "off"],
      ["shortcuts", `{"newFolder":"ctrl+cmd+k","find":"none"}`]])
      await setSetting(name, value);
    await command("settings open");
    await closeSettingsWindow();
    const file = join(dataDir, "Settings.json");
    await until("saved", () => existsSync(file) && JSON.parse(readFileSync(file, "utf8")).theme === "#E5589D", 4000);
    const saved = JSON.parse(readFileSync(file, "utf8"));
    assert(saved.minimalURL === true && saved.loadingProgress === false && saved.defaultZoom === 1.25 && saved.newTabNextToActive === true &&
      saved.recentTabCycling === false && saved.copyLinkShortcut === false && saved.sidebarShortcut === false &&
      saved.shortcuts?.newFolder === "ctrl+cmd+k" && saved.shortcuts?.find === "none", `Settings.json ${JSON.stringify(saved)}`);
    assert(!/(https?:|password|cookie)/i.test(readFileSync(file, "utf8")), "Settings.json holds something it shouldn't");
    await command("state");
    savedSettings = state().settings;
  },
  async quit() {
    savedSidebar = state().sidebar;
    savedActive = state().activeEntry;
    child.stdin.write("menu quit\n");
    await Promise.race([exited, sleep(15000)]);
    assert(exitCode !== null, "didn't exit within 15 s");
    const prefs = JSON.parse(readFileSync(join(dataDir, "Chromium/Default/Preferences"), "utf8"));
    assert(prefs.profile?.exit_type === "Normal", `exit_type ${prefs.profile?.exit_type}`);
    const added = crashReports().filter((f) => !crashesBefore.includes(f));
    assert(added.length === 0, `new crash reports: ${added.join(", ")}`);
  },
  async restore() {
    const before = savedSidebar;
    assert(before, "no sidebar state before quitting");
    ws?.close();
    // Remembered full screen must not apply to a hidden test instance.
    const file = join(dataDir, "Sidebar.json");
    writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file, "utf8")), fullScreen: true }));
    launch();
    await connect();
    await until("restored", () => state()?.sidebar && state().sidebar.pinned.length === before.pinned.length);
    await sleep(300);
    await command("state");
    assert(state().fullScreen === false, "a background test instance went full screen");
    // The settings come back as they were left, in the menu, the colour and the window.
    // (Only when the settings-persist check ran before the quit.)
    if (savedSettings) {
    const canon = (o) => JSON.stringify(o, (k, v) => (v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort()) : v));
    assert(canon(state().settings) === canon(savedSettings), `settings changed over the relaunch: ${JSON.stringify(state().settings)} vs ${JSON.stringify(savedSettings)}`);
    assert(state().menuKeys.copyURL === "" && state().menuKeys.toggleSidebar === "", `menu keys after relaunch ${JSON.stringify(state().menuKeys)}`);
    // The user's shortcuts are the menu's again (settings-persist's ⌃⌘K for New Folder, Find with none).
    assert(state().shortcuts.keys.newFolder === "⌃⌘K" && state().shortcuts.keys.find === "", `shortcuts after relaunch ${JSON.stringify(state().shortcuts.keys)}`);
    await command("settings open");
    await until("settings window after relaunch", async () => { await command("state"); return state().settingsWindow.open; });
    const shown = state().settingsWindow.controls;
    assert(shown.minimalURL === true && shown.loadingProgress === false && shown.newTabNextToActive === "Below current" && shown.recentTabCycling === false &&
      shown.copyLinkShortcut === false && shown.sidebarShortcut === false && shown.theme === "#E5589D" && shown.defaultZoom === "125%", `window after relaunch ${JSON.stringify(shown)}`);
    await closeSettingsWindow();
    }
    const after = state().sidebar;
    assert(JSON.stringify(after.favorites.map((e) => e.id)) === JSON.stringify(before.favorites.map((e) => e.id)), "favorites differ");
    assert(JSON.stringify(after.pinned.map((e) => [e.id, e.pinnedURL, e.parent, e.title])) === JSON.stringify(before.pinned.map((e) => [e.id, e.pinnedURL, e.parent, e.title])), "pinned differ");
    assert(JSON.stringify(after.today.map((e) => e.id)) === JSON.stringify(before.today.map((e) => e.id)), "today differs");
    await until("active entry restored and loaded", () => state().activeEntry === savedActive && state().active !== null && oneVisibleActive());
    // Tab names (the tab-rename check leaves some) come back as they were.
    const names = (sidebar) => JSON.stringify([...sidebar.favorites, ...sidebar.pinned, ...sidebar.today].map((e) => [e.id, e.customTitle]));
    assert(names(after) === names(before), `names after relaunch: ${names(after)} vs ${names(before)}`);
    const notActive = [...after.favorites, ...after.pinned, ...after.today].filter((e) => e.id !== savedActive);
    assert(notActive.every((e) => !e.live), "restored tabs other than the active one loaded at launch");
    // Downloads from before the restart are still listed, so the list can be opened again.
    if (downloadedName) await until("download history", () => state().downloads.some((d) => d.filename === downloadedName), 5000);
    const sidebarBefore = state().sidebar;
    const activeBefore = state().activeEntry;
    child.stdin.write("terminate\n");
    await Promise.race([exited, sleep(15000)]);
    assert(exitCode !== null, "NSApp.terminate (Dock / AppleScript quit) didn't quit");
    ws?.close();
    launch();
    await connect();
    await until("restored after a Dock-style quit", () => state()?.sidebar && state().activeEntry === activeBefore && oneVisibleActive());
    const again = state().sidebar;
    assert(JSON.stringify([...again.favorites, ...again.pinned, ...again.today].map((e) => e.id)) ===
      JSON.stringify([...sidebarBefore.favorites, ...sidebarBefore.pinned, ...sidebarBefore.today].map((e) => e.id)), "entries lost on a Dock-style quit");
    child.stdin.write("menu quit\n");
    await Promise.race([exited, sleep(15000)]);
  },
};

function crashReports() {
  const dir = join(homedir(), "Library/Logs/DiagnosticReports");
  return existsSync(dir) ? readdirSync(dir).filter((f) => f.startsWith("Ray")) : [];
}

const wanted = process.argv.slice(2);
const order = Object.keys(checks).filter(
  (name) => !wanted.length || wanted.includes(name) || name === "boot" || name === "quit" || name === "restore");
let failed = 0;
let skipped = 0;
try {
  await connect();
  for (const name of order) {
    const started = Date.now();
    try {
      await checks[name]();
      console.log(`ok   ${name} (${Date.now() - started} ms)`);
    } catch (error) {
      if (error instanceof Skip) {
        skipped++;
        console.log(`skip ${name}: ${error.message}`);
        continue;
      }
      failed++;
      console.log(`FAIL ${name}: ${error.message}`);
      console.log(`     state: ${JSON.stringify(state())}`);
      const notes = stderr.split("\n").filter((l) => l.includes("[ray] ") && !l.includes("loaded") && !l.includes("inserted")).slice(-3);
      for (const note of notes) console.log(`     log: ${note.slice(note.indexOf("[ray]"))}`);
    }
  }
} finally {
  if (exitCode === null) {
    child.kill("SIGTERM");
    await Promise.race([exited, sleep(10000)]);
    if (exitCode === null) child.kill("SIGKILL");
  }
  ws?.close();
  server.close();
}
const ran = order.length - skipped;
const skipNote = skipped ? `, ${skipped} skipped` : "";
console.log(failed ? `${failed} of ${ran} failed${skipNote} (data: ${dataDir})` : `all ${ran} passed${skipNote}`);
process.exit(failed ? 1 : 0);

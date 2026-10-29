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
  "/h": `<title>Hist Page</title><p>history</p>`,
  "/find": `<title>Find</title><p>banana one</p><p>apple</p><p>banana two</p><p>banana three</p>`,
  "/search": `<title>Search</title><p>results</p>`,
  "/long": `<title>Long</title><style>body{margin:0;font:16px/1.6 sans-serif}p{margin:0 16px 12px}</style>` +
    Array.from({ length: 120 }, (_, i) => `<p id=p${i}>Paragraph ${i}: the quick brown fox jumps over the lazy dog, again and again, to make lines wrap differently at different widths.</p>`).join(""),
};
// Requests to /safe-storage/…, with the cookies they carried (the safe-storage-migration check).
const safeStorageRequests = [];
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
      RAY_SUGGEST_URL: `${origin}/suggest?q=%s`,
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
    ["newTabNextToActive", "off"], ["recentTabCycling", "on"], ["copyLinkShortcut", "on"], ["sidebarShortcut", "on"]])
    await command(`setting ${name} ${value}`);
  await command("state");
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
    assert(tabRows.length === Math.min(8, state().tabs.length - 1), `expected the other tabs, got ${tabRows.length}`);
    assert(bar.rows.slice(0, tabRows.length).every((r) => r.kind === "tab"), `open tabs should come first: ${JSON.stringify(bar.rows)}`);
    assert(bar.rows.slice(tabRows.length).every((r) => r.kind === "history"), `then frequent history: ${JSON.stringify(bar.rows)}`);
    await command("escape");
  },
  async "bar-switch-to-tab"() {
    const before = state().tabs.length;
    await command("menu newTab");
    await command("type Page B");
    const bar = await until("tab row", () => state().commandBar?.rows.some((r) => r.kind === "tab") && state().commandBar);
    assert(bar.rows[0].kind === "search", `first row ${bar.rows[0].kind}`);
    const tabRow = bar.rows.findIndex((r) => r.kind === "tab");
    for (let i = 0; i < tabRow; i++) await command("down");
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
    // Search is a fixed Google (the engine's default can't be changed from Ray): the bar says so, and a search goes
    // to the template (here the RAY_SEARCH_URL fixture), not to anything the engine reports.
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
    await command("menu showHistory");
    await until("history tab", async () => { await command("state"); return activeTabState()?.url.startsWith("chrome://history"); });
    bar = await barFor("history");
    assert(bar.rows[0].kind === "tab", `"history" first row: ${JSON.stringify(bar.rows[0])}`);
    assert(actionRow(bar, "Show Full History") > 0, `"history" didn't offer History: ${JSON.stringify(bar.rows)}`);
    await command("escape");
    await command("menu closeTab");
    await until("back on the page", async () => { await command("state"); return state().active === page; });
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
    writeFileSync(join(dir, "popup.html"), `<!doctype html><body style="width:220px;height:90px">fixture popup</body>`);
    const from = stderr.length;
    await command(`extinstall ${dir}`);
    const id = await until("installed", () => stderr.slice(from).match(/\[ray-test\] installed ([a-p]{32})/)?.[1], 15000);
    await until("listed", async () => { await command("state"); return state().extensions.some((e) => e.id === id && e.enabled); }, 8000);
    const before = state().sidebar.today.length;
    await command(`extrun ${id}`);
    await until("popup open", () => state().extensionPopup?.startsWith(`chrome-extension://${id}/popup.html`));
    await until("popup page loaded", async () => (await targets()).some((t) => t.url.startsWith(`chrome-extension://${id}/popup.html`)), 8000);
    assert(state().sidebar.today.length === before, "the popup page showed up as a tab");
    assert(![...state().sidebar.today, ...state().sidebar.pinned].some((e) => e.url.startsWith("chrome-extension://")), "popup in the sidebar");
    await command("extclose");
    await until("popup closed", () => state().extensionPopup === null);
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
    // One signing identity across builds when the owner's "Ray Code Signing" certificate is installed, so macOS keeps
    // "Always Allow" for "Ray Safe Storage" (and privacy permissions) from build to build.
    if (execFileSync("security", ["find-identity", "-p", "codesigning"], { encoding: "utf8" }).includes('"Ray Code Signing"')) {
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
    assert(win().title === "Settings" && win().pane === "appearance", `window ${JSON.stringify(win())}`);
    assert(state().menuKeys.settings === ",", `Settings… answers to ${state().menuKeys.settings}`);
    const [, , width, height] = win().frame.match(/-?[\d.]+/g).map(Number);
    assert(width === 640 && height >= 560 && height < 620, `the window is ${width} x ${height}`);
    // The defaults, as the controls show them.
    assert(c().minimalURL === false && c().loadingProgress === true && c().newTabNextToActive === false &&
      c().recentTabCycling === true && c().copyLinkShortcut === true && c().sidebarShortcut === true, `switches ${JSON.stringify(c())}`);
    assert(c().zoom === "100%" && c().zoomLevels.length === 17 && c().zoomLevels[0] === "25%" && c().zoomLevels.at(-1) === "500%", `zoom ${c().zoomLevels}`);
    assert(c().swatch === "default" && c().swatches === 9 && c().swatchSelected === 0, `swatches ${c().swatch} ${c().swatches} ${c().swatchSelected}`);
    assert(c().allSettingsLink === "All Settings…", `link ${c().allSettingsLink}`);
    // A control changes the setting, and a setting changed anywhere else shows in the control.
    await command("settings press minimalURL");
    await until("switch changed the setting", async () => { await command("state"); return state().settings.minimalURL === true; });
    await setSetting("minimalURL", "off");
    await until("control follows the setting", async () => { await command("state"); return c().minimalURL === false; });
    await command("settings press swatch 3");
    await until("swatch chose Green", async () => { await command("state"); return state().settings.theme.setting === "#3EA64A" && c().swatchSelected === 3; });
    await command("settings press zoom 9");
    await until("popup chose 125%", async () => { await command("state"); return state().settings.defaultZoom === 1.25 && c().zoom === "125%"; });
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
    assert(state().settingsWindow.controls.swatch === "#14146E" && state().settingsWindow.controls.swatchSelected === 8, `custom ${JSON.stringify(state().settingsWindow.controls)}`);
    await setSetting("theme", "#12A594");
    await until("preset selected", async () => { await command("state"); return state().settingsWindow.controls.swatchSelected === 2; });
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
    // Ray's own Settings window has the first two, and Ray searches with a fixed Google.
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
    // Search engine is gone with no window to stand in for it: its addresses show the settings page itself, in the same
    // tab, from a navigation in the page and typed (ray:// or chrome://).
    const noSearchPage = async (why) => {
      await command("state");
      // Only settings addresses count: earlier checks can leave the fixture's own /search page open.
      assert(state().tabs.length === tabCount + 1 && !state().tabs.some((t) => /^chrome:\/\/settings\/search/i.test(t.url)), `${why}: ${state().tabs.map((t) => t.url)}`);
      assert(!state().settingsWindow.open, `${why} opened Ray's Settings window`);
      const r = await read();
      assert(r.searchPage === 0 && !r.views.includes("search") && r.last === "/performance", `${why} shows ${r.last} ${r.views}`);
    };
    for (const path of ["/searchEngines", "/search"]) {
      await evaluate(sid, `location.href = "chrome://settings${path}"`);
      await until(`tab left ${path}`, async () => { await command("state"); return state().tabs.find((t) => t.id === settingsTab)?.url === "chrome://settings/"; }, 6000);
      await until(`settings page back after ${path}`, async () => (await read().catch(() => null))?.menu.length > 0, 10000);
      await sleep(500);
      await noSearchPage(`navigating to ${path}`);
    }
    for (const typed of ["ray://settings/search", "chrome://settings/searchEngines"]) {
      await goTo(typed);
      await sleep(1500);
      await until(`settings page back after ${typed}`, async () => (await read().catch(() => null))?.menu.length > 0, 10000);
      await noSearchPage(`typing ${typed}`);
    }
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
    const start = () => {
      const it = { log: "", states: [] };
      let partial = "";
      it.proc = spawn(join(app, "Contents/MacOS/Ray"), [], {
        env: { ...process.env, RAY_BACKGROUND: "1", RAY_TEST_COMMANDS: "1", RAY_LOG_STATE: "1", RAY_ONBOARDING: "1",
          RAY_IMPORT_SOURCE_DIR: support, RAY_DATA_DIR: dir, RAY_DOWNLOADS_DIR: join(dir, "Downloads"), RAY_START_URL: `${origin}/a`,
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
  async "settings-persist"() {
    // Non-default values for every setting; the next launch (the restore check) must find them as they were.
    await resetSettings();
    for (const [name, value] of [["minimalURL", "on"], ["loadingProgress", "off"], ["theme", "#E5589D"], ["defaultZoom", "1.25"],
      ["newTabNextToActive", "on"], ["recentTabCycling", "off"], ["copyLinkShortcut", "off"], ["sidebarShortcut", "off"]])
      await setSetting(name, value);
    await command("settings open");
    await closeSettingsWindow();
    const file = join(dataDir, "Settings.json");
    await until("saved", () => existsSync(file) && JSON.parse(readFileSync(file, "utf8")).theme === "#E5589D", 4000);
    const saved = JSON.parse(readFileSync(file, "utf8"));
    assert(saved.minimalURL === true && saved.loadingProgress === false && saved.defaultZoom === 1.25 && saved.newTabNextToActive === true &&
      saved.recentTabCycling === false && saved.copyLinkShortcut === false && saved.sidebarShortcut === false, `Settings.json ${JSON.stringify(saved)}`);
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
    await command("settings open");
    await until("settings window after relaunch", async () => { await command("state"); return state().settingsWindow.open; });
    const shown = state().settingsWindow.controls;
    assert(shown.minimalURL === true && shown.loadingProgress === false && shown.newTabNextToActive === true && shown.recentTabCycling === false &&
      shown.copyLinkShortcut === false && shown.sidebarShortcut === false && shown.swatch === "#E5589D" && shown.zoom === "125%", `window after relaunch ${JSON.stringify(shown)}`);
    await closeSettingsWindow();
    }
    const after = state().sidebar;
    assert(JSON.stringify(after.favorites.map((e) => e.id)) === JSON.stringify(before.favorites.map((e) => e.id)), "favorites differ");
    assert(JSON.stringify(after.pinned.map((e) => [e.id, e.pinnedURL, e.parent, e.title])) === JSON.stringify(before.pinned.map((e) => [e.id, e.pinnedURL, e.parent, e.title])), "pinned differ");
    assert(JSON.stringify(after.today.map((e) => e.id)) === JSON.stringify(before.today.map((e) => e.id)), "today differs");
    await until("active entry restored and loaded", () => state().activeEntry === savedActive && state().active !== null && oneVisibleActive());
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

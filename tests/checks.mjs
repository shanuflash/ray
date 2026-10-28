#!/usr/bin/env node
// Drives a hidden build/Ray.app over DevTools and Ray's [ray-state] log.
//   node tests/checks.mjs [check …]      (build first: scripts/build-app.sh)
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { createServer as createSecureServer } from "node:https";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const app = join(root, "build/RayTests.app");
const port = 9400 + Math.floor(Math.random() * 400);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const pages = {
  "/a": `<title>Page A</title><a id=blank href="/b" target="_blank">blank</a> <a id=plain href="/b">plain</a>
         <button id=open onclick="window.open('/c')">open</button>`,
  "/b": `<title>Page B</title><p>b</p>`,
  "/c": `<title>Page C</title><button id=close onclick="window.close()">close</button>`,
  "/h": `<title>Hist Page</title><p>history</p>`,
  "/find": `<title>Find</title><p>banana one</p><p>apple</p><p>banana two</p><p>banana three</p>`,
  "/search": `<title>Search</title><p>results</p>`,
  "/long": `<title>Long</title><style>body{margin:0;font:16px/1.6 sans-serif}p{margin:0 16px 12px}</style>` +
    Array.from({ length: 120 }, (_, i) => `<p id=p${i}>Paragraph ${i}: the quick brown fox jumps over the lazy dog, again and again, to make lines wrap differently at different widths.</p>`).join(""),
};
function serve(req, res) {
  const url = new URL(req.url, "http://x");
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
    }));
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
    // A file over plain HTTP from a secure page never lands (the engine cancels Chrome's insecure download).
    const insecure = origin.replace("127.0.0.1", "ray.test");
    await send("Target.createTarget", { url: `${secureOrigin}/b?dl` });
    const { sessionId } = await session(secureOrigin);
    await until("loaded", async () => (await evaluate(sessionId, `document.readyState`)) === "complete");
    await evaluate(sessionId, `(() => { const a = document.createElement("a"); a.href = ${JSON.stringify(insecure + "/files/held.txt")}; a.click(); })()`);
    const item = await until("blocked", () => state().downloads.find((d) => d.filename === "held.txt" && d.state !== "downloading"), 15000);
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
  async "page-toolbar"() {
    // The address bar above the page shows host and path, and View › Show Address Bar on Page turns it off.
    const entryFor = (tabId) => ["favorites", "pinned", "today"].flatMap((k) => state().sidebar[k]).find((e) => e.tab === tabId);
    await command(`row ${entryFor(tabFor("/a").id).id}`);
    await until("/a active", () => state().active === tabFor("/a").id);
    await until("address", async () => { await command("state"); return state().toolbar?.address === origin.replace("http://", "") + "/a"; });
    if (process.env.SNAP_DIR) await command(`toolbarsnap ${join(process.env.SNAP_DIR, "toolbar.png")}`);
    const cardTop = () => { const [, y, , h] = state().cardFrame.match(/-?[\d.]+/g).map(Number); return y + h; };
    const withBar = cardTop();
    await command("menu toggleToolbar");
    await until("bar off", async () => { await command("state"); return state().toolbar === null; });
    assert(cardTop() > withBar, `the page didn't grow into the bar's room (${withBar} -> ${cardTop()})`);
    await command("menu toggleToolbar");
    await until("bar on", async () => { await command("state"); return state().toolbar !== null; });
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
    assert(panel().security === "Not Secure", `an http page says ${panel().security}`);
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
  async "sidebar-toggle"() {
    await needsFrames();
    const x = () => Number(state().cardFrame.match(/-?[\d.]+/g)[0]);
    assert(x() > 200, `card starts at ${x()}`);
    await command("menu toggleSidebar");
    await until("sidebar hidden", () => state().sidebar.hidden);
    await until("card slid left", async () => { await command("state"); return x() < 20; }, 3000, 50);
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

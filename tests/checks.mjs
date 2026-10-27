#!/usr/bin/env node
// Drives a hidden build/Ray.app over DevTools and Ray's [ray-state] log.
//   node tests/checks.mjs [check …]      (build first: scripts/build-app.sh)
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, existsSync, readdirSync, statSync } from "node:fs";
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
  "/search": `<title>Search</title><p>results</p>`,
  "/long": `<title>Long</title><style>body{margin:0;font:16px/1.6 sans-serif}p{margin:0 16px 12px}</style>` +
    Array.from({ length: 120 }, (_, i) => `<p id=p${i}>Paragraph ${i}: the quick brown fox jumps over the lazy dog, again and again, to make lines wrap differently at different widths.</p>`).join(""),
};
const server = createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/suggest") {
    const q = url.searchParams.get("q") ?? "";
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify([q, q.startsWith("zz") ? [`${q} one`, `${q} two`, q] : []]));
  }
  const body = pages[url.pathname];
  res.writeHead(body ? 200 : 404, { "content-type": "text/html" });
  res.end(body ?? "not found");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;

const dataDir = mkdtempSync(join(tmpdir(), "ray-checks-"));
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

let savedSidebar = null;
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
    const { sessionId } = await session("/a");
    const result = await evaluate(sessionId, `Notification.requestPermission()`);
    assert(result === "default" || result === "denied", `notification permission answered ${result}`);
    await until("permission log", () => stderr.includes("[ray] permission"));
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
    const frame = state().windowFrame;
    await sleep(Number(process.env.STRIP_WAIT ?? 300));
    child.stdin.write("hit 400 14\n");
    await sleep(100);
    console.log("     hit:", (stderr.match(/\[ray-test\] hit 400 14 -> (.*)/) || [])[1], "pages:", JSON.stringify(state().pages));
    await command("drag 400 14 120 60");
    await sleep(300);
    const downs = await evaluate(sessionId, `JSON.stringify(window.__downs)`);
    assert(JSON.parse(downs).length === 1, `page saw mousedowns ${downs}`);
    await command("menu newTab");
    await command("escape");
    assert(state().windowMovable === true, "window left unmovable after the drag");
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
    assert(state().tabs.length === liveBefore - 1, "the tab wasn't closed");
    await command(`row ${id}`);
    await until("reloaded and active", () => state().sidebar.pinned.find((e) => e.id === id)?.live && state().activeEntry === id);
    assert(oneVisibleActive(), "pinned tab not shown");
  },
  async favorites() {
    const id = state().sidebar.today[0].id;
    await command(`rowaction favorite ${id}`);
    await until("favorite", () => state().sidebar.favorites.some((e) => e.id === id) && !state().sidebar.today.some((e) => e.id === id));
    await command(`row ${id}`);
    await until("favorite active", () => state().activeEntry === id && oneVisibleActive());
  },
  async "sidebar-toggle"() {
    const x = () => Number(state().cardFrame.match(/-?[\d.]+/g)[0]);
    assert(x() > 200, `card starts at ${x()}`);
    await command("menu toggleSidebar");
    await until("sidebar hidden", () => state().sidebar.hidden);
    await until("card slid left", async () => { await command("state"); return x() < 20; }, 3000, 50);
    await command("peek on");
    await until("peeking", () => state().sidebar.peeking);
    assert(x() < 20, "peeking moved the page");
    await command("peek off");
    await until("peek ended", () => !state().sidebar.peeking);
    await command("menu toggleSidebar");
    await until("sidebar shown", () => !state().sidebar.hidden);
    await until("card back", async () => { await command("state"); return x() > 200; }, 3000, 50);
  },
  async "peek-zones"() {
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
    const reopen = state().sidebar.favorites[0]?.id ?? state().sidebar.pinned[0]?.id;
    await command(`row ${reopen}`);
    await until("a tab is open", () => state().active !== null);
    await command("pointer 600 300");
    await until("sidebar hides again", () => !state().sidebar.peeking);
    await command("menu toggleSidebar");
    await until("shown", () => !state().sidebar.hidden);
    assert(state().tabs.length === state().sidebar.pinned.filter((e) => e.live).length + state().sidebar.favorites.filter((e) => e.live).length, "today tabs still loaded");
  },
  async "window-lights"() {
    await command("state");
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
    launch();
    await connect();
    await until("restored", () => state()?.sidebar && state().sidebar.pinned.length === before.pinned.length);
    const after = state().sidebar;
    assert(JSON.stringify(after.favorites.map((e) => e.id)) === JSON.stringify(before.favorites.map((e) => e.id)), "favorites differ");
    assert(JSON.stringify(after.pinned.map((e) => [e.id, e.pinnedURL])) === JSON.stringify(before.pinned.map((e) => [e.id, e.pinnedURL])), "pinned differ");
    assert(JSON.stringify(after.today.map((e) => e.id)) === JSON.stringify(before.today.map((e) => e.id)), "today differs");
    await until("active entry restored and loaded", () => state().activeEntry === savedActive && state().active !== null && oneVisibleActive());
    const notActive = [...after.favorites, ...after.pinned, ...after.today].filter((e) => e.id !== savedActive);
    assert(notActive.every((e) => !e.live), "restored tabs other than the active one loaded at launch");
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

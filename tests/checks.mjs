#!/usr/bin/env node
// Drives a hidden build/Lumen.app over DevTools and Lumen's [lumen-state] log.
//   node tests/checks.mjs [check …]      (build first: scripts/build-app.sh)
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const app = join(root, "build/Lumen.app");
const port = 9400 + Math.floor(Math.random() * 400);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const pages = {
  "/a": `<title>Page A</title><a id=blank href="/b" target="_blank">blank</a> <a id=plain href="/b">plain</a>
         <button id=open onclick="window.open('/c')">open</button>`,
  "/b": `<title>Page B</title><p>b</p>`,
  "/c": `<title>Page C</title><button id=close onclick="window.close()">close</button>`,
};
const server = createServer((req, res) => {
  const body = pages[new URL(req.url, "http://x").pathname];
  res.writeHead(body ? 200 : 404, { "content-type": "text/html" });
  res.end(body ?? "not found");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;

const dataDir = mkdtempSync(join(tmpdir(), "lumen-checks-"));
const crashesBefore = crashReports();
let stderr = "";
let states = [];
const child = spawn(join(app, "Contents/MacOS/Lumen"), [], {
  env: {
    ...process.env,
    LUMEN_BACKGROUND: "1",
    LUMEN_LOG_STATE: "1",
    LUMEN_TEST_COMMANDS: "1",
    LUMEN_DATA_DIR: dataDir,
    LUMEN_REMOTE_DEBUGGING_PORT: String(port),
    LUMEN_START_URL: `${origin}/a`,
  },
  stdio: ["pipe", "ignore", "pipe"],
});
child.stdin.on("error", () => {});
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  stderr += chunk;
  for (const line of chunk.split("\n")) {
    const at = line.indexOf("[lumen-state] ");
    if (at >= 0) states.push(JSON.parse(line.slice(at + 14)));
  }
});
let exitCode = null;
const exited = new Promise((r) => child.on("exit", (code, signal) => r((exitCode = code ?? signal))));

const state = () => states.at(-1);
async function until(what, fn, ms = 8000) {
  const end = Date.now() + ms;
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(100);
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
  const marker = `[lumen-test] ${line} -> `;
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
    assert(state().address.includes("/a"), `address shows ${state().address}`);
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
    await until("permission log", () => stderr.includes("[lumen] permission"));
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
    await command("type something");
    await command("escape");
    await sleep(300);
    assert(state().tabs.length === before, "Esc opened a tab");
    assert(state().active === active, "Esc changed the active tab");
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
  async quit() {
    send("Browser.close").catch(() => {});
    await Promise.race([exited, sleep(15000)]);
    assert(exitCode !== null, "didn't exit within 15 s");
    const prefs = JSON.parse(readFileSync(join(dataDir, "Chromium/Default/Preferences"), "utf8"));
    assert(prefs.profile?.exit_type === "Normal", `exit_type ${prefs.profile?.exit_type}`);
    const added = crashReports().filter((f) => !crashesBefore.includes(f));
    assert(added.length === 0, `new crash reports: ${added.join(", ")}`);
  },
};

function crashReports() {
  const dir = join(homedir(), "Library/Logs/DiagnosticReports");
  return existsSync(dir) ? readdirSync(dir).filter((f) => f.startsWith("Lumen")) : [];
}

const wanted = process.argv.slice(2);
const order = Object.keys(checks).filter((name) => !wanted.length || wanted.includes(name) || name === "boot" || name === "quit");
let failed = 0;
try {
  await connect();
  for (const name of order) {
    const started = Date.now();
    try {
      await checks[name]();
      console.log(`ok   ${name} (${Date.now() - started} ms)`);
    } catch (error) {
      failed++;
      console.log(`FAIL ${name}: ${error.message}`);
      console.log(`     state: ${JSON.stringify(state())}`);
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
console.log(failed ? `${failed} of ${order.length} failed (data: ${dataDir})` : `all ${order.length} passed`);
process.exit(failed ? 1 : 0);

// A stand-in for Google Chrome in the jumpcloud-relay check: speaks Chrome's DevTools pipe protocol (reads fd 3,
// writes fd 4, each message JSON ending in NUL) for the calls Ray's JumpCloud relay makes, and writes what it was
// started with and asked into $RAY_STANDIN_DIR. Never a real browser, never the network.
//   RAY_STANDIN_DIR=<dir> node tests/jumpcloud-chrome-standin.mjs <Chrome's arguments>
// <dir>/mode says how it behaves: "success" (the login page reaches the user console), "never" (it stays on the login
// page), "headlessNever" (it stays there when started with --headless=new, and gets there in 2 s in a window),
// "silent" (it never answers, as a Chrome whose policy forbids remote debugging), "setup" (the Web Store window,
// closed by the user after a moment). Headless relays come as createTarget about:blank, attachToTarget (flat),
// Emulation.setUserAgentOverride and Page.navigate on that session.
import { appendFileSync, readFileSync } from "node:fs";
import { Socket } from "node:net";
import { join } from "node:path";

const dir = process.env.RAY_STANDIN_DIR;
const log = (file, value) => appendFileSync(join(dir, file), JSON.stringify(value) + "\n");
const mode = readFileSync(join(dir, "mode"), "utf8").trim();
log("launches.jsonl", { pid: process.pid, mode, argv: process.argv.slice(2) });

process.on("SIGTERM", () => {
  log("cdp.jsonl", { pid: process.pid, signal: "SIGTERM" });
  process.exit(0);
});
if (mode === "silent") setInterval(() => {}, 1 << 30);
else {
  // Pipes as sockets (libuv pipe handles): an fs stream on a pipe blocks a worker thread in read(), and the process
  // then can't exit.
  const out = new Socket({ fd: 4, readable: false, writable: true });
  const send = (message) => out.write(JSON.stringify(message) + "\0");
  const emit = (method, params) => send({ method, params });
  const targets = new Map();
  let nextTarget = 1;
  // Cookies Chrome would hold after signing in: JumpCloud's (a session one, a host-only one, a domain one) and others
  // that must stay out of Ray.
  const expires = Date.now() / 1000 + 3600;
  const cookies = [
    { name: "jcsession", value: "relay-session-1", domain: "console.jumpcloud.com", path: "/", expires: -1, size: 24,
      httpOnly: true, secure: true, session: true, sameSite: "Lax", priority: "Medium", sourceScheme: "Secure", sourcePort: 443 },
    { name: "jcuser", value: "relay-user-1", domain: ".jumpcloud.com", path: "/", expires, size: 18, httpOnly: false,
      secure: true, session: false, sameSite: "None", priority: "Medium", sourceScheme: "Secure", sourcePort: 443 },
    { name: "other", value: "not-for-ray", domain: ".example.com", path: "/", expires, size: 16, httpOnly: false,
      secure: true, session: false, priority: "Medium", sourceScheme: "Secure", sourcePort: 443 },
    { name: "lookalike", value: "not-for-ray", domain: ".notjumpcloud.com", path: "/", expires, size: 20, httpOnly: false,
      secure: true, session: false, priority: "Medium", sourceScheme: "Secure", sourcePort: 443 },
    { name: "suffix", value: "not-for-ray", domain: "jumpcloud.com.evil.test", path: "/", expires, size: 17,
      httpOnly: false, secure: true, session: false, priority: "Medium", sourceScheme: "Secure", sourcePort: 443 },
  ];
  const info = (id) => ({ targetId: id, type: "page", title: "", url: targets.get(id), attached: false, canAccessOpener: false });
  const sessions = new Map();
  let nextSession = 1;
  // A page reaching the console's login page signs in on its own (as JumpCloud Go does) when the mode says so: 0.4 s
  // later, or 2 s later for a windowed Chrome after headless never got there.
  const headless = process.argv.includes("--headless=new");
  const navigated = (id, url) => {
    if (!url.endsWith("/login")) return;
    const delay = mode === "success" ? 400 : mode === "headlessNever" && !headless ? 2000 : null;
    if (delay === null) return;
    setTimeout(() => {
      if (!targets.has(id)) return;
      targets.set(id, url.replace(/\/login$/, "/userconsole/#/"));
      emit("Target.targetInfoChanged", { targetInfo: info(id) });
    }, delay);
  };
  const handlers = {
    "Target.setDiscoverTargets": () => ({}),
    "Target.createTarget": ({ url }) => {
      const id = `T${nextTarget++}`;
      targets.set(id, url);
      setTimeout(() => emit("Target.targetCreated", { targetInfo: info(id) }), 20);
      navigated(id, url);
      if (mode === "setup") {
        setTimeout(() => {
          targets.delete(id);
          emit("Target.targetDestroyed", { targetId: id });
        }, 600);
      }
      return { targetId: id };
    },
    "Target.attachToTarget": ({ targetId }) => {
      if (!targets.has(targetId)) throw new Error("No target with given id found");
      const sessionId = `S${nextSession++}`;
      sessions.set(sessionId, targetId);
      return { sessionId };
    },
    "Emulation.setUserAgentOverride": () => ({}),
    "Page.navigate": ({ url }, sessionId) => {
      const id = sessions.get(sessionId);
      if (!id) throw new Error("'Page.navigate' wasn't found");
      targets.set(id, url);
      setTimeout(() => emit("Target.targetInfoChanged", { targetInfo: info(id) }), 10);
      navigated(id, url);
      return { frameId: id, loaderId: "L1" };
    },
    "Browser.getWindowForTarget": () => ({ windowId: 7, bounds: { left: 0, top: 0, width: 800, height: 600, windowState: "normal" } }),
    "Browser.setWindowBounds": () => ({}),
    "Storage.getCookies": () => ({ cookies }),
    "Target.closeTarget": ({ targetId }) => {
      targets.delete(targetId);
      setTimeout(() => emit("Target.targetDestroyed", { targetId }), 10);
      return { success: true };
    },
    "Browser.close": () => {
      setTimeout(() => process.exit(0), 50);
      return {};
    },
  };
  let buffer = Buffer.alloc(0);
  const input = new Socket({ fd: 3, readable: true, writable: false });
  input.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (let end; (end = buffer.indexOf(0)) >= 0; ) {
      const message = JSON.parse(buffer.subarray(0, end).toString("utf8"));
      buffer = buffer.subarray(end + 1);
      log("cdp.jsonl", { pid: process.pid, method: message.method, params: message.params, sessionId: message.sessionId });
      const handler = handlers[message.method];
      const reply = message.sessionId ? { sessionId: message.sessionId } : {};
      if (!handler) {
        send({ ...reply, id: message.id, error: { code: -32601, message: `'${message.method}' wasn't found` } });
        continue;
      }
      try { send({ ...reply, id: message.id, result: handler(message.params ?? {}, message.sessionId) }); }
      catch (error) { send({ ...reply, id: message.id, error: { code: -32000, message: error.message } }); }
    }
  });
  // Ray went away: Chrome closes itself when its pipe closes.
  input.on("end", () => process.exit(0));
}

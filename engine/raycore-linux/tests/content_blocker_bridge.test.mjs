import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";

const bridge = readFileSync(new URL("../content-blocker/ray-linux-bridge.js", import.meta.url), "utf8");
const page = readFileSync(new URL("../content-blocker/ray-linux-bridge.html", import.meta.url), "utf8");
const EXTENSION = "fajbdaomknpkicfjcpipdmcpoamdmilh";
const OFF = "/^(?:ray-blocking-off|)/";

function fakeUblock({ ready = true, invalidated = false, stalled = false, silent = [], remote = {}, refused = [] } = {}) {
  const state = {
    whitelist: ["chrome-extension-scheme", "moz-extension-scheme"],
    whitelistDefault: ["chrome-extension-scheme", "moz-extension-scheme"],
    available: {
      "ublock-filters": { content: "filters", group: "default", title: "uBlock filters", entryCount: 100 },
      easylist: { content: "filters", group: "ads", title: "EasyList", entryCount: 50000, contentURL: ["https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt", "https://easylist.to/easylist/easylist.txt"] },
      "fanboy-cookiemonster": { content: "filters", group: "annoyances", title: "Cookie notices", off: true, entryCount: 9000, contentURL: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt" },
      "DEU-0": { content: "filters", group: "regions", title: "DEU", off: true, lang: "de", entryCount: 10 },
      "user-filters": { content: "filters", group: "user", title: "My filters" },
    },
    cache: { easylist: { writeTime: 1 } },
    autoUpdate: true,
    reloads: 0,
    messages: [],
    userFilters: "! my own notes\nexample.com##.ad\n  news.example##div.banner  \n||tracker.example^\nexample.com##+js(nowebrtc)\n",
    userFiltersError: null,
    listLoads: 0,
    core: [],
    selections: [],
  };
  const core = {
    userFiltersPath: "user-filters",
    get selectedFilterLists() {
      return Object.keys(state.available).filter((id) => state.available[id].off !== true);
    },
    applyFilterListSelection({ toSelect, merge }) {
      state.core.push("applyFilterListSelection");
      assert.equal(merge, true);
      for (const id of toSelect) state.available[id].off = false;
    },
    loadUserFilters() {
      state.core.push("loadUserFilters");
      return Promise.resolve(state.userFiltersError ? { error: state.userFiltersError } : { content: state.userFilters });
    },
    appendUserFilters(text, options) {
      state.core.push("appendUserFilters");
      assert.equal(JSON.stringify(options), "{}");
      state.userFilters = `${state.userFilters.replace(/\n?$/, "\n")}${text}\n`;
      return Promise.resolve({});
    },
    saveUserFilters(text) {
      state.core.push("saveUserFilters");
      state.userFilters = text;
      return Promise.resolve({});
    },
    loadFilterLists() {
      state.core.push("loadFilterLists");
      state.listLoads++;
      return Promise.resolve();
    },
  };
  const storage = {};
  const messaging = {
    send(channel, message) {
      assert.equal(channel, "dashboard");
      state.messages.push(message.what);
      if (silent.includes(message.what)) return new Promise(() => {});
      switch (message.what) {
        case "getWhitelist":
          return Promise.resolve({ whitelist: [...state.whitelist], whitelistDefault: state.whitelistDefault });
        case "getLists":
          return Promise.resolve({ available: structuredClone(state.available), cache: structuredClone(state.cache), netFilterCount: 1234, cosmeticFilterCount: 56, autoUpdate: state.autoUpdate });
        case "setWhitelist":
          state.whitelist = message.whitelist.split("\n").filter(Boolean);
          return Promise.resolve(null);
        case "userSettings":
          state[message.name] = message.value;
          return Promise.resolve(null);
        case "applyFilterListSelection":
          state.selections.push(structuredClone(message));
          if (Array.isArray(message.toSelect)) {
            for (const [id, list] of Object.entries(state.available)) {
              if (list.group === "user") continue;
              list.off = !message.toSelect.includes(id);
            }
          }
          for (const id of Array.isArray(message.toRemove) ? message.toRemove : []) {
            if (state.available[id] && state.available[id].group === "custom") {
              delete state.available[id];
              delete state.cache[id];
            }
          }
          for (const url of typeof message.toImport === "string" ? message.toImport.split("\n").filter(Boolean) : []) {
            if (refused.includes(url)) continue;
            const needle = url.replace(/^https?:/i, "");
            const stock = Object.keys(state.available).find((k) => [].concat(state.available[k].contentURL || []).some((u) => u.endsWith(needle)));
            if (stock) state.available[stock].off = false;
            else state.available[url] = { content: "filters", group: "custom", title: "", contentURL: url, entryCount: 0 };
          }
          return Promise.resolve(null);
        case "reloadAllFilters":
          state.reloads++;
          for (const [id, list] of Object.entries(state.available)) {
            if (list.group !== "custom" || list.off === true) continue;
            if (remote[id] === undefined) state.cache[id] = { error: "network error" };
            else {
              list.entryCount = remote[id];
              state.cache[id] = { writeTime: 2 };
            }
          }
          return Promise.resolve(null);
        default:
          return Promise.resolve(undefined);
      }
    },
  };
  return { state, storage, messaging, core, ready, invalidated, stalled };
}

function load({ origin = `chrome-extension://${EXTENSION}`, ublock = fakeUblock() } = {}) {
  const attributes = new Map();
  const observers = [];
  const root = {
    getAttribute: (name) => (attributes.has(name) ? attributes.get(name) : null),
    setAttribute(name, value) {
      attributes.set(name, String(value));
      for (const o of observers) if (o.filter.includes(name)) queueMicrotask(() => o.callback());
    },
    removeAttribute(name) {
      if (!attributes.delete(name)) return;
      for (const o of observers) if (o.filter.includes(name)) queueMicrotask(() => o.callback());
    },
  };
  const background = ublock.ready
    ? { "µBlock": Object.assign(ublock.core, { isReadyPromise: ublock.stalled ? new Promise(() => {}) : Promise.resolve() }) }
    : {};
  let looks = 0;
  const locks = [];
  const context = {
    document: {
      documentElement: root,
      createDocumentFragment: () => ({
        querySelector(selector) {
          const count = (c) => selector.split(c).length - 1;
          if (count("[") !== count("]") || count("(") !== count(")")) throw new SyntaxError(`'${selector}' is not a valid selector`);
          return null;
        },
      }),
    },
    location: { origin, href: `${origin}/ray-linux-bridge.html` },
    navigator: {
      languages: ["en-US", "de"],
      locks: {
        request(name, options, hold) {
          const held = hold();
          locks.push({ name, options, held });
          return held;
        },
      },
    },
    MutationObserver: class {
      constructor(callback) {
        this.callback = callback;
      }
      observe(target, options) {
        assert.equal(target, root);
        assert.equal(JSON.stringify(options), JSON.stringify({ attributes: true, attributeFilter: ["data-ray-request"] }));
        observers.push({ callback: this.callback, filter: options.attributeFilter });
      }
    },
    chrome: {
      runtime: { id: EXTENSION, lastError: undefined },
      extension: {
        getBackgroundPage: () => {
          if (ublock.invalidated && ++looks > 1) throw new Error("Extension context invalidated.");
          return background;
        },
      },
      i18n: { getUILanguage: () => "en" },
      storage: {
        local: {
          get(key, done) {
            done(key in ublock.storage ? { [key]: ublock.storage[key] } : {});
          },
          set(value, done) {
            Object.assign(ublock.storage, value);
            done();
          },
          remove(key, done) {
            delete ublock.storage[key];
            done();
          },
        },
      },
    },
    fetch: async (url) => {
      assert.equal(url, "/assets/assets.json");
      return { json: async () => ({ easylist: {}, "ublock-filters": {}, "fanboy-cookiemonster": { off: true }, "DEU-0": { off: true, lang: "de" } }) };
    },
    vAPI: { messaging: ublock.messaging },
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    Date,
    JSON,
    Promise,
    Object,
    Array,
    Number,
    String,
    Set,
    Error,
    queueMicrotask,
  };
  context.self = context;
  runInNewContext(bridge, context);
  let ticket = 0;
  const call = async (op, args = {}, { deadlineMs = 2000, failNext = false } = {}) => {
    const id = ++ticket;
    root.removeAttribute("data-ray-reply");
    root.setAttribute("data-ray-request", JSON.stringify({ ticket: id, op, args, deadlineMs, failNext }));
    for (let i = 0; i < 400; i++) {
      const raw = root.getAttribute("data-ray-reply");
      if (raw) {
        const reply = JSON.parse(raw);
        if (reply.ticket === id) return reply;
      }
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    throw new Error(`no reply to ${op}`);
  };
  const invalidate = () => {
    context.chrome.runtime.id = undefined;
  };
  return { root, call, ublock, attributes, invalidate, locks };
}

test("the bridge page loads uBlock's messaging client before the bridge and marks itself ready", () => {
  const scripts = [...page.matchAll(/<script src="([^"]+)"><\/script>/g)].map((m) => m[1]);
  assert.deepEqual(scripts, ["js/vapi.js", "js/vapi-common.js", "js/vapi-client.js", "ray-linux-bridge.js"]);
  assert.doesNotMatch(page, /<!--/);
  const { root } = load();
  assert.equal(root.getAttribute("data-ray-bridge"), "ready");
});

test("state reports filter lists, defaults, counts and user exceptions", async () => {
  const { call } = load();
  const { value } = await call("state");
  assert.equal(value.enabled, true);
  assert.equal(value.networkFilters, 1234);
  assert.equal(value.cosmeticFilters, 56);
  assert.deepEqual(value.allowedHosts, []);
  const byId = Object.fromEntries(value.lists.map((l) => [l.id, l]));
  assert.equal(byId["user-filters"], undefined);
  assert.equal(byId.easylist.enabled, true);
  assert.equal(byId.easylist.defaultOn, true);
  assert.equal(byId["fanboy-cookiemonster"].enabled, false);
  assert.equal(byId["fanboy-cookiemonster"].defaultOn, false);
  assert.equal(byId["DEU-0"].defaultOn, true);
  assert.equal(byId.easylist.filters, 50000);
  assert.equal(byId.easylist.failed, false);
  assert.equal(byId["DEU-0"].failed, false);
});

test("site exceptions cover subdomains and revoking removes every covering directive", async () => {
  const { call, ublock } = load();
  assert.deepEqual(await call("isAllowed", { host: "news.example.com" }), { ticket: 1, value: false });
  assert.deepEqual(await call("setAllowed", { host: "example.com", allowed: true }), { ticket: 2, value: null });
  assert.equal((await call("isAllowed", { host: "news.example.com" })).value, true);
  assert.equal((await call("isAllowed", { host: "notexample.com" })).value, false);
  assert.deepEqual((await call("state")).value.allowedHosts, ["example.com"]);
  await call("setAllowed", { host: "news.example.com", allowed: false });
  assert.equal((await call("isAllowed", { host: "news.example.com" })).value, false);
  assert.deepEqual(ublock.state.whitelist, ["chrome-extension-scheme", "moz-extension-scheme"]);
});

test("turning blocking off adds the off directive and stops list updates; on removes both", async () => {
  const { call, ublock } = load();
  await call("setEnabled", { enabled: false });
  assert.ok(ublock.state.whitelist.includes(OFF));
  assert.equal(ublock.state.autoUpdate, false);
  assert.equal((await call("state")).value.enabled, false);
  assert.deepEqual((await call("state")).value.allowedHosts, []);
  await call("setEnabled", { enabled: true });
  assert.ok(!ublock.state.whitelist.includes(OFF));
  assert.equal(ublock.state.autoUpdate, true);
});

test("enabling a list applies the selection and reloads filters, leaving no pending reload", async () => {
  const { call, ublock } = load();
  await call("setList", { id: "fanboy-cookiemonster", enabled: true });
  assert.equal(ublock.state.available["fanboy-cookiemonster"].off, false);
  assert.equal(ublock.state.available.easylist.off, false);
  assert.equal(ublock.state.reloads, 1);
  assert.equal(ublock.storage.rayReloadPending, undefined);
  await call("setList", { id: "easylist", enabled: false });
  assert.equal(ublock.state.available.easylist.off, true);
  assert.equal((await call("setList", { id: "nope", enabled: true })).error, "no list nope");
  for (const id of ["constructor", "__proto__", "toString", "hasOwnProperty"]) {
    assert.equal((await call("setList", { id, enabled: true })).error, `no list ${id}`);
  }
  assert.equal(ublock.state.reloads, 2);
});

test("errors are reported, never success: dev failure, unknown operations, foreign pages and a blocker that never starts", async () => {
  const { call } = load();
  assert.equal((await call("setEnabled", { enabled: false }, { failNext: true })).error, "getWhitelist: failed (dev)");
  assert.match((await call("eval", { code: "1" })).error, /unknown operation/);
  assert.match((await call("__proto__")).error, /unknown operation/);
  const foreign = load({ origin: "https://example.com" });
  assert.match((await foreign.call("state")).error, /not the extension page/);
  const stalled = load({ ublock: fakeUblock({ ready: false }) });
  assert.match((await stalled.call("state", {}, { deadlineMs: 50 })).error, /timed out|never started/);
});

test("a bridge page whose extension context was invalidated replies with that error instead of going silent", async () => {
  const lost = load({ ublock: fakeUblock({ ready: false, invalidated: true }) });
  const reply = await lost.call("state", {}, { deadlineMs: 1500 });
  assert.match(reply.error, /Extension context invalidated/);
});

test("a call waiting on uBlock's old background page answers as soon as uBlock reloads itself", async () => {
  const reloading = load({ ublock: fakeUblock({ stalled: true }) });
  setTimeout(reloading.invalidate, 100);
  const started = Date.now();
  const reply = await reloading.call("state", {}, { deadlineMs: 20000 });
  assert.match(reply.error, /Extension context invalidated/);
  assert.ok(Date.now() - started < 1500);
});

test("settings reads the selected lists, every whitelist directive and auto-update for another profile to copy", async () => {
  const { call } = load();
  await call("setAllowed", { host: "news.example", allowed: true });
  await call("setEnabled", { enabled: false });
  const { value } = await call("settings");
  assert.deepEqual(value, {
    lists: ["easylist", "ublock-filters", "user-filters"],
    imported: [],
    whitelist: [OFF, "chrome-extension-scheme", "moz-extension-scheme", "news.example"].sort(),
    autoUpdate: false,
  });
});

test("follow copies the default profile's lists, exceptions and auto-update, and writes nothing already equal", async () => {
  const leader = load();
  await leader.call("setList", { id: "fanboy-cookiemonster", enabled: true });
  await leader.call("setAllowed", { host: "news.example", allowed: true });
  await leader.call("setEnabled", { enabled: false });
  const { value: settings } = await leader.call("settings");
  const follower = load();
  assert.deepEqual(await follower.call("follow", settings), { ticket: 1, value: null });
  assert.deepEqual((await follower.call("settings")).value, settings);
  assert.equal(follower.ublock.state.reloads, 1);
  assert.equal((await follower.call("isAllowed", { host: "a.news.example" })).value, true);
  assert.equal((await follower.call("state")).value.enabled, false);
  const before = follower.ublock.state.messages.length;
  assert.deepEqual((await follower.call("follow", settings)).value, null);
  const written = follower.ublock.state.messages.slice(before).filter((m) => m !== "getLists" && m !== "getWhitelist");
  assert.deepEqual(written, []);
  for (const bad of [{}, { lists: "easylist", whitelist: [] }, { lists: [], whitelist: [3] }, { lists: [1], whitelist: [] }]) {
    assert.match((await follower.call("follow", bad)).error, /no settings to copy/);
  }
});

test("hidden elements are the hiding rules among the profile's own filters, trimmed, and an unreadable file is an error", async () => {
  const { call, ublock } = load();
  assert.deepEqual(await call("hiddenElements"), { ticket: 1, value: ["example.com##.ad", "news.example##div.banner"] });
  ublock.state.userFiltersError = "storage gone";
  assert.equal((await call("hiddenElements")).error, "user filters: storage gone");
  assert.deepEqual(ublock.state.core.filter((c) => c !== "loadUserFilters"), []);
});

test("hiding appends only new valid rules once, turning the user's own list on first", async () => {
  const { call, ublock } = load();
  ublock.state.available["user-filters"].off = true;
  assert.deepEqual(await call("hideElements", { filters: ["a.test##div.x > p", "example.com##.ad", "a.test##div.x > p"] }), { ticket: 1, value: null });
  assert.equal(ublock.state.available["user-filters"].off, false);
  assert.equal(ublock.state.userFilters.split("\n").filter((l) => l === "a.test##div.x > p").length, 1);
  assert.equal(ublock.state.userFilters.split("\n").filter((l) => l.trim() === "example.com##.ad").length, 1);
  assert.deepEqual(ublock.state.core, ["loadUserFilters", "applyFilterListSelection", "appendUserFilters"]);
  ublock.state.core.length = 0;
  assert.deepEqual((await call("hideElements", { filters: ["news.example##div.banner"] })).value, null);
  assert.deepEqual(ublock.state.core, ["loadUserFilters"]);
});

test("hiding refuses anything that isn't a plain hiding rule and writes nothing", async () => {
  const { call, ublock } = load();
  const before = ublock.state.userFilters;
  for (const filters of [["a.test##+js(alert)"], ["a.test##^script"], ["a.test## div"], ["A.test##.x"], ["a.test#.x"], ["a.test##.x{color:red}"], [`a.test##.${"x".repeat(1020)}`], [3], "a.test##.x", null]) {
    assert.match((await call("hideElements", { filters })).error, /not a hiding rule/, JSON.stringify(filters));
  }
  assert.match((await call("hideElements", { filters: ["a.test##.fine", "a.test##div[[x"] })).error, /not a valid selector/);
  assert.equal(ublock.state.userFilters, before);
  assert.deepEqual(ublock.state.core, []);
});

test("restoring drops every trimmed line that matches, then saves and reloads; nothing to drop writes nothing", async () => {
  const { call, ublock } = load();
  assert.deepEqual(await call("restoreElements", { filters: ["news.example##div.banner", "gone.example##.x"] }), { ticket: 1, value: null });
  assert.equal(ublock.state.userFilters, "! my own notes\nexample.com##.ad\n||tracker.example^\nexample.com##+js(nowebrtc)\n");
  assert.equal(ublock.state.listLoads, 1);
  ublock.state.core.length = 0;
  assert.deepEqual((await call("restoreElements", { filters: ["gone.example##.x"] })).value, null);
  assert.deepEqual(ublock.state.core, ["loadUserFilters"]);
  assert.match((await call("restoreElements", { filters: "example.com##.ad" })).error, /no filters to restore/);
  assert.match((await call("restoreElements", { filters: [4] })).error, /no filters to restore/);
  assert.equal(ublock.state.listLoads, 1);
});

const MINE = "https://lists.example/mine.txt";

test("adding a list by address imports it, waits for the reload and answers its id, count and whether it downloaded", async () => {
  const { call, ublock } = load({ ublock: fakeUblock({ remote: { [MINE]: 42 } }) });
  assert.deepEqual(await call("addList", { url: MINE }), { ticket: 1, value: { id: MINE, custom: true, existed: false, filters: 42, failed: false } });
  assert.deepEqual(ublock.state.selections, [{ what: "applyFilterListSelection", toImport: MINE }]);
  assert.equal(ublock.state.reloads, 1);
  assert.equal(ublock.storage.rayReloadPending, undefined);
  const mine = (await call("state")).value.lists.find((l) => l.id === MINE);
  assert.deepEqual(mine, { id: MINE, title: MINE, group: "custom", enabled: true, defaultOn: false, filters: 42, failed: false });
  assert.deepEqual((await call("addList", { url: MINE })).value, { id: MINE, custom: true, existed: true, filters: 42, failed: false });
  const broken = "http://lists.example/gone.txt";
  assert.deepEqual((await call("addList", { url: broken })).value, { id: broken, custom: true, existed: false, filters: 0, failed: true });
  assert.equal((await call("state")).value.lists.find((l) => l.id === broken).failed, true);
});

test("adding the address of a stock list turns that list on and says whether it already was", async () => {
  const { call, ublock } = load();
  assert.deepEqual((await call("addList", { url: "http://secure.fanboy.co.nz/fanboy-cookiemonster.txt" })).value,
    { id: "fanboy-cookiemonster", custom: false, existed: false, filters: 9000, failed: false });
  assert.equal(ublock.state.available["fanboy-cookiemonster"].off, false);
  assert.deepEqual((await call("addList", { url: "https://easylist.to/easylist/easylist.txt" })).value,
    { id: "easylist", custom: false, existed: true, filters: 50000, failed: false });
});

test("adding refuses anything but an http or https address and writes nothing; a list uBlock turns down is an error", async () => {
  const { call, ublock } = load({ ublock: fakeUblock({ refused: [MINE] }) });
  for (const url of ["ftp://lists.example/a.txt", "https://", "https:///a.txt", "https://a.test/a b", "javascript:alert(1)", "//a.test/x", `https://a.test/${"x".repeat(2048)}`, 3, null, undefined]) {
    assert.match((await call("addList", { url })).error, /not a list address/, JSON.stringify(url));
  }
  assert.deepEqual(ublock.state.selections, []);
  assert.equal(ublock.state.reloads, 0);
  assert.equal((await call("addList", { url: MINE })).error, "uBlock Origin turned the list down");
});

test("adding answers before the call's deadline even while uBlock is still reloading", async () => {
  const { call } = load({ ublock: fakeUblock({ silent: ["reloadAllFilters"] }) });
  const started = Date.now();
  const reply = await call("addList", { url: MINE }, { deadlineMs: 1500 });
  assert.deepEqual(reply.value, { id: MINE, custom: true, existed: false, filters: 0, failed: false });
  assert.ok(Date.now() - started < 1500);
});

test("removing drops only a list added by address", async () => {
  const { call, ublock } = load({ ublock: fakeUblock({ remote: { [MINE]: 42 } }) });
  await call("addList", { url: MINE });
  ublock.state.selections.length = 0;
  assert.deepEqual(await call("removeList", { id: MINE }), { ticket: 2, value: null });
  assert.deepEqual(ublock.state.selections, [{ what: "applyFilterListSelection", toRemove: [MINE] }]);
  assert.equal(ublock.state.available[MINE], undefined);
  assert.equal(ublock.state.reloads, 2);
  for (const id of ["easylist", "user-filters", "nope", MINE, "__proto__", "constructor", 7]) {
    assert.equal((await call("removeList", { id })).error, `no added list ${id}`);
  }
  assert.equal(ublock.state.selections.length, 1);
});

test("settings name the lists added by address, and follow imports and removes them to match", async () => {
  const OTHER = "https://lists.example/other.txt";
  const remote = { [MINE]: 42, [OTHER]: 7 };
  const leader = load({ ublock: fakeUblock({ remote }) });
  await leader.call("addList", { url: OTHER });
  await leader.call("addList", { url: MINE });
  const { value: settings } = await leader.call("settings");
  assert.deepEqual(settings.imported, [MINE, OTHER]);
  assert.ok(settings.lists.includes(MINE) && settings.lists.includes(OTHER));
  const follower = load({ ublock: fakeUblock({ remote }) });
  assert.deepEqual((await follower.call("follow", settings)).value, null);
  assert.deepEqual((await follower.call("settings")).value, settings);
  assert.deepEqual(follower.ublock.state.selections[0], { what: "applyFilterListSelection", toImport: `${MINE}\n${OTHER}`, toRemove: [] });
  await leader.call("removeList", { id: OTHER });
  const { value: fewer } = await leader.call("settings");
  assert.deepEqual(fewer.imported, [MINE]);
  await follower.call("follow", fewer);
  assert.deepEqual((await follower.call("settings")).value, fewer);
  assert.equal(follower.ublock.state.available[OTHER], undefined);
  const before = follower.ublock.state.selections.length;
  await follower.call("follow", fewer);
  assert.equal(follower.ublock.state.selections.length, before);
  for (const bad of [{ ...fewer, imported: "x" }, { ...fewer, imported: [3] }]) {
    assert.match((await follower.call("follow", bad)).error, /no settings to copy/);
  }
});

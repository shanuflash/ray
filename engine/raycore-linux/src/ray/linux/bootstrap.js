(() => {
  "use strict";
  if (location.protocol !== "chrome:" || location.hostname !== "ray" || window !== window.top) return;
  if (typeof globalThis.chrome?.send !== "function" || window.__rayHost) return;

  const bootstrap = globalThis.__rayBootstrap ?? {};
  delete globalThis.__rayBootstrap;
  const pending = new Map();
  const listeners = new Set();
  const beforeClose = new Set();
  const prefix = crypto.randomUUID();
  let sequence = 0;
  let disposed = false;
  const interactive = new Map([
    ["RayPasswords.unlock", 180000],
    ["RayPasswords.reveal", 180000],
    ["RayPasswords.update", 180000],
    ["RayAutofill.cardNumber", 180000],
    ["RayPasswords.export", 900000],
    ["RaySync.createPhrase", 180000],
    ["RaySync.enterPhrase", 180000],
    ["RaySync.unlock", 180000],
    ["RaySync.forget", 180000],
    ["RaySync.status", 180000],
    ["RaySync.read", 120000],
    ["RaySync.write", 120000],
    ["RaySync.deleteChain", 120000],
    ["RaySync.recoveryWords", 180000],
    ["RaySync.qrCode", 180000],
    ["RaySync.copyRecoveryPhrase", 180000],
    ["RaySync.chooseFolder", 900000],
    ["RaySync.saveRecoveryKit", 900000],
    ["RayLive.request", 180000],
    ["RayLive.connect", 180000],
    ["RayLive.disconnect", 180000],
    ["RayCalendar.requestAccess", 120000],
    ["RayCalendar.sources", 60000],
    ["RayCalendar.objects", 120000],
    ["RayCli.install", 330000],
    ["RayShell.fetchBangList", 75000],
  ]);

  const request = (method, args, deadline = 30000) => {
    if (disposed) return Promise.reject(new Error("The browser UI has closed"));
    if (pending.size >= 256) return Promise.reject(new Error("Too many pending native requests"));
    return new Promise((resolve, reject) => {
      const id = `${prefix}:${++sequence}`;
      const timer = setTimeout(() => {
        if (!pending.delete(id)) return;
        reject(new Error(`Native request timed out: ${method}`));
      }, deadline);
      pending.set(id, { resolve, reject, timer });
      try {
        chrome.send("rayRequest", [id, method, args]);
      } catch (error) {
        pending.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
  };

  Object.defineProperty(window, "__rayReply", {
    value(id, success, result) {
      const entry = pending.get(id);
      if (!entry) return;
      pending.delete(id);
      clearTimeout(entry.timer);
      if (success) entry.resolve(result);
      else entry.reject(Object.assign(new Error(typeof result === "string" ? result : result?.message ?? "Native request failed"), {
        code: typeof result === "object" && result ? result.code ?? "ERR_ENGINE" : "ERR_ENGINE",
      }));
    },
  });

  Object.defineProperty(window, "__rayEvent", {
    value(module, event, payload) {
      if (disposed) return;
      for (const listener of [...listeners]) {
        try {
          listener(module, event, payload);
        } catch (error) {
          console.error("[ray host] event listener failed", error);
        }
      }
    },
  });

  Object.defineProperty(window, "__rayHost", {
    value: Object.freeze({
      bootstrap: Object.freeze(bootstrap),
      call(name, profile, args = null) {
        if (typeof name !== "string" || typeof profile !== "string" || (args !== null && typeof args !== "string")) {
          return Promise.reject(new TypeError("Invalid engine call"));
        }
        return request("engine.call", { name, profile, args });
      },
      invoke(method, args = {}) {
        if (typeof method !== "string" || !args || typeof args !== "object" || Array.isArray(args)) {
          return Promise.reject(new TypeError("Invalid host call"));
        }
        return request("host.invoke", { method, args }, interactive.get(method));
      },
      onEvent(listener) {
        if (typeof listener !== "function") throw new TypeError("Expected an event listener");
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      onBeforeClose(listener) {
        if (typeof listener !== "function") throw new TypeError("Expected a close listener");
        beforeClose.add(listener);
        return () => beforeClose.delete(listener);
      },
    }),
  });

  addEventListener("pagehide", () => {
    for (const listener of [...beforeClose]) {
      try {
        listener();
      } catch (error) {
        console.error("[ray host] close listener failed", error);
      }
    }
    disposed = true;
    for (const { reject, timer } of pending.values()) {
      clearTimeout(timer);
      reject(new Error("The browser UI has closed"));
    }
    pending.clear();
    listeners.clear();
    beforeClose.clear();
  }, { once: true });
})();

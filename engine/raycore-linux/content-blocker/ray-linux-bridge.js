"use strict";
(() => {
  const offDirective = "/^(?:ray-blocking-off|)/";
  const root = document.documentElement;
  const requestAttribute = "data-ray-request";
  const replyAttribute = "data-ray-reply";

  const contextLost = () => {
    try {
      return !chrome.runtime || !chrome.runtime.id;
    } catch {
      return true;
    }
  };

  const withDeadline = (promise, what, left) =>
    new Promise((resolve, reject) => {
      const stop = () => {
        clearTimeout(timer);
        clearInterval(watch);
      };
      const timer = setTimeout(() => {
        stop();
        reject(new Error(`${what}: timed out`));
      }, Math.max(0, left()));
      const watch = setInterval(() => {
        if (!contextLost()) return;
        stop();
        reject(new Error("Extension context invalidated."));
      }, 50);
      promise.then(
        (value) => {
          stop();
          resolve(value);
        },
        (error) => {
          stop();
          reject(error);
        },
      );
    });

  const session = (deadlineMs, failNext) => {
    const deadline = Date.now() + deadlineMs;
    const left = () => Math.max(0, deadline - Date.now());
    let failing = failNext === true;
    const expired = () => left() === 0;

    const ready = () =>
      new Promise((resolve, reject) => {
        const look = () => {
          try {
            const background = chrome.extension.getBackgroundPage && chrome.extension.getBackgroundPage();
            const ublock = background && background["µBlock"];
            if (ublock && ublock.isReadyPromise) return ublock.isReadyPromise.then(resolve, reject);
            if (expired()) return reject(new Error("uBlock Origin never started"));
            setTimeout(look, 10);
          } catch (error) {
            reject(error);
          }
        };
        look();
      });

    const send = (message) => {
      if (expired()) return Promise.reject(new Error(`${message.what}: timed out`));
      if (failing) {
        failing = false;
        return Promise.reject(new Error(`${message.what}: failed (dev)`));
      }
      if (!self.vAPI || !self.vAPI.messaging) return Promise.reject(new Error(`${message.what}: no reply`));
      return self.vAPI.messaging.send("dashboard", message).then((reply) => {
        if (reply === undefined) throw new Error(`${message.what}: no reply`);
        return reply;
      });
    };

    const trusted = () =>
      send({ what: "getWhitelist" }).then((t) => {
        if (!t || !Array.isArray(t.whitelist)) throw new Error("getWhitelist: no answer");
        return t;
      });

    const lists = () =>
      send({ what: "getLists" }).then((l) => {
        if (!l || !l.available || typeof l.available !== "object") throw new Error("getLists: no answer");
        return l;
      });

    const selected = (l) => Object.keys(l.available).filter((k) => l.available[k] && l.available[k].off !== true);
    const imported = (l) => Object.keys(l.available).filter((k) => l.available[k] && l.available[k].group === "custom").sort();
    const owns = (l, id) => Object.prototype.hasOwnProperty.call(l.available, id) && !!l.available[id];
    const failedToLoad = (l, id) =>
      !!(l.cache && Object.prototype.hasOwnProperty.call(l.cache, id) && l.cache[id] && l.cache[id].error !== undefined);
    const covers = (directive, host) => !directive.includes("/") && (host === directive || host.endsWith("." + directive));

    const storageCall = (name, arg) =>
      expired()
        ? Promise.reject(new Error(`storage ${name}: timed out`))
        : new Promise((resolve, reject) =>
            chrome.storage.local[name](arg, (value) =>
              chrome.runtime.lastError ? reject(new Error(chrome.runtime.lastError.message)) : resolve(value || {}),
            ),
          );
    const local = {
      get: (key) => storageCall("get", key),
      set: (value) => storageCall("set", value),
      remove: (key) => storageCall("remove", key),
    };
    const reloadLists = () => send({ what: "reloadAllFilters" }).then(() => local.remove("rayReloadPending"));
    const reloadWait = () => new Promise((resolve) => setTimeout(resolve, Math.max(0, left() - 1000)));
    const applySelection = (details) =>
      local.set({ rayReloadPending: true }).then(() => send({ what: "applyFilterListSelection", ...details }));
    const applyLists = (toSelect) => applySelection({ toSelect }).then(reloadLists);
    const settlePending = () => local.get("rayReloadPending").then((b) => (b.rayReloadPending ? reloadLists() : null));

    const state = () =>
      Promise.all([lists(), trusted(), fetch("/assets/assets.json").then((r) => r.json())]).then(([l, t, assets]) => {
        const languages = new Set(
          [chrome.i18n.getUILanguage(), ...(navigator.languages || [])].map((x) => (/^[a-z]+/.exec(x) || [])[0]).filter(Boolean),
        );
        const forLanguages = (lang) => typeof lang === "string" && lang.split(/\s+/).some((x) => languages.has(x));
        const onByDefault = (id) => !!assets[id] && (assets[id].off !== true || forLanguages(assets[id].lang));
        return {
          lists: Object.entries(l.available)
            .filter(([, list]) => list && list.content === "filters" && list.group !== "user")
            .map(([id, list]) => ({
              id,
              title: list.title || id,
              group: list.group || "",
              enabled: list.off !== true,
              defaultOn: list.group !== "custom" && onByDefault(id),
              filters: list.entryCount || 0,
              failed: failedToLoad(l, id),
            })),
          networkFilters: l.netFilterCount || 0,
          cosmeticFilters: l.cosmeticFilterCount || 0,
          enabled: !t.whitelist.includes(offDirective),
          allowedHosts: t.whitelist.filter(
            (d) => !d.includes("/") && !d.startsWith("#") && !(t.whitelistDefault || []).includes(d),
          ),
        };
      });

    const setEnabled = ({ enabled }) =>
      trusted()
        .then((t) => {
          const kept = t.whitelist.filter((d) => d !== offDirective);
          return send({ what: "setWhitelist", whitelist: (enabled ? kept : kept.concat([offDirective])).join("\n") });
        })
        .then(() => send({ what: "userSettings", name: "autoUpdate", value: enabled === true }))
        .then(() => null);

    const setList = ({ id, enabled }) =>
      lists().then((l) => {
        if (!owns(l, id)) throw new Error(`no list ${id}`);
        const keep = selected(l).filter((x) => x !== id);
        return applyLists(enabled ? keep.concat([id]) : keep).then(() => null);
      });

    const listAddress = /^https?:\/\/[^\s\/]+\S*$/i;

    const addList = ({ url }) =>
      Promise.resolve()
        .then(() => {
          if (typeof url !== "string" || url.length > 2048 || !listAddress.test(url)) throw new Error("not a list address");
          return lists();
        })
        .then((before) => {
          const needle = url.replace(/^https?:/i, "");
          const findId = (l) =>
            owns(l, url)
              ? url
              : Object.keys(l.available).find((k) =>
                  [].concat((l.available[k] && l.available[k].contentURL) || []).some((u) => typeof u === "string" && u.endsWith(needle)),
                );
          const had = findId(before);
          return applySelection({ toImport: url })
            .then(() => Promise.race([reloadLists(), reloadWait()]))
            .then(lists)
            .then((l) => {
              const id = findId(l);
              if (!id) throw new Error("uBlock Origin turned the list down");
              const entry = l.available[id];
              return {
                id,
                custom: entry.group === "custom",
                existed: !!had && before.available[had].off !== true,
                filters: entry.entryCount || 0,
                failed: failedToLoad(l, id),
              };
            });
        });

    const removeList = ({ id }) =>
      lists().then((l) => {
        if (typeof id !== "string" || !owns(l, id) || l.available[id].group !== "custom") throw new Error(`no added list ${id}`);
        return applySelection({ toRemove: [id] })
          .then(reloadLists)
          .then(() => null);
      });

    const isAllowed = ({ host }) => trusted().then((t) => t.whitelist.some((d) => covers(d, host)));

    const setAllowed = ({ host, allowed }) =>
      trusted().then((t) => {
        const kept = t.whitelist.filter((d) => (allowed ? d !== host : !covers(d, host)));
        return send({ what: "setWhitelist", whitelist: (allowed ? kept.concat([host]) : kept).join("\n") }).then(() => null);
      });

    const sameSet = (a, b) => a.length === b.length && a.every((x) => b.includes(x));
    const strings = (value) => Array.isArray(value) && value.every((x) => typeof x === "string");

    const settings = () =>
      Promise.all([lists(), trusted()]).then(([l, t]) => ({
        lists: selected(l).sort(),
        imported: imported(l),
        whitelist: [...t.whitelist].sort(),
        autoUpdate: l.autoUpdate !== false,
      }));

    const follow = (want) =>
      Promise.all([lists(), trusted()]).then(([l, t]) => {
        if (!strings(want.lists) || !strings(want.whitelist) || typeof want.autoUpdate !== "boolean")
          throw new Error("no settings to copy");
        if (want.imported !== undefined && !strings(want.imported)) throw new Error("no settings to copy");
        const mine = imported(l);
        const wanted = want.imported === undefined ? mine : want.imported;
        const toImport = wanted.filter((u) => !mine.includes(u));
        const toRemove = mine.filter((u) => !wanted.includes(u));
        const importsDiffer = toImport.length > 0 || toRemove.length > 0;
        let written = Promise.resolve(null);
        if (importsDiffer)
          written = written.then(() => send({ what: "applyFilterListSelection", toImport: toImport.join("\n"), toRemove }));
        if (importsDiffer || !sameSet(selected(l), want.lists)) written = written.then(() => applyLists(want.lists));
        if (!sameSet(t.whitelist, want.whitelist))
          written = written.then(() => send({ what: "setWhitelist", whitelist: want.whitelist.join("\n") }));
        if ((l.autoUpdate !== false) !== want.autoUpdate)
          written = written.then(() => send({ what: "userSettings", name: "autoUpdate", value: want.autoUpdate }));
        return written.then(() => null);
      });

    const hidingRule = /^[a-z0-9.-]+##[^+^\s][^\n{}]*$/;
    const lines = (content) => content.split("\n").map((l) => l.trim());
    const core = () => {
      const background = chrome.extension.getBackgroundPage && chrome.extension.getBackgroundPage();
      const ublock = background && background["µBlock"];
      if (!ublock) throw new Error("uBlock Origin never started");
      return ublock;
    };
    const userFilters = () =>
      Promise.resolve()
        .then(() => core().loadUserFilters())
        .then((d) => {
          if (!d || d.error || typeof d.content !== "string") throw new Error(`user filters: ${(d && d.error) || "unreadable"}`);
          return d.content;
        });

    const hiddenElements = () => userFilters().then((content) => lines(content).filter((l) => hidingRule.test(l)));

    const hideElements = ({ filters }) =>
      Promise.resolve()
        .then(() => {
          if (!strings(filters)) throw new Error("not a hiding rule");
          for (const f of filters) {
            if (f.length > 1024 || !hidingRule.test(f)) throw new Error("not a hiding rule");
            document.createDocumentFragment().querySelector(f.slice(f.indexOf("##") + 2));
          }
          return userFilters();
        })
        .then((content) => {
          const have = new Set(lines(content));
          const fresh = [...new Set(filters)].filter((f) => !have.has(f));
          const ublock = core();
          if (!ublock.selectedFilterLists.includes(ublock.userFiltersPath))
            ublock.applyFilterListSelection({ toSelect: [ublock.userFiltersPath], merge: true });
          return fresh.length ? ublock.appendUserFilters(fresh.join("\n"), {}) : null;
        })
        .then(() => null);

    const restoreElements = ({ filters }) => {
      if (!strings(filters)) return Promise.reject(new Error("no filters to restore"));
      const drop = new Set(filters);
      return userFilters()
        .then((content) => {
          const all = content.split("\n");
          const kept = all.filter((l) => !drop.has(l.trim()));
          if (kept.length === all.length) return null;
          const ublock = core();
          return ublock.saveUserFilters(kept.join("\n")).then(() => ublock.loadFilterLists());
        })
        .then(() => null);
    };

    const operations = {
      state,
      setEnabled,
      setList,
      isAllowed,
      setAllowed,
      settings,
      follow,
      addList,
      removeList,
      hiddenElements,
      hideElements,
      restoreElements,
    };
    return { ready, settlePending, operations, left };
  };

  const answer = (ticket, body) => root.setAttribute(replyAttribute, JSON.stringify({ ticket, ...body }));

  const run = (request) => {
    const { ticket, op, args, deadlineMs, failNext } = request;
    if (!Number.isInteger(ticket)) return;
    const s = session(Number.isFinite(deadlineMs) ? deadlineMs : 0, failNext);
    const operation = Object.prototype.hasOwnProperty.call(s.operations, op) ? s.operations[op] : null;
    if (!operation) return answer(ticket, { error: `unknown operation ${String(op)}` });
    Promise.resolve()
      .then(() => {
        if (location.origin !== `chrome-extension://${chrome.runtime.id}`) throw new Error(`not the extension page: ${location.href}`);
      })
      .then(() => withDeadline(s.ready(), "uBlock Origin", s.left))
      .then(() => withDeadline(s.settlePending().then(() => operation(args && typeof args === "object" ? args : {})), "the call", s.left))
      .then(
        (value) => answer(ticket, { value: value === undefined ? null : value }),
        (error) => answer(ticket, { error: String((error && error.message) || error) }),
      );
  };

  const take = () => {
    const raw = root.getAttribute(requestAttribute);
    if (raw === null) return;
    root.removeAttribute(requestAttribute);
    let request;
    try {
      request = JSON.parse(raw);
    } catch {
      return;
    }
    if (request && typeof request === "object") run(request);
  };

  if (navigator.locks) navigator.locks.request("ray-linux-bridge", { mode: "shared" }, () => new Promise(() => {}));
  new MutationObserver(take).observe(root, { attributes: true, attributeFilter: [requestAttribute] });
  root.setAttribute("data-ray-bridge", "ready");
})();

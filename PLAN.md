# Plan: native macOS Arc-style browser on Ardia's engine

Goal: a macOS-only, Chromium-only browser with Arc's sidebar, pinned tabs and pinned tiles, at Arc's level of
smoothness, and as fast as Chrome or better. UI: native AppKit + Core Animation. No React Native, no SwiftUI on hot
paths, no WebKit, no Gecko, no Electron.

Name: **Ray** (decided 2026-10-27, section 11), but see the open decision below about how searchable it is.

Source for everything referenced: github.com/mantrakp04/ardia at `main`, 2026-10-27 (v0.2.41, Chromium
156.0.8078.47, Helium 0.20.1).

## Goal and roadmap

Read this first, every run. Every decision, design or code, should serve the end goal; when a choice doesn't, say
so.

**End goal:** Ray becomes the most Arc-feeling browser on real, de-Googled Chromium for Mac, and a popular
open-source project (users and GitHub stars). Arc shuts down on **2026-12-22**, and that migration is our launch
window. Every decision serves three things:
- **Arc's feel:** native AppKit + Core Animation, motion fitted to Arc, and performance gates on every release
  (section 9 targets, measured, never regressing silently).
- **Real Chromium with working extensions:** Chrome Web Store extensions behave as they do in Chrome.
- **Painless switching from Arc:** your Arc setup comes over in one go, and Arc's shortcuts work.

**Roadmap, in order:**
1. **Phase B engine** (section 6): our own build, the rename map, a "Ray Safe Storage" keychain item, and migrating
   mock-keychain data (decrypt with the known mock key, re-encrypt under the real one). Keep our own patches few,
   small and in separate files from Ardia's, so following Ardia's Chromium bumps stays cheap.
2. **Spaces.**
3. **Full Arc import:** Spaces, pinned tabs, folders, cookies.
4. **Distribution:** Developer ID signing, a notarized DMG, Sparkle updates, a Homebrew cask.
5. **Launch prep:** a README that opens with a short motion video/GIF, a one-line pitch and the install command; a
   side-by-side video with Arc; CONTRIBUTING and good-first-issue labels; regular tagged releases with readable
   notes.
6. **Launch week around 2026-12-22.** The owner posts; Claude prepares the drafts, the demo build and answers to
   likely questions.
7. **After launch:** quick issue triage, and periodic performance comparisons against Zen, Crest and Chrome.

Claude never posts anything publicly or creates accounts; the owner does.

## Open decisions (owner)

Recorded for the owner to decide. Don't act on them until they do.

| Topic | Question |
|---|---|
| Name | "Ray" is hard to search: it collides with ray-project/ray, Raycast and Spatie Ray. Keep it, or rename before launch? |

## Decisions so far

| Topic | Decision |
|---|---|
| Platform | macOS 14 Sonoma or later, Apple Silicon only |
| Spaces | Arc-style: many Spaces per Profile |
| Distribution | Personal use on Ardia's prebuilt engine first; Phase B only when shipping publicly or an engine change is needed |
| Engine | Ardia's engine. **Phase A:** Ardia's prebuilt, unchanged. **Phase B:** our own renamed build from source |
| UI | AppKit + Core Animation; SwiftUI only for Settings |
| Peek | **No** |
| DRM sites → WebKit | **No.** Chromium only; Netflix-type sites won't play (no Widevine) |
| Content blocker | **None built in.** The user installs uBlock Origin Lite from the Web Store (Basic mode is cheapest) |
| Page script | **Our own, minimal.** No Peek, DRM or performance messages |
| Launch flags | Required + recommended set (section 4); `--no-memory-reducer` decided by measurement |
| Who builds it | Claude (Opus 5.5, high) orchestrating subagents; owner directs and dogfoods (section 8) |

---

## 1. Architecture

```
┌────────────────────────────────────────────────────────────┐
│ Nova.app: Swift + AppKit + Core Animation          NEW     │
│   Sidebar · Favorites grid · Pinned/Today · Spaces         │
│   Command bar · prompts/bubbles · Settings · SQLite store  │
├────────────────────────────────────────────────────────────┤
│ Host layer (ObjC++)                       PORTED           │
│   TabContentView, tab registry, tab parking, swipe, PiP,   │
│   favicons, downloads, notifications, launch               │
├────────────────────────────────────────────────────────────┤
│ ArdiaCore public API (plain ObjC, ArdiaCore.h)  AS IS (A)  │
├────────────────────────────────────────────────────────────┤
│ Chromium Framework.framework              PREBUILT (A)     │
│   Chromium 156 + Helium + Ardia's patches + //ardia/core   │
└────────────────────────────────────────────────────────────┘
```

What we take from Ardia:

| Ardia path | Action |
|---|---|
| `engine/` | **Phase A:** keep byte-identical to an Ardia release tag so `fetch-engine.sh` finds the prebuilt. **Phase B:** fork and rename (section 6). |
| `packages/ardiacore/ios/` (host layer, 139 files) | **Keep and port:** `ArdiaHost*`, `ArdiaHostEngineDelegate`, `ArdiaEngineBridge`, `ArdiaStartup`, `ArdiaLaunchConfig`, `ArdiaTabRegistry`, `ArdiaTabParking`, `ArdiaLaunchTabHolder`, `ArdiaSwipe*`, `ArdiaPiP*` / `ArdiaPictureInPicture*`, `ArdiaFavicons`, `ArdiaNavigationDownloads`, `ArdiaNotifications`, `ArdiaProfiles`, `ArdiaPopupWindow`, `ArdiaChromeWindowHost`, `ArdiaReservedKeys`, `ArdiaFullScreen*`. **Rewrite** `ArdiaWebView*.mm` (a React Native view) as a plain `NSView` `TabContentView`, without its `+Peek` category. **Drop:** every `*Module.swift` (Expo bridges to JS), `ArdiaContentBlocker*` and `ContentBlockerModule.swift` (no built-in blocker), `WebKitModule.swift`, `WebKitWebView.swift`, `WebKitPageScript.swift` (no WebKit), `ArdiaPixelGridModule.mm`, `ArdiaFieldTiming*` (Ardia's measurements). |
| `packages/ardiacore/ios/page_script.js` | **Replace** with our own (section 5). |
| `packages/ardiacore/scripts/fetch-engine.sh`, `prebuilt-engines.tsv` | **Keep** (Phase A engine download + SHA-256 check). |
| Spike host `spikes/ardiacore-host/main.mm` at commit `00951870` | **Reference for M1**: Ardia's first plain-AppKit host app, before React Native. Older API; update calls. |
| `packages/import/ios` | **Keep** for M4 (Arc/Chrome/Safari import). |
| `packages/sync/ios` | Later (iCloud Drive E2E sync). |
| `packages/core` (TS omnibox parsing, suggestions) | **Port to Swift** what the command bar needs. |
| `apps/browser/src` (React Native UI) | **Drop.** Read as a behaviour spec only. |
| `packages/ardiacore/scripts/acceptance.mjs` (126 checks) | **Port a subset** to our CDP harness. |
| `apps/browser/scripts/perf/xbench.mjs`, `finch-ab.mjs` | **Keep** as the perf gate and the flag A/B tool. |
| `AGENTS.md`, `scripts/agent/*` (build lock, quiet builds, `await`) | **Adapt** for our Claude workflow (section 8). |

Licence: Ardia's own files are Apache-2.0 (keep notices). The engine is GPL-3.0 (Helium), so the shipped app is
GPL-3.0; publish source per release.

---

## 2. UI design rules (where the smoothness comes from)

1. **AppKit + Core Animation on hot paths.** No SwiftUI in the sidebar, tab rows or window chrome.
2. **Animations run in the render server:** `CASpringAnimation` / `CABasicAnimation` on layer `position`,
   `transform`, `opacity`. Never step animations from a main-thread timer.
3. **Hover peek of the hidden sidebar = overlay.** It slides over a page that doesn't resize.
4. **Docked hide/show = relayout per frame**, page trails 1–2 frames. Reference: Dia hide spring response 0.215 s,
   damping 0.79; Arc dock 100 ms ease-out cubic.
5. **Tab switch never waits on the store.** Click → `activateTab` → page shown natively in the same runloop turn;
   the store updates after. Keep the display-link prewarm on sidebar mouse-down (`wakeFrames`).
6. **One owner per piece of state.** The engine owns live tabs; the store owns the sidebar model and refers to
   live tabs by id.
7. **Measure at 120 Hz** (8.33 ms per frame). Motion changes are recorded and stepped frame by frame.

---

## 3. Sidebar data model

```
Profile (Chrome profile: cookies, logins, extensions)
 └─ Space (name, theme, icon; several Spaces may share a Profile)
     ├─ Pinned: tree of PinnedItem | Folder
     └─ Today: [TabRef]   (auto-archive after N hours idle → Archive)
Favorites (per Profile, shown in every Space of that Profile): [FavoriteItem]

FavoriteItem / PinnedItem { id, pinnedURL, title, iconRef, liveTabId?, lastURL }
```

- **Close a pinned item or favourite:** park/discard the engine tab, keep the row; click restores or reloads.
- **Back to pinned URL:** shown when `lastURL`'s host differs from `pinnedURL`'s.
- **Spaces:** default Arc-style (many per Profile). Switching to a Space on another Profile swaps the engine
  `Browser` (view swap).
- **Persistence:** SQLite (GRDB), write-behind on a background queue.
- **Session restore is ours:** Ardia's engine keeps hosted Browsers out of Chrome's `SessionService`.

Views: Favorites = custom layer-backed grid; Pinned/Today = `NSCollectionView` + diffable data source (switch to
custom layer-backed rows if frame recordings show it can't match Arc); sidebar = docked container or floating
overlay container moved by a spring on its layer.

---

## 4. Launch flags

Passed by our host (port of `ArdiaHost+Launch.mm`).

**Required:** `--user-data-dir=<dir>`, `--profile-directory=Default`, `WebContentsDiscard` (the engine adds it too;
pinned-tab parking needs it).

**Keep:**
- `--disable-features=AutofillAiWalletPrivatePasses,MacAppCodeSignClone,DevToolsAcceptDebuggingConnections`
- `--disable-stack-profiler`

**Recommended (power and launch):**
- `ThrottleMainFrameTo60Hz`, `UrgentMainFrameForInput`
- `InfiniteTabsFreezing:ardia_unconnected_unfreeze_interval/600s`,
  `CPUMeasurementInFreezingPolicy:freezing_visible_protection_time/0s`
- `ImprovedStartupBestEffortDelay:StartupDelayStopOnLoadingTimedOut/true`

**Preference:** `--enable-smooth-scrolling`, `BrowserInitiatedAutomaticPictureInPicture`.

**Measure before deciding:** `--js-flags=--no-memory-reducer` (likely more memory per tab), and Chrome's Finch
defaults vs ours (`finch-ab.mjs`).

**Test runs only:** `--mute-audio`, `--use-fake-device-for-media-stream`, `--use-mock-keychain`,
`--remote-debugging-port`, `--disable-modal-animations`.

---

## 5. Page script

Handed to the engine at launch (`engine.pageScript`); runs in every http(s) and file frame. Ours:

```js
(() => {
  if (window !== window.top) return;
  main();
  function main() { /* main-frame code only */ }
})();
```

Iframes only reach the first check; `main`'s body compiles only in top frames.

| Message | Keep | Notes |
|---|---|---|
| `hello` | Yes | Tells the host the page channel is ready |
| `theme` | M2+ | Page colour, if we tint the sidebar per page. Observe only `meta[name=theme-color]`, not the whole `<head>` |
| `notification`, `notificationClose` | Decide in M3 | First test Chrome's own macOS notification path without the script |
| `scroll` | Only with toolbar auto-hide | — |
| `linkDrop` | Optional | Drag a link to the sidebar |
| `nowPlaying` | Probably not | Use Chrome's native audible state and Media Session first |
| `pinch`, `selection`, `displayMedia` | No (revisit if a feature needs one) | — |
| `peek*` | **No** | No Peek |
| `drm` | **No** | No WebKit routing |
| `firstPaint`, `paint`, `perf`, `pipTrace`, `peekTrace` | **No** | Ardia's measurements; `xbench.mjs` measures from outside |

---

## 6. Engine phases

**Phase A (M0–M3): Ardia's prebuilt, no Chromium source.**
- `engine/` byte-identical to an Ardia release tag; `fetch-engine.sh` downloads `ArdiaCore-<tree>.tar.xz`
  (~110 MB) from Ardia's GitHub releases and checks its SHA-256. Mirror every tarball we use.
- Fixed in the binary: bundle id `com.ardia.browser`, Ardia's team id (passkeys and saved cards won't work under
  our signing), "Ardia" on chrome:// pages, credits and crash product, the "Ardia Safe Storage" keychain item.
- No engine changes. Chromium security fixes arrive when Ardia ships an engine; our host layer moves to that tag.
- Unused engine pieces (Peek's temporary-tab hook, content-blocker navigation hold) stay in the binary, idle.

**Phase B (M4, or sooner if we need an engine change): own build.**
- Hardware: Apple Silicon; about 45 GB of disk for the source and build (`~/chromium-build` on the internal disk, no
  external SSD). Build steps from Ardia's `docs/engine-build.md` (1 sync, 3 Helium, 4 series, 2 gn args, 5 build),
  under the `chromium` lock (`scripts/locked`). Never clean the build cache: incremental builds depend on it.
- Scripted rename map, `tools/engine/sync-engine.sh <ardia checkout>`: `rename-ardia.py` writes `engine/` from
  Ardia's (`ArdiaCore`→`RayCore`, `//ardia/core`→`//ray/core`, `chrome/browser/ray`, `g_ray_`, `ray_namesub.py`,
  bundle id `dev.shanus.ray`, keychain item "Ray Safe Storage", links; `ac_` calls keep their names), then
  `apply-ray.py` applies Ray's own changes from `engine-ray/`. Never edit `engine/` by hand; a later Ardia commit is
  run through the same script and the diff cherry-picked.
- Patch review (`engine-ray/drop-patches.txt`): dropped `chromium-temporary-tab-restore-hook` (Peek),
  `chromium-devtools-control-token` (Ardia CLI; the harness doesn't use it) and `chromium-neterror-game`. Still
  in: the content-blocker navigation hold (idle: Ray loads no blocker). Kept the hosting, de-Googling, Web Store
  and power patches. Decide the rest one by one.
- Keychain: the real app leaves the mock keychain. On its first launch, `Host/SafeStorage.swift` makes
  "Ray Safe Storage", re-encrypts the profile's databases from the mock key to it (originals kept a week in
  `Safe Storage Migration/backup`) and only then starts the engine. Test builds stay on the mock keychain; the
  `safe-storage-migration` check runs the real path against the engine's file keychain. Until Ray is signed with a
  stable identity (Developer ID, or at least one self-signed certificate), macOS asks for the keychain once after
  each update, because an ad-hoc signature changes every build.
- Chromium bump every 4 weeks (or follow Ardia's bumps via the rename map).

---

## 7. Milestones

### M0: Repo + prebuilt engine (week 1)
- New repo; `engine/` at Ardia tag `v0.2.41`; `fetch-engine.sh`; the host-layer files from section 1.
- `CLAUDE.md` with the agent rules (section 8) and `scripts/agent/*`.
- Apple Developer account and signing identity (owner).
- **Exit:** a minimal AppKit app links `Chromium Framework.framework`, boots the engine and shows one page.

### M1: Native host skeleton (weeks 2–4)
- Port the host layer; `TabContentView` (focus, input monitors, painting, navigation, page messages).
- Engine boot owns the main loop; one window, one profile; open/close/activate tabs; popups and `target=_blank` as
  our tabs; basic address field; main menu and shortcuts; launch flags (section 4); our page script (`hello` only).
- CDP harness with ~30 checks ported from `acceptance.mjs`. Baseline with `xbench.mjs` vs Chrome and Helium.
- **Exit:** everyday browsing of simple sites; native tab switch; clean quit.

### M2: The Arc sidebar (weeks 5–8)
- Store + SQLite; Favorites grid; Pinned tree with folders; Today list; Archive; Spaces with swipe.
- ⌘S docked hide/show, edge-hover overlay peek, mini window (Little Arc).
- Drag and drop between tabs, pinned and favourites; session restore.
- **Exit:** 0 dropped sidebar frames at 120 Hz in toggle and peek; sidebar click → page shown ≤ 10 ms median.

### M3: Browser essentials (weeks 9–12)
- Command bar (⌘L/⌘T) with a Swift port of the needed `packages/core` parts.
- UI for what the engine asks the host to show: find bar, permission prompts, external-app prompt, password save,
  extension toolbar + action popups + install prompt, downloads, context menus, fullscreen, docked DevTools,
  private windows, Settings.
- Flag A/B (`--no-memory-reducer`, Finch defaults). Notifications decision.
- Harness to ~60 checks.
- **Exit:** replaces Chrome for a working day, uBlock Origin Lite installed from the Web Store.

### M4: Ship (weeks 13–16)
- Phase B engine build (section 6) or, if staying on the prebuilt for personal use, skip it.
- Developer ID signing, notarization, DMG, Sparkle auto-updates.
- Arc import (`packages/import`): Arc stops working on 2026-12-22. Favorites, pinned tabs and folders are done
  (File › Import from Arc…, 2026-10-28).
- **Arc cookie import waits for Phase B (decided 2026-10-28):** it needs Arc's "Arc Safe Storage" keychain key, and
  the sessions it brings in must be stored under Ray's own "Ray Safe Storage" item, not the prebuilt engine's mock
  keychain, where they'd sit on disk effectively unencrypted.
- **Exit:** a notarized DMG that installs, updates itself and imports an Arc profile.

### M5: Ongoing
- Engine updates every 4 weeks (Phase A: move to Ardia's next engine tag; Phase B: our own bump).
- Perf gate each release with `xbench.mjs`: no regression vs our previous release, interleaved runs.
- Later: iCloud sync, themes, cast dialog, device choosers, screen-capture picker.

**Estimate, Claude-driven at Ardia's intensity: daily driver in about 2–3 months; with one person doing most of
it by hand, 4–5.**

---

## 8. Running it with Claude

Modelled on Ardia's `AGENTS.md` (286 of its last 300 commits are co-authored by Claude Opus 5.5).

- **Orchestrator + subagents:** one main session plans and verifies; Opus subagents implement, one area each, with
  their own files, build folder and throwaway data dir.
- **Ground truth for agents:** the CDP harness, `xbench.mjs`, and a 120 Hz frame-timing rig for sidebar motion.
  An agent's work is done when those pass, not when it compiles.
- **Hard rules in `CLAUDE.md`:** hidden test instances only (`open -g -n`, never steal focus); never touch the
  owner's installed apps or real browser profiles; every wait has a deadline; in Phase B, Chromium builds take a
  lock and the build cache is never cleaned.
- **Second opinion** on risky native code (lifetimes, races, quit, security): a separate review agent before
  and after the change.
- **Owner's part:** name and open decisions, Apple account and signing, daily dogfooding with screen recordings,
  final "does it feel like Arc" calls, release approval.
- **Cost:** heavy Opus usage for weeks; budget for it.

---

## 9. Performance targets

Targets, measured with `xbench.mjs` against Chrome, Helium and our previous release.

| Metric | Target | Reference (Ardia 0.2.37 / Chrome 155) |
|---|---|---|
| Sidebar click → page shown | ≤ 10 ms median | Ardia 5 ms with prewarm |
| Sidebar toggle / peek | 0 dropped frames at 120 Hz | — |
| Browser process memory, 1 tab | ≤ 95 MB | Ardia 125 (React Native), Helium 76 |
| Renderer memory per tab | ≤ 30 MB with uBO Lite in Basic | Ardia ~41, Chrome 24 |
| Idle wakeups, browser process | ≤ 2/s | Ardia 3.3, Chrome 2.1 |
| Cold launch → window on screen | ≤ 360 ms | Ardia 358, Chrome 424 |

---

## 10. Risks

1. **Hidden coupling to Ardia's app** in the engine (early window, launch tab holder, hidden windows). Found while
   porting checks; fixed in the host layer where possible.
2. **One compositor per tab** (inherited): 1–2 refreshes on first show; prewarm hides it on clicks, keyboard switches
   pay ~8 ms. A real fix needs Phase B.
3. **Upstream pace:** Ardia has one maintainer. If it stalls, Phase B becomes urgent.
4. **Prebuilt limits:** Ardia branding inside, no passkeys/saved cards, no engine fixes of our own. The engine's
   keychain item is "Ardia Safe Storage", which is the real Ardia's; Ray runs with `--use-mock-keychain` until
   Phase B, so its saved passwords and cookies are encrypted with a fixed, public key. Don't keep real passwords
   in Ray before Phase B.
   Friends' builds run on mock keychain (user's decision, 2026-10-28); when Ray has its own engine and keychain
   item, an update migrates their data by decrypting with the known mock key and re-encrypting under the real one.
5. **No Widevine:** streaming sites with DRM won't play.
6. **Build hardware** for Phase B.

---

## 11. Decided 2026-10-27

Name **Ray** (bundle id `dev.shanus.ray` until changed), Arc-style Spaces, macOS 14 minimum, prebuilt engine
for personal use first. "Nova" / `NovaCore` above means Ray / `RayCore`.

---

## 12. Upstream notes (carry into our port)

**Ardia v0.2.42-nightly.1** (2026-10-27): engine unchanged (tree `529394c5`, same as our pin), so no engine bump.
Lessons for code we haven't written yet:
- **Trust the engine's origin, never the page's.** `tab:didReceivePageMessage:…origin:` gives a verified origin;
  Ardia stopped using the URL a page reports in its `hello` (M1, page channel).
- **Picture in picture state comes from the engine** (`tab:didChangePictureInPicture:`), not from a page message, so
  a page can't fake or take over another tab's PiP (M1).
- **Show a web notification only if the site's notification permission is `allow`**; otherwise close it (M3).
- **Permission prompts ignore clicks for their first 0.5 s and show the full origin** (M3).
- **Address field:** never run `javascript:` typed or pasted; elide long hosts from the start; hide
  `user:pass@`; always show the port (M1/M3).
- **Insecure downloads wait for Keep / Discard** instead of finishing (M3).
- **Tab sleeping:** keep the 4 most recently used background tabs loaded, sleep others after 20 min, other
  profiles' tabs first; never sleep tabs that play, record, sit in a split or hold unsaved text (M2, with parking).
- **Fullscreen:** the window slides under the menu bar with no grey bar (`ArdiaFullScreenReveal.mm`, new) (M3).
- Not for us: the drag-freeze fix (`RCTTouchHandler+Pages.mm`) was a React Native touch-handler bug.
- Later: Dia open/pinned tab import in `packages/import` (M4).

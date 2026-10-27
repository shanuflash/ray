# Lumen

A macOS (14+, Apple Silicon) Chromium browser with Arc's sidebar, pinned tabs and pinned tiles. Native AppKit +
Core Animation UI on Ardia's engine. `PLAN.md` is the plan and the source of truth for decisions.

## Layout
- `Host/`: the native app in Swift + AppKit. `Bridging.h` exposes the engine API. `BrowserWindowController` owns a
  window's tabs; `SidebarView` is the address field and tab list; `PageContainerView` shows one page at a time
  (others stay attached but hidden, with `noteShown(byHost:)`); `MainMenu` + `Shortcuts` do key routing.
- `CommandBarView` + `Suggestions`: the Arc-style command bar (⌘T new tab, ⌘L / clicking the sidebar address =
  current tab). Rows: autocompleted host match, typed URL or search, open tabs ("Switch to Tab"), history.
- `EngineCalls`: calls the engine's exported `ac_*` C functions (`dlsym`, JSON in, JSON reply), e.g.
  `ac_history_query`. Their arguments are in `third_party/ardia/engine/chromium/src/chrome/browser/ardia/ac_*.cc`.
- `Resources/page_script.js`: runs in every frame; iframes return on its first line. Only `hello` today.
- `tests/`: `checks.mjs` (DevTools + `[lumen-state]` log checks on a hidden instance), `AddressInputTests.swift`.
- `Host/TestCommands.swift`: with `LUMEN_TEST_COMMANDS=1`, stdin lines drive the real UI (`menu <action>`,
  `type <text>`, `enter`, `escape`) through the same code paths as the keyboard. DevTools can't reach native UI, so
  checks for the sidebar and address field go through this.
- `vendor/ardiacore/ArdiaCore.h`: the engine's public API, copied from Ardia at the tag in `engine.lock`. Must match
  the engine binary; update both together.
- `engine.lock`: the pinned prebuilt engine (tree, release, sha256). `scripts/fetch-engine.sh` downloads and checks it.
- `third_party/ardia/`: read-only reference clone of Ardia at `ardia_tag` (gitignored). Read it for behaviour; don't
  build from it.
- `third_party/crest/`: read-only reference clone of Crest (gitignored), another native-Mac Chromium browser.

## Build and run
- `scripts/build-app.sh` → `build/Lumen.app` (the user's app) and `build/LumenTests.app` (same code compiled with
  `-D LUMEN_TEST_HOOKS`, bundle id `….tests`). Test hooks, `LUMEN_*` overrides, URL logs and the DevTools port exist
  only in the test app; checks and `run-hidden.sh` use it, `relaunch.sh` opens the real one.
- `scripts/run-hidden.sh <throwaway data dir> [port] [url]` launches hidden and prints DevTools' page list.
- `scripts/test.sh [check …]`: address-parsing unit tests, then `tests/checks.mjs` (hidden instance, own data dir,
  local fixture pages). Add a check for every behaviour you add or fix.
- Engine delegate methods are `@optional`: a Swift name that's slightly off compiles with only a "nearly matches"
  warning and is never called. Treat those warnings as errors.

## Security checklist (every change)
Web pages are hostile; Chromium sandboxes them, but Lumen's chrome must not hand them anything back.
- **Identity comes from the engine, never the page.** Use the verified `origin` the engine passes with page messages
  and the tab's `committedOrigin`; ignore any URL or origin a page reports about itself.
- **Page channel:** `Resources/page_script.js` runs in every frame; iframes return on its first line unless a feature
  needs them. Treat every message as untrusted: check kind, types and sizes; never act on it across tabs.
- **URLs from anywhere** (address field, command bar, history, suggestions, drag and drop, `Sidebar.json`, popups) go
  through `AddressInput`. Never load `javascript:`. Load `data:`/`file:` only when the user typed it.
- **Address display:** host only, elided from the start, `user:pass@` hidden, port shown; never show page-controlled
  text where the address goes.
- **Prompts** (permissions, external apps, downloads, extension installs, password save): deny or close by default,
  show the full origin, ignore clicks for the first 0.5 s, never auto-accept, never show over another tab's page.
- **No string-built code:** JSON through `JSONSerialization` only (`EngineCalls`); never build JS for
  `evaluate`/`executeJavaScript` from untrusted text.
- **Test and debug hooks** (`TestCommands`, `[lumen-state]` logs, DevTools port, `LUMEN_*` overrides) work only when
  their `LUMEN_*` variable is set, and are never reachable from a page or a normal launch.
- **Logs:** no URLs, titles, page messages, cookies or credentials in `NSLog` in normal runs.
- **Secrets:** never in `Sidebar.json`, logs or tests. While on the prebuilt engine (mock keychain), Lumen isn't for
  real accounts.
- **Monitors:** global event monitors watch pointer position only, never keys; none in test instances.
- **Engine:** `engine.lock` pins the SHA-256; on every bump, note the Chromium version against current Chrome stable.
- **Every security-relevant behaviour gets a check** in `tests/checks.mjs`.

## Key routing
- `preHandleKeyEvent` runs only Chrome's reserved set (`Shortcuts.isReserved`: ⌘T ⌘W ⌘N ⌘Q ⇧⌘T ⇧⌘W ⇧⌘N ⇧⌘[ ⇧⌘]
  ⌃Tab) before the page. Everything else reaches the page first; `handleKeyEvent` (page didn't use it) sends it to
  the main menu.

## Rules
- Commit messages: caveman style, one short line like `feat: arc like sidebar` or `fix: sidebar opening too quickly`
  (conventional prefix, lowercase, no body unless the why is non-obvious). No Co-Authored-By or other attribution.
- Before any design or behaviour decision, check all three references and say what each does: Chromium's source
  (Chrome's behaviour), Ardia (`third_party/ardia`, same engine) and Crest (`third_party/crest`). None is
  automatically right; weigh them, and where they disagree pick on evidence. Don't narrate the checking.
- Never steal focus with test instances: test only through `scripts/run-hidden.sh` / `tests/checks.mjs`
  (`LUMEN_BACKGROUND=1`, own data dir).
- After a build the user should look at, run `scripts/relaunch.sh` once checks pass: it quits their running Lumen with
  a normal macOS quit and opens the new build in front on their default data dir. The user asked for this; they
  can't easily run commands themselves.
- Every test instance gets its own throwaway `LUMEN_DATA_DIR`; never the default data dir, never a real browser profile.
- Quit the instances you start (`kill -TERM <pid>`), and only those.
- Every wait has a deadline.
- Verify before calling something done: build, run hidden, check over DevTools (port) and the stderr log; say what
  still needs a visual check.
- UI hot paths (sidebar, tab rows, window chrome) are AppKit + Core Animation, never SwiftUI. Animations run on
  layers, not main-thread timers. A tab switch shows the page before any store update.
- No Peek, no WebKit, no built-in content blocker, no Ardia performance messages in the page script.
- Lumen always runs with `--use-mock-keychain` while it's on Ardia's prebuilt engine: that engine's keychain item
  is "Ardia Safe Storage", which belongs to the user's real Ardia. Never let Lumen read it. Our own engine build
  (Phase B) gets a "Lumen Safe Storage" item and drops the switch.

# Lumen

A macOS (14+, Apple Silicon) Chromium browser with Arc's sidebar, pinned tabs and pinned tiles. Native AppKit +
Core Animation UI on Ardia's engine. `PLAN.md` is the plan and the source of truth for decisions.

## Layout
- `Host/`: the native app in Swift + AppKit. `Bridging.h` exposes the engine API. `BrowserWindowController` owns a
  window's tabs; `SidebarView` is the address field and tab list; `PageContainerView` shows one page at a time
  (others stay attached but hidden, with `noteShown(byHost:)`); `MainMenu` + `Shortcuts` do key routing.
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

## Build and run
- `scripts/build-app.sh` → `build/Lumen.app` (fetches the engine, compiles `Host/`, re-signs the framework ad hoc).
- `scripts/run-hidden.sh <throwaway data dir> [port] [url]` launches hidden and prints DevTools' page list.
- `scripts/test.sh [check …]`: address-parsing unit tests, then `tests/checks.mjs` (hidden instance, own data dir,
  local fixture pages). Add a check for every behaviour you add or fix.
- Engine delegate methods are `@optional`: a Swift name that's slightly off compiles with only a "nearly matches"
  warning and is never called. Treat those warnings as errors.

## Key routing
- `preHandleKeyEvent` runs only Chrome's reserved set (`Shortcuts.isReserved`: ⌘T ⌘W ⌘N ⌘Q ⇧⌘T ⇧⌘W ⇧⌘N ⇧⌘[ ⇧⌘]
  ⌃Tab) before the page. Everything else reaches the page first; `handleKeyEvent` (page didn't use it) sends it to
  the main menu.

## Rules
- Never steal focus: test only through `scripts/run-hidden.sh` (`open -g -n`, `LUMEN_BACKGROUND=1`).
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

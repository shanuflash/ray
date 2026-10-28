# Ray

A macOS (14+, Apple Silicon) Chromium browser with Arc's sidebar, pinned tabs and pinned tiles. Native AppKit +
Core Animation UI on Ardia's engine. `PLAN.md` is the plan and the source of truth for decisions.

## Layout
- `Host/`: the native app in Swift + AppKit. `Bridging.h` exposes the engine API. `BrowserWindowController` owns a
  window's tabs; `SidebarView` is the address field and tab list; `PageContainerView` shows one page at a time
  (others stay attached but hidden, with `noteShown(byHost:)`); `MainMenu` + `Shortcuts` do key routing.
- `CommandBarView` + `Suggestions`: the Arc-style command bar (⌘T new tab, ⌘L / clicking the sidebar address =
  current tab). Rows: autocompleted host match, typed URL or search, open tabs ("Switch to Tab"), history.
- `PageToolbar`: Dia's address bar above the page (View › Show Address Bar on Page). Geometry is Ardia's
  (`third_party/ardia/apps/browser/src/components/ui/theme.ts` `layout`, `components/toolbar/Toolbar.tsx`): 41 pt,
  buttons centred at 21/56/92/127, address from 145; host only, path on hover. The sidebar/back/forward/reload
  buttons ride the sidebar's dock spring in while the sidebar is hidden. Its sliders button opens `SiteControls`:
  quick actions, extension tiles, the site's permissions (`ac_site_settings_*`, keyed by the tab's
  `committedOrigin`) and the connection state.
- `ConnectionLook` (in `AddressInput.swift`): the security icon for both address fields and the panel's footer.
- `ProfileColor`: the profile's colour, which every accent in Ray's UI uses (loading wash, progress, drop targets,
  selection, "on" states). Default: Dia's lavender; profiles and their settings come later. Never use
  `NSColor.controlAccentColor` (`scripts/test.sh` fails on it). `LoadingTint` uses Dia's measured lilac-to-lavender
  ramp for the default and builds the same shape around any other colour.
- `EngineCalls`: calls the engine's exported `ac_*` C functions (`dlsym`, JSON in, JSON reply), e.g.
  `ac_history_query`. Their arguments are in `third_party/ardia/engine/chromium/src/chrome/browser/ardia/ac_*.cc`.
  `EngineEvents` is the one engine event sink (`downloads.changed`, …), handed out by topic.
- Pinned folders are `SidebarEntry`s of kind `.folder` inside `state.pinned`, kept in tree order with `parentID`
  links; `SidebarState.normalizePinned()` rebuilds a valid tree after every change and on load.
- `Extensions` (puzzle button in the sidebar address field, action popups in an NSPopover, install prompt),
  `Downloads` (button in the sidebar footer, ⌥⌘L; the list slides up as a panel inside the sidebar), `FindBar` (⌘F),
  `PermissionPrompt` (site permissions, only over their own tab), `ArcImport` (File › Import from Arc…, reads Arc's
  StorableSidebar.json only when asked), `Toast` (Arc's top-right note, "Copied Current URL").
- `Spring`: a CADisplayLink spring. `dockSpring` (⌘S) and `peekSpring` drive `layout()` every frame.
- `Branding/Ray.icon` (Icon Composer; `actool` builds Assets.car + Ray.icns) and `tools/rebrand-pak.py` (renames
  "Ardia" to "Ray" and swaps Ardia's logos in the engine's .pak files at build time).
- `Resources/page_script.js`: runs in every frame; iframes return on its first line. Only `hello` today.
- `tests/`: `checks.mjs` (DevTools + `[ray-state]` log checks on a hidden instance), `AddressInputTests.swift`,
  `affected.mjs` (which checks each file or `// MARK:` section can affect) and `changed.mjs` (diff → checks).
- `Host/TestCommands.swift`: with `RAY_TEST_COMMANDS=1`, stdin lines drive the real UI (`menu <action>`,
  `type <text>`, `enter`, `escape`) through the same code paths as the keyboard. DevTools can't reach native UI, so
  checks for the sidebar and address field go through this.
- `vendor/ardiacore/ArdiaCore.h`: the engine's public API, copied from Ardia at the tag in `engine.lock`. Must match
  the engine binary; update both together.
- `engine.lock`: the pinned prebuilt engine (tree, release, sha256). `scripts/fetch-engine.sh` downloads and checks it.
- `third_party/ardia/`: read-only reference clone of Ardia at `ardia_tag` (gitignored). Read it for behaviour; don't
  build from it.
- `third_party/crest/`: read-only reference clone of Crest (gitignored), another native-Mac Chromium browser.

## Build and run
- `scripts/build-app.sh` → `build/Ray.app` (the user's app) and `build/RayTests.app` (same code compiled with
  `-D RAY_TEST_HOOKS`, bundle id `….tests`). Test hooks, `RAY_*` overrides, URL logs and the DevTools port exist
  only in the test app; checks and `run-hidden.sh` use it, `relaunch.sh` opens the real one.
- Quit the user's Ray before building: macOS App Management blocks rewriting a running bundle (EPERM, a half-built
  app, a broken icon). `osascript -e 'tell application id "<CFBundleIdentifier of build/Ray.app>" to quit'`.
- `scripts/run-hidden.sh <throwaway data dir> [port] [url]` launches hidden and prints DevTools' page list.
- `scripts/test.sh [check …]`: address-parsing unit tests, then `tests/checks.mjs` (hidden instance, own data dir,
  local fixture pages). Add a check for every behaviour you add or fix.
- Engine delegate methods are `@optional`: a Swift name that's slightly off compiles with only a "nearly matches"
  warning and is never called. Treat those warnings as errors.

## Testing
- Per change: `scripts/build-app.sh && scripts/test.sh --changed`. It runs the unit tests, then only the checks the
  working tree's diff (plus untracked files) can affect, printing the reason per file. `--changed <base>` diffs
  against another commit. Run the whole suite (`scripts/test.sh`) before a push, and whenever `--changed` says
  "all" anyway.
- Keep `tests/affected.mjs` honest: a new Host file, a new `// MARK:` section in a big file, or a new check gets its
  entry in the same change. Unmapped files run everything (safe, slow). A section runs from its MARK to the next
  MARK or top-level declaration. Changes inside a check in `checks.mjs` run that check; changes to shared helpers
  run everything.
- Animations: record what happened app-side (e.g. `navigationSteps` in the state log) instead of polling; a command
  round trip is slower than a 0.26 s spring.
- Multi-window checks: `state()` is whichever window logged last; poll `command("state")`, which logs the current one.
- Known environment noise. Spring checks skip while the display sleeps (`needsFrames`). Some checks only run when the
  hidden test window happens to land on the visible desktop: `switch-back-latency` then fails (on older commits
  too) and leaves state that breaks `private-window`, `arc-import` and `close-last-window` after it. A subset run
  can also fail from what earlier checks left behind. Before blaming a change, run the same command on the
  previous commit (`git stash -u`, build, run, `git stash pop`) and compare.

## Gotchas (learnt the hard way)
- Shifted menu key equivalents must be uppercase ("C" for ⇧⌘C); real and synthetic ⇧-keys arrive uppercase.
- Chrome's window swallows reserved shortcuts (⌘W with no tab) before the menu sees them: `AppController` routes
  `Shortcuts.isReserved` keys to the main menu from an app-local keyDown monitor. A menu item that
  `validateMenuItem` disables never fires its shortcut either.
- Info.plist needs the privacy usage strings (camera, microphone, location, Bluetooth, audio capture): without them
  TCC kills Ray the moment a site asks.
- The engine silently cancels insecure downloads (HTTPS page → HTTP file); Keep/Discard only shows for files Chrome
  holds as dangerous. Ardia 0.2.42's "insecure download waits for Keep" is its app UI over the same engine tree
  (`ac_downloads_keep` already handles insecure ones), so on this engine nothing changes.
- NSPopover is Liquid Glass on macOS 26+, so content without its own background shows the glass. Extension popups
  get Chrome's white base (`contentsBackgroundColor`). The user dislikes popovers for Ray's own UI: build in-window
  panels (downloads, site controls) that close on an outside click, Escape and tab switches.
- Extension action icons can be empty (they load late, or only the background page sets one): fall back to the
  manifest icon from `ac_extensions_list`, as Chrome's toolbar does.
- `NSTextField` labels draw from the top of their frame: make the frame exactly one line tall
  (`intrinsicContentSize.height`) and centre that, or text rides 1–2 pt high.
- Chrome's content layer follows the page by CALayer autoresizing, which rounds each step: keep page frames on whole
  points or the page creeps a little on every ⌘S.
- Chrome that moves with the sidebar takes `dockSpring.value` in `layout()`; never switch it on
  `state.sidebarHidden`, which flips before the animation starts.
- Subview order in the window's root: pages < toolbar < sidebar / floating peek < panels and toast. New UI over the
  page goes below `floating`, so a peeking sidebar covers it.
- Security icon (`ConnectionLook`): nothing on dev hosts (localhost, 127/8, ::1, `*.localhost`, `*.test`), a grey
  open lock for plain http, red only for a certificate error on a real site. The user hated Dia's red lock on dev.
- Scripted edits: assert the old text matches exactly once before replacing; an empty-string replace once corrupted
  `checks.mjs`.

## Security checklist (every change)
Web pages are hostile; Chromium sandboxes them, but Ray's chrome must not hand them anything back.
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
- **Test and debug hooks** (`TestCommands`, `[ray-state]` logs, DevTools port, `RAY_*` overrides) work only when
  their `RAY_*` variable is set, and are never reachable from a page or a normal launch.
- **Logs:** no URLs, titles, page messages, cookies or credentials in `NSLog` in normal runs.
- **Secrets:** never in `Sidebar.json`, logs or tests. While on the prebuilt engine (mock keychain), Ray isn't for
  real accounts.
- **Monitors:** global event monitors watch pointer position only, never keys; none in test instances.
- **Engine:** `engine.lock` pins the SHA-256; on every bump, note the Chromium version against current Chrome stable.
- **Every security-relevant behaviour gets a check** in `tests/checks.mjs`.

## Key routing
- `preHandleKeyEvent` runs only Chrome's reserved set (`Shortcuts.isReserved`: ⌘T ⌘W ⌘N ⌘Q ⇧⌘T ⇧⌘W ⇧⌘N ⇧⌘[ ⇧⌘]
  ⌃Tab) before the page. Everything else reaches the page first; `handleKeyEvent` (page didn't use it) sends it to
  the main menu.

## Rules
- Don't push until the user has tried the build and says so: commit locally, relaunch, wait. Commit only when the
  checks you ran pass (look for FAIL in the output first).
- Match Arc and Dia from the user's screenshots and recordings. For exact sizes and spacing read Ardia's source
  (same design lineage) instead of measuring pixels.
- Commit messages: caveman style, one short line like `feat: arc like sidebar` or `fix: sidebar opening too quickly`
  (conventional prefix, lowercase, no body unless the why is non-obvious). No Co-Authored-By or other attribution.
- Before any design or behaviour decision, check all three references and say what each does: Chromium's source
  (Chrome's behaviour), Ardia (`third_party/ardia`, same engine) and Crest (`third_party/crest`). None is
  automatically right; weigh them, and where they disagree pick on evidence. Don't narrate the checking.
- Never steal focus with test instances: test only through `scripts/run-hidden.sh` / `tests/checks.mjs`
  (`RAY_BACKGROUND=1`, own data dir).
- After a build the user should look at, run `scripts/relaunch.sh` once checks pass: it quits their running Ray with
  a normal macOS quit and opens the new build in front on their default data dir. The user asked for this; they
  can't easily run commands themselves.
- Every test instance gets its own throwaway `RAY_DATA_DIR`; never the default data dir, never a real browser profile.
- Quit the instances you start (`kill -TERM <pid>`), and only those.
- Every wait has a deadline.
- Verify before calling something done: build, run hidden, check over DevTools (port) and the stderr log; say what
  still needs a visual check.
- UI hot paths (sidebar, tab rows, window chrome) are AppKit + Core Animation, never SwiftUI. Animations run on
  layers, not main-thread timers. A tab switch shows the page before any store update.
- No Peek, no WebKit, no built-in content blocker, no Ardia performance messages in the page script.
- Ray always runs with `--use-mock-keychain` while it's on Ardia's prebuilt engine: that engine's keychain item
  is "Ardia Safe Storage", which belongs to the user's real Ardia. Never let Ray read it. Our own engine build
  (Phase B) gets a "Ray Safe Storage" item and drops the switch.

# Contributing to Ray

Thanks for helping. Ray's goal: the most Arc-feeling browser on real, de-Googled Chromium for Mac. Every change is
weighed against three things: Arc's feel, real Chromium with working extensions, and painless switching from Arc.

New here? Start with [docs/GOOD-FIRST-ISSUES.md](docs/GOOD-FIRST-ISSUES.md).

## What you need

- A Mac on Apple Silicon, macOS 14 or later
- Xcode (Ray is built with `xcrun swiftc`, no Xcode project)
- Node.js, for the checks in `tests/`
- Ray's engine (below)

## The engine

Ray's UI is in `Host/` (Swift, AppKit). The engine is Chromium built from `engine/`, which is generated from
[Ardia](https://github.com/mantrakp04/ardia)'s engine by `tools/engine/sync-engine.sh` plus Ray's own changes in
`engine-ray/`. Never edit `engine/` by hand: change `engine-ray/` and sync.

`engine.lock` says where the engine comes from:

- `source=local` (today): build it yourself in `~/chromium-build`, steps 1, 3, 4, 2, 5 of `engine/patches/build/`,
  under `scripts/locked chromium`. The first build takes hours and a lot of disk. `RAY_ENGINE_FRAMEWORK` points Ray
  at a framework somewhere else.
- `source=prebuilt`: `scripts/fetch-engine.sh` downloads a published engine and checks its sha256.

<!-- TODO before launch: publish a prebuilt engine, switch engine.lock to source=prebuilt and make it the first
     option here, so a UI change doesn't need a Chromium build. -->

Most changes are in `Host/` and never touch the engine.

## Build

```sh
scripts/build-app.sh
```

Makes `build/Ray.app` (the real app) and `build/RayTests.app` (the same code with test hooks). Quit any Ray you
built before rebuilding: macOS blocks rewriting a running app.

## Test

```sh
scripts/test.sh --changed
```

Runs the unit tests, then only the checks your diff can affect, on a hidden test instance with its own throwaway
data dir. Look for `FAIL` in the output. `scripts/test.sh <check>` runs one check by name; `scripts/test.sh` alone
runs everything (slow; once before you send).

- Every behaviour you add or fix gets a check in `tests/checks.mjs`.
- A new `Host/` file, `// MARK:` section or check gets its entry in `tests/affected.mjs`, so `--changed` finds it.
- Test only through `scripts/run-hidden.sh` and `tests/checks.mjs`. Never on your real profile, never stealing focus.
- Some checks are flaky in known ways: see "Known environment noise" in [CLAUDE.md](CLAUDE.md). Before blaming your
  change, run the same check on `main`.

## Send a change

1. Fork, branch from `main`.
2. One change per pull request. Small is better.
3. `scripts/build-app.sh && scripts/test.sh --changed` passes.
4. Docs in the same commit:
   - a new file, MARK section, setting, test hook or check: its line in [CLAUDE.md](CLAUDE.md)'s Layout
   - a feature that lands: move it to "Done" in [docs/MISSING.md](docs/MISSING.md)
   - a gap you find: add it to "Known limitations" there
   - anything a user would notice: README's "What works", "Coming" or "Privacy and security"
5. Commit messages: one short lowercase line with a prefix, e.g. `feat: arc like sidebar`,
   `fix: sidebar opening too quickly`. A body only when the why isn't obvious.
6. Open the pull request. Say what you changed, how you tested it, and what still needs a look by eye.

Big or design changes: open an issue first. The owner decides the look and the order.

By contributing you agree your work is licensed under GPL-3.0 ([LICENSE](LICENSE)).

## House rules

The full set is in [CLAUDE.md](CLAUDE.md). The short version:

**Feel**
- Match Arc. For exact sizes and spacing, read Ardia's source rather than measuring pixels.
- Before a design or behaviour decision, see what Chromium, Ardia, Crest and Cra do. Pick on evidence.
- Sidebar, tab rows, window chrome and Settings are AppKit + Core Animation. Never SwiftUI there.
- Animations run on layers, not main-thread timers. A tab switch shows the page before anything else.
- No popovers for Ray's own UI: use `Panels`. Accents come from `ProfileColor`, never the system accent.
- Settings copy is Arc's: a row is its title; a grey line only to warn or clear something up.
- No WebKit. Peek and a built-in content blocker are open decisions: don't build them yet.

**Security** (web pages are hostile)
- Identity comes from the engine (`committedOrigin`, the verified `origin`), never from what a page says.
- Every URL, from anywhere, goes through `AddressInput`. Never load `javascript:`.
- Treat every page-script message as untrusted: check kind, types and sizes.
- JSON only through `JSONSerialization`. Never build JS from untrusted text.
- Prompts deny by default, show the full origin and ignore clicks for the first 0.5 s.
- No URLs, titles, cookies or credentials in logs. No secrets in `Sidebar.json`, logs or tests.
- Test hooks work only in the test app with their `RAY_*` variable set.
- Every security-relevant behaviour gets a check.

**Performance**
- Measured every release, never regressing silently. `tests/perf.mjs`; numbers in
  [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Where things are

- `Host/`: the app. `BrowserWindowController` owns a window, `SidebarView` the sidebar, `CommandBarView` the bar.
- `Importer/`: browser import (`swift test --package-path Importer`, fixtures only).
- `engine-ray/`: Ray's engine patches and fixups. `engine/`: generated, don't edit.
- `tests/`: checks and unit tests.
- [PLAN.md](PLAN.md): the plan and every decision. [docs/MISSING.md](docs/MISSING.md): what's left.

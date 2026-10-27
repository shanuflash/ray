# Lumen

A macOS (14+, Apple Silicon) Chromium browser with Arc's sidebar, pinned tabs and pinned tiles. Native AppKit +
Core Animation UI on Ardia's engine. `PLAN.md` is the plan and the source of truth for decisions.

## Layout
- `Host/`: the native app (ObjC++ today; Swift/AppKit UI arrives in M1–M2).
- `vendor/ardiacore/ArdiaCore.h`: the engine's public API, copied from Ardia at the tag in `engine.lock`. Must match
  the engine binary; update both together.
- `engine.lock`: the pinned prebuilt engine (tree, release, sha256). `scripts/fetch-engine.sh` downloads and checks it.
- `third_party/ardia/`: read-only reference clone of Ardia at `ardia_tag` (gitignored). Read it for behaviour; don't
  build from it.

## Build and run
- `scripts/build-app.sh` → `build/Lumen.app` (fetches the engine, compiles `Host/`, re-signs the framework ad hoc).
- `scripts/run-hidden.sh <throwaway data dir> [port] [url]` launches hidden and prints DevTools' page list.

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

# Chromium watch

Chrome stable (and extended stable) releases for Mac, and Helium releases, against the Chromium Ray's engine is
built on. Newest first. A daily task (`chromium-watch-daily`) appends here and commits only this file; it never
touches engine files or builds. Moving the engine is the owner's call. Ardia's side is in `docs/ARDIA-WATCH.md`.

Ray's engine: Chromium 156.0.8078.47 (`engine.lock`), Helium helium-chromium 0.20.1 / helium-macos 0.20.1.1
(`engine/patches/build/helium-pins.ini`).

Last checked: Chrome 156.0.8078.80 (Mac stable and extended), 2026-11-02

## 2026-11-02

**Ray is two security releases behind on M156, with 5 Critical and 65 High fixes missing. Helium is already
on .79, so a same-milestone bump is ready.**

Chrome for Mac (chromiumdash):
- **156.0.8078.79 / .80**, stable and extended, 2026-10-29/30 (blog: "Stable Channel Update for Desktop",
  2026-10-29). 21 security fixes:
  - Critical: CVE-2026-76024, memory corruption in MediaStream.
  - High (19): FileSystem (CVE-2026-76025 UAF, -76028 UAF, -76030), Autofill (-76026), CacheStorage (-76027,
    -119270), Network (-76029), Input UAF (-76031), Frames UAF (-119260), Skia (-119261, -119271 UAF),
    V8 input validation (-119262), GarbageCollection (-119263), Dawn (-119264), Quota (-119265, -119266 UAF),
    DOM (-119267), Editing integer overflow (-119268), Blink UAF (-119269).
  - Medium: CVE-2026-119272, out-of-bounds read in FileSystem.
- **156.0.8078.73 / .74 / .75**, stable (.74 also extended), 2026-10-27/28 (blog post 2026-10-27). 52 security
  fixes: 4 Critical, 46 High, 2 Medium.
  - Critical: CVE-2026-118306 (FileSystem memory corruption), CVE-2026-118331 (FileAPI input validation),
    CVE-2026-118348 (Skia input validation), CVE-2026-118344 (UAF in Layout).
  - High includes V8 (CVE-2026-118318 access control, -118320), Turbolev (-118350 UAF, -118305), ANGLE
    (-118322, -118329), Skia (-118354, -118340, -118351), WebRTC (-118328), WebAudio (-118358), Paint UAF
    (-118307), Animation UAF (-118339), Headless (-118336).
- 156.0.8078.49 (stable, 2026-10-28) and .48 (stable and extended, 2026-10-21): small respins; the blog lists no
  separate security fixes for them.
- **157.0.8103.26** (early stable, 2026-10-28; .15/.16 on 2026-10-22): M157 to a small share of users; Windows
  first, Mac "coming shortly". Full M157 stable not out yet. Beta is 158.0.8127.2, Dev 159.0.8130.0.
- None of these posts says an exploit exists in the wild.

How far behind: same milestone (156), .47 against .80. Every fix above is missing from Ray. A patch release in
M156 is the smaller rebuild (pins, refreshed patches, incremental build); M157 is a new milestone (bigger patch
refresh, longer build) and has no Helium release yet.

Helium:
- helium-chromium 0.20.2 (2026-10-28) is on 156.0.8078.73; **0.20.3 (2026-10-30, latest) is on 156.0.8078.79**.
- helium-macos 0.20.2.1 (2026-10-28) and **0.20.3.1 (2026-10-30, latest)**.
- So Helium is ready for 156.0.8078.79 (the .79 fixes; .80 is Google's Mac/extended build number of the same
  fixes). No Helium release for M157 yet.

What moving would take: bump `helium-pins.ini` to helium-chromium 0.20.3 / helium-macos 0.20.3.1 and
`engine.lock` to 156.0.8078.79, re-sync and rebuild the engine (`engine/patches/build/` steps under
`scripts/locked chromium`). Ardia hasn't bumped Chromium (still .47 as of `docs/ARDIA-WATCH.md`, last reviewed
2026-10-30); its engine-4d8c64033b08 changes could go in the same rebuild. Not started: owner decides.

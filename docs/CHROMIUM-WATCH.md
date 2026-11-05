# Chromium watch

Chrome stable (and extended stable) releases for Mac, and Helium releases, against the Chromium Ray's engine is
built on. Newest first. A daily task (`chromium-watch-daily`) appends here and commits only this file; it never
touches engine files or builds. Moving the engine is the owner's call. Ardia's side is in `docs/ARDIA-WATCH.md`.

Ray's engine: Chromium 156.0.8078.47 (`engine.lock`), Helium helium-chromium 0.20.1 / helium-macos 0.20.1.1
(`engine/patches/build/helium-pins.ini`).

Last checked: Chrome 158.0.8127.18 (Mac early stable), 157.0.8103.39 (Mac stable), 156.0.8078.88 (Mac extended), 2026-11-05

## 2026-11-05

**Chrome 158 started its early stable rollout (no security notes yet). Helium-chromium 0.21.1 moved to M157
(157.0.8103.38), but helium-macos has no 0.21 release yet, so M157 isn't buildable for Ray from Helium alone.**

Chrome for Mac (chromiumdash):
- **158.0.8127.18 / .19**, early stable, 2026-11-04 (blog: "Early Stable Update for Desktop"): a small
  percentage of users, Mac "coming shortly". The post lists no security fixes; those come with M158's full
  stable post. Same build as today's Beta.
- 156.0.8078.82, stable, 2026-11-04: another M156 respin next to the early stable; no post of its own.
- Extended stable unchanged at 156.0.8078.88. Nothing exploited in the wild reported.

How far behind: unchanged in substance from yesterday. Ray's 156.0.8078.47 misses M156's fixes through .88
(5 Critical in .73–.80 plus .88's backports, incl. Critical CVE-2026-121156) and all of M157's 213; M158 is
now one milestone further out.

Helium:
- helium-chromium **0.21.1** (2026-11-04): Chromium 157.0.8103.38, patches refreshed, ungoogled-chromium
  157.0.8103.38, uBlock 1.75.4.
- helium-macos: still **0.20.3.1** (2026-10-30). No macOS release for 0.21.1 yet.

What moving would take: M156 bump still ready (0.20.3 / 0.20.3.1, Chromium 156.0.8078.79). M157 needs a
helium-macos 0.21.1.x first; then `helium-pins.ini` and `engine.lock` to 157.0.8103.38, re-sync, refresh
Ray's and Ardia's fixups for M157, full rebuild (new milestone, longer). Watch `docs/ARDIA-WATCH.md` for an
Ardia M157 engine. Not started: owner decides.

## 2026-11-04

**Chrome 157 is stable (213 security fixes, 7 Critical, 77 High). Ray's .47 now also misses 156.0.8078.88's
extended backports. Helium has nothing past 0.20.3 (156.0.8078.79), so only the M156 bump is ready.**

Chrome for Mac (chromiumdash):
- **157.0.8103.38 / .39**, stable, 2026-11-03 (blog: "Stable Channel Update for Desktop", 2026-11-03). M157
  promoted to stable for everyone, rolling out over days/weeks. 213 security fixes: 7 Critical, 77 High, 75
  Medium, 54 Low.
  - Critical: CVE-2026-121156 and -121247 (buffer overflow in Dawn), -121229 (ANGLE memory corruption),
    -121246 (WebGL UAF), -121035 (Prerender UAF), -121203 (Geometry UAF), -121126 (Core UAF).
  - High includes V8 type confusion (CVE-2026-121082, -121228, -121210, -121057), PDFium (-121166 type
    confusion, -121113 overflow, -121179 UAF), ANGLE (-121197, -121037 OOB write, -121148 UAF), WebGPU UAF
    (-121089), GPU (-121074, -121052 UAF, -121098), Skia (-121086, -121032), Media overflows (-121047, -121180),
    Extensions UAF (-121250), BackgroundFetch authorization (-121107, -121174), FileSystem authorization
    (-121071), Navigation privilege (-121090), and UAFs in SVG, Layout, DOM, Editing, Codecs, Compositing,
    WebAudio, Animation, PictureInPicture, PerformanceAPIs.
- **156.0.8078.88**, extended stable, 2026-11-03 (blog: "Extended Stable Update for Desktop"). 55 security fixes
  (3 Critical, 49 High, 2 Medium, 1 Low): everything in .79/.80 plus M157 fixes backported to M156, among them
  Critical CVE-2026-121156 (Dawn) and Highs -121032, -121057, -121071, -121086, -121127, -121148, -121201,
  -121210, -121250 and ~20 more.
- 156.0.8078.81, stable, 2026-11-03: a respin next to the M157 release; no blog post of its own.
- None of these posts says an exploit exists in the wild.

How far behind: Ray is on 156.0.8078.47. Same milestone: .47 against .88 (extended), missing every fix since
2026-10-27 (5 Critical in .73–.80, plus .88's backports). New milestone: M157 is now what Chrome stable users
run, with 213 fixes Ray lacks; moving to it is a bigger patch refresh and a longer build than an M156 bump.

Helium:
- No new release since 2026-10-30: helium-chromium **0.20.3** (156.0.8078.79) and helium-macos **0.20.3.1** are
  still latest. Nothing for 156.0.8078.88 or M157 yet.

What moving would take: unchanged from 2026-11-02 for M156 (`helium-pins.ini` to 0.20.3 / 0.20.3.1,
`engine.lock` to 156.0.8078.79, re-sync, rebuild; Ardia's engine-1982453a46fe already did this bump and is in
engine-2da3ca19a224, see `docs/ARDIA-WATCH.md`). That still lacks .88's backports (incl. Critical
CVE-2026-121156); getting those needs Helium on .88 or M157. M157 waits for a Helium 0.21-ish release. Not
started: owner decides.

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

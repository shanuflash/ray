# Performance

Numbers come from `tests/perf.mjs` (see CLAUDE.md, Testing): hidden test instances, `--runs 3` medians, run under
`scripts/locked perflab`. Each area below keeps to its own section.

## Baseline: v0.7.0 vs 0.9.5 (2026-11-12)

Both test builds on the same engine (Chromium 156.0.8078.47), one after the other under the lock on a quiet Mac,
`--runs 3` (launch 5), medians. Scenarios: `tests/perf.mjs` header. v0.7.0's tab switch, ⌘S with 15 tabs and idle
numbers carry bugs fixed since (0.7.x); the command bar was the one regression (site completion, Tab to Search,
settings rows and suggestion fill came after v0.7.0).

| Scenario | Metric | v0.7.0 | 0.9.5 |
|---|---|---|---|
| launch | coldMs | 374.24 | 394.56 |
| launch | coldHostMB | 51.05 | 48.86 |
| launch | coldTotalMB | 188.3 | 184.16 |
| launch | coldHostCpuS | 0.6 | 0.46 |
| launch | warmMs | 388.16 | 438.84 |
| launch | warmHostMB | 48.69 | 48.63 |
| launch | warmTotalMB | 183.49 | 183.34 |
| launch | warmHostCpuS | 0.43 | 0.43 |
| idle | 1tabHostCpuPct | 1.55 | 0.08 |
| idle | 1tabMainCpuPct | 1.09 | 0.05 |
| idle | 1tabGpuCpuPct | 0.36 | 0.02 |
| idle | 1tabTotalCpuPct | 2.86 | 0.12 |
| idle | 1tabHostWakeups | 20.29 | 1.49 |
| idle | 1tabTotalWakeups | 75.39 | 6.23 |
| idle | 1tabHostMB | 49.2 | 48.97 |
| idle | 1tabTotalMB | 186.15 | 182.51 |
| idle | 15tabsHostCpuPct | 106.67 | 0.38 |
| idle | 15tabsMainCpuPct | 99.39 | 0.35 |
| idle | 15tabsGpuCpuPct | 6.97 | 0.09 |
| idle | 15tabsTotalCpuPct | 131.1 | 0.71 |
| idle | 15tabsHostWakeups | 11.9 | 9.42 |
| idle | 15tabsTotalWakeups | 341.51 | 27.7 |
| idle | 15tabsHostMB | 107.75 | 71.47 |
| idle | 15tabsTotalMB | 928.86 | 636.23 |
| tabswitch | ackMs | 35.49 | 4.78 |
| tabswitch | ackP95Ms | 59.07 | 11.6 |
| tabswitch | pingAfterMs | 32.6 | 10.36 |
| tabswitch | mainCpuMsPerSwitch | 394.69 | 53.44 |
| tabswitch | hostCpuMsPerSwitch | 439.8 | 56.87 |
| tabswitch | gpuCpuMsPerSwitch | 90.68 | 18.35 |
| tabswitch | totalCpuMsPerSwitch | 628.37 | 80.71 |
| tabswitch | framesToNew | 0 | 3 |
| tabswitch | blankFrames | 0 | 0 |
| tabswitch | switchesSeen | 20 | 20 |
| commandbar | openMs | 19.89 | 21.73 |
| commandbar | keyMs | 20.84 | 28.94 |
| commandbar | keyP95Ms | 25.39 | 35.25 |
| commandbar | keyMaxMs | 41.03 | 45.03 |
| commandbar | keyAckMs | 13.84 | 22.92 |
| commandbar | deleteMs | 20.11 | 26.98 |
| commandbar | mainCpuMsPerKey | 47.93 | 64.6 |
| commandbar | hostCpuMsPerKey | 53.73 | 69.89 |
| sidebar | 1tabAckMs | 0.4 | 0.35 |
| sidebar | 1tabMainCpuMsPerToggle | 104 | 105 |
| sidebar | 1tabHostCpuMsPerToggle | 116.87 | 116.67 |
| sidebar | 1tabGpuCpuMsPerToggle | 31.51 | 30.36 |
| sidebar | 1tabTotalCpuMsPerToggle | 167.25 | 164.94 |
| sidebar | 15tabsAckMs | 72.04 | 0.4 |
| sidebar | 15tabsMainCpuMsPerToggle | 780 | 142 |
| sidebar | 15tabsHostCpuMsPerToggle | 830.2 | 150.23 |
| sidebar | 15tabsGpuCpuMsPerToggle | 77.42 | 50.82 |
| sidebar | 15tabsTotalCpuMsPerToggle | 1076.52 | 242.4 |
| drag | moveAckMs | 17.92 | 0.3 |
| drag | moveP95Ms | 28.03 | 0.96 |
| drag | mainCpuMsPerMove | 58.63 | 2.25 |
| drag | hostCpuMsPerMove | 68.51 | 2.45 |
| drag | totalCpuMsPerMove | 103.83 | 3.14 |
| resize | supported | False | True |
| resize | layoutMsMax | – | 2.96 |
| resize | layoutMsMean | – | 2.43 |
| resize | frameMsMax | – | 16.67 |
| resize | longFrames | – | 1 |
| resize | mainCpuMsPerSweep | – | 286.67 |
| resize | totalCpuMsPerSweep | – | 437.82 |
| iframes | loadMs | 173.6 | 166 |
| iframes | mainCpuMsPerLoad | 215 | 205 |
| iframes | hostCpuMsPerLoad | 295.06 | 279.23 |
| iframes | totalCpuMsPerLoad | 746.6 | 710.02 |
| iframes | idleHostCpuPct | 0.04 | 0.04 |
| iframes | idleHostWakeups | 1.26 | 1.19 |
| iframes | renderers | 3 | 3 |
| iframes | totalMB | 815.84 | 847.62 |
| memory | startHostMB | 48.69 | 48.69 |
| memory | afterHostMB | 114.83 | 99.61 |
| memory | growthPerCycleHostMB | 8.15 | 9.38 |
| memory | startTotalMB | 184.55 | 186.63 |
| memory | afterTotalMB | 350.32 | 250.65 |
| memory | growthPerCycleTotalMB | 8.31 | 10.22 |


## Command bar

`tests/perf.mjs --only commandbar --runs 3` (20,000 history URLs, 4 queries of 5-9 keys, 3 rounds). v0.7.0 for
reference (1 run): open 20 ms, key 21 ms (ack 14), main CPU 48 ms/key.

| | open ms | key ms (p95) | key ack ms | delete ms | main CPU ms/key | host CPU ms/key |
|---|---|---|---|---|---|---|
| main 0.9.5 | 15.9 | 26.0 (34.2) | 21.9 | 24.9 | 60.6 | 64.6 |
| after | 20.1 | 12.6 (15.0) | 6.5 | 12.5 | 31.6 | 35.8 |

Cost: one letter matches most of history, and `Suggestions.build` made a row (shortened address, icon lookup) for every
match, re-parsed every matching address with `URLComponents` several times (host, front page, registrable domain), built
a front-page dictionary over all of history, searched every title and address with `String.range(of:)`, and
re-split every command's and setting's words per key. Now rows are made for the shown pages only, each address is parsed
once (`HistoryItem.site`, `Suggestions.facts`), titles and addresses are searched as ASCII bytes, the front-page map is
built only when a host starts with the typed word, and names' words are kept (`BarActions.BarName`). Same rows and ranking
(bar-ranking, bar-sites, bar-fills-rows, bar-arrow-fill, tab-to-search, site-search, settings-bar,
search-suggestions-off pass); guard: check `bar-key-work` (state log `commandBar.work`).

Left: a command bar key still reloads its table (`CommandBarView.show`, about 3 ms/key) and the test build logs state per key.
## Tab switch and sidebar (⌘S)

Before: main 0.9.5 (the orchestrator's 3-run baseline). After: this change (2026-11-12). CPU is ms per switch or
toggle; "main" is the host's main thread.

| Scenario | Metric | Before | After |
| --- | --- | --- | --- |
| tabswitch (8 tabs) | ack ms | 4.78 | 3.44 |
| tabswitch | main CPU / switch | 53.4 | 13.8 |
| tabswitch | host CPU / switch | 56.9 | 23.3 |
| tabswitch | GPU CPU / switch | 18.4 | 15.5 |
| tabswitch | total CPU / switch | 80.7 | 43.9 |
| tabswitch | frames to new page, blank frames | 3, 0 | 2, 0 |
| sidebar ⌘S, 1 tab | main CPU / toggle | 105 | 76 |
| sidebar ⌘S, 1 tab | total CPU / toggle | 165 | 162 |
| sidebar ⌘S, 15 tabs | main CPU / toggle | 142 | 100 |
| sidebar ⌘S, 15 tabs | total CPU / toggle | 242 | 220 |
| drag (15 tabs) | main CPU / move | 2.25 | 2.0 |
| resize sweep | main CPU / sweep | 287 | 210 |
| resize sweep | long frames | 1 | 0 |

(Single profiled runs of the same builds, with `sample` running, gave ⌘S main 102 → 54–61 at 1 tab and 138 → 89–111 at
15; this scenario varies by about ±20 ms between runs.)

What cost what (`PERF_SAMPLE=<dir>` makes the harness `sample` the host over the measured loops):

- Tab switch: `TabPictures.capture` scaled the engine's full-size page bitmap to a ⌃Tab card on the main thread, once
  or twice per switch (the command reaches `select` by itself and again by the engine's activation): 658 of ~850
  Ray samples. Now one copy per tab per 2 s, fitted on a utility queue, in the page's own colour space. The sidebar's
  rows also made a new `NSImage` for every symbol on every switch (`RowSymbols`, 3–4 ms).
- ⌘S: the loading wash redrew its bitmap on every frame (`LoadingWash.applyTint`, ~230 of ~1,000 busy samples) though
  nothing loaded; the page address field shaped its text twice per frame (host width, label width) and redrew its
  label as its width changed; every hidden page was resized each frame (Chrome resizes each page's views in step).
  Now the picture is drawn only for a sweep that shows, the host width is cached per address, the label is as wide as
  its text when that fits, and hidden pages take the settled size once.
- Left: AppKit's tracking-area and tooltip refresh of every row on every frame, Chrome's own work resizing the shown
  page, the engine's `copyPicture` memcpy on the main thread. See docs/MISSING.md, Known limitations 57.

Checks: `sidebar-motion-cheap` (hidden-page resizes and wash pictures bounded over ⌘S and a sidebar drag),
`tab-switch-cheap` (one picture copy per switch, no new symbol images).

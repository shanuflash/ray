# Performance

Numbers come from `tests/perf.mjs` (see CLAUDE.md, Testing): hidden test instances, `--runs 3` medians, run under
`scripts/locked perflab`. Each area below keeps to its own section.

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

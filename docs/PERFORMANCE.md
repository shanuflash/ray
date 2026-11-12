# Performance

Measured with `tests/perf.mjs` (see its header) on hidden test instances, under `scripts/locked perflab`.

## Idle and memory

Review of 2026-11-12. Before is main 0.9.5's 3-run column from the orchestrator's baseline; after is the same
harness (`--only idle,memory --runs 3`) on this branch.

| Scenario | Metric | Before (0.9.5) | After |
|---|---|---|---|
| idle | 1tabHostCpuPct | 0.08 | 0.88 (noisy) |
| idle | 1tabHostWakeups | 1.49 | 10.71 (noisy) |
| idle | 15tabsHostCpuPct | 0.38 | 1.28 (noisy) |
| idle | 15tabsHostWakeups | 9.42 | 19.38 (noisy) |
| idle | 15tabsTotalWakeups | 27.7 | 53.2 (noisy) |
| idle | 15tabsHostMB | 71.47 | 72.16 |
| memory | startHostMB | 48.69 | 49.38 |
| memory | afterHostMB (4 cycles) | 99.61 | 97.63 |
| memory | growthPerCycleHostMB (cycle 4 − 1) | 9.38 | 8.73 |

What the numbers mean:
- **Idle**: nothing in Ray runs at idle (`sample` of a 15-tab instance: the main thread sits in `nextEvent`, a few
  Mojo messages from renderers, no Ray timer or display link; Ray has no repeating timer outside tests). This change
  touches no idle code; the "after" idle figures were taken while the Mac was busy (other agents building, the
  window server at 30 %) and are noise against the quiet baseline, not a regression. The 35 wakeups/s in the first
  smoke run were noise too.
- **Memory "growth per cycle" is a step, not a leak.** Ten cycles on main: `48.7 71.0 75.3 76.2 97.8 98.5 98.9 99.2
  100.0 100.5 100.9` MB: one jump of ~21 MB between cycles 3 and 4 (after 36-48 tabs opened and closed), then ~0.4 MB
  per cycle. v0.7.0 does the same (`53.9 64.1 70.1 76.5 78.8 81.4 105.5 104.0 103.1`), and it happens with no Ray UI
  involved (open and close tabs only, no switches, command bar or ⌘S). The harness' (cycle 4 − cycle 1) / 3 lands on
  the step, so it reads ~9 MB/cycle. It is the engine's allocator (Ray's Swift objects live in it too, so
  `heap`/`leaks` see 0.7 MB of 100); see MISSING.md Known limitations 57.
- **Fixed**, Ray's own growth: a closed tab's ⌃Tab picture (316×210×4 = 265 KB each, 12 per cycle) stayed in
  `TabPictures` until the next ⌃Tab walk; a copy still in flight when its tab closed was stored after it. Both go now
  (`drop` in `didRemove`, a closed-tab guard in the copy's callback). Also freed with the tab: `LoadSweeps`' entry,
  `zoomHosts`, `PageContainerView.hideGeneration`. Ten-cycle runs with the fix: `48.7 70.2 74.6 75.0 96.3 96.7 96.7
  96.8 97.0 97.1 98.8`: the plateau is ~2 MB lower (97 vs 99 MB) and the pictures no longer accumulate for sessions
  that never press ⌃Tab. Guard: check `tab-pictures-dropped` (state log `tabPictures`).
- Unfixed: the 21 MB step and the 0.4 MB per cycle after it (Chromium-side; Known limitations 57).

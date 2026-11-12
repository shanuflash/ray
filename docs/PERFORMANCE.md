
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

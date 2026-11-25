# Arc behaviour audit: tabs, sidebar, command bar

2026-11-23. How Ray behaves against Arc and against Ardia v0.2.48, one behaviour at a time, to find the small
differences that make Ray not feel exactly like Arc. This is an audit only: no app code changed. Anything UI-shaped
needs a mock and the owner's pick before it is built.

**Sources and how sure each Arc claim is**
- Arc: Arc 1.172.1 is installed (`/Applications/Arc.app`, read only, never launched). Arc's help centre is gone since
  the sunset (resources.arc.net lists 22 articles; the Shortcuts, Command Bar, Pinned Tabs and Archive pages return
  403), so the evidence is:
  - **RN**: Arc's release notes, 2021–2026.
  - **BIN**: strings inside Arc.app (tooltips, menu titles, setting keys).
  - **CRA**: Cra's reverse-engineering notes (`third_party/cra/docs/arc-reverse-engineering.md`), observed live on
    Arc 1.168–1.170.
  - Certainty: **C** certain, **L** likely, **U** unknown. A U row is judged against Ardia's "as in Arc" choice and
    marked as such.
- Ardia: tag v0.2.48 (`6b1bcba`, 2026-11-22), read only. Paths are relative to `apps/browser/src/`. Ardia's defaults
  are Dia's; its `PRESETS.arc` (`state/onboarding/presets.ts:71-93`) is what Ardia calls Arc-like, and both are
  noted where they differ.
- Ray: read from the code at `cb8c275`. The rows marked **probe** were run on a hidden RayTests.app (its own data dir,
  local pages, quit afterwards).
- Research notes with every source line are in the session notes folder: `arc-behaviour-research.md` and
  `ardia-0.2.48-behaviour.md`.

**How to read the tables**
- Verdict: **same**, **differs**, **missing** (Ray has nothing for it), or **bug** (Ray does something no one would
  want).
- Hurt: how much it hurts Arc feel (high, med or low).
- Fix: rough size, from S (an afternoon) to L (a feature).

## Tabs

| Behaviour | Arc | Ardia 0.2.48 | Ray | Verdict | Hurt | Fix | Evidence |
|---|---|---|---|---|---|---|---|
| ⌘T | Opens the command bar; ⌘T or ⌘L again closes it (CRA, C) | Setting: New Tab page (default) or command bar (Arc preset); ⌘T again closes the bar (`state/commands/commands.ts:162`) | Opens the bar; ⌘T again re-presents it (text selected), never closes it | differs | low | S | `BrowserWindowController.swift:2730` |
| Where a ⌘T tab lands | Top of Today (CRA live for routed links; U for ⌘T itself) | `newTabPosition` top / bottom (default) / next to current; Arc preset top | Top of Today; Settings › next to the active tab | same | – | – | probe: d, c, b, a after ⌘T b, c, d |
| ⌘T then Return, nothing typed | U. RN: a URL on the clipboard makes "Paste and Go" the top row | Switches to the **most recently used** other tab (row 0 of the recency list, `components/omnibox/dropdownStart.ts`) | Switches to the **top tab in sidebar order** (favorites, then pinned, then Today), not the one you were just on | differs | med | S | probe: on d, Return went to c; `Suggestions.swift:464` |
| Paste and Go row | URL on the clipboard → "Paste and Go" leads the empty bar; ⌘-hover on + shows it; ⌘⌥V pastes as a new tab (RN, C) | Not found | None; no ⌘⌥V | missing | low | S | `MainMenu.swift` |
| Link with target=_blank from a Today tab | U (Arc stores `referrerID`; Cra puts it under the opener) | Peek by default; with Peek off, a foreground tab right after the opener | Foreground tab right after the opener | same (as Ardia with Peek off) | – | – | probe: order d, opened, c… |
| ⌘-click / middle click on a link | U for placement; BIN has a "background tab" notice | Background tab after the opener's earlier children, "New tab opened" pill; auto-groups by default (Arc preset off) | Background tab right after the opener (so several ⌘-clicks land in reverse order); "Opened in Background Tab" note | differs (order of several) | low | S | `BrowserWindowController.swift:3046`, `:1472` |
| Links from a pinned tab or favorite to another site | Open in **Peek**; with Peek off, a **new tab**; the pinned tab stays home (RN, C) | Peek (`peekLinksToOtherSites`, on) | Navigates the pinned tab itself away (row grows a host line and a slash) | differs | high | S without Peek (open a Today tab), L with Peek | `didInsert` only sees new tabs; same-tab navigations aren't intercepted |
| Sized pop-ups (`window.open` with width/height: OAuth sign-ins) | A small pop-up window (CRA static, L) | Pop-up window; "Open pop-ups as tabs" off by default (`settings.ts:89`) | Becomes a Today tab, active | differs | med | M | probe: tabs 5→6, active /popup; `popupFeatures` unused |
| Links from other apps | Little Arc by default (CRA live, C) | Little Ardia by default | Today tab in the normal window | missing | – | L | MISSING Arc 4 (Little Arc) |
| Tab shown after ⌘W / row ✕ | The tab used before it: certain for pinned tabs, likely for Today (CRA live; RN "improved logic for the next tab") | Most recently used awake, seen tab; sleeping or never-shown tabs only as a last resort (`state/tabs/openers.ts:97-105`) | Nearest live neighbour in sidebar order (below first) | differs | high | S | `BrowserWindowController.swift:1538`; MISSING 63 |
| Closing the last Today tab, pinned tabs left | Window stays, empty card with "Search or Enter URL…" (CRA, C) | Window stays, a blank New Tab is made | Window stays, nothing shown, sidebar forced out; ⌘W again closes the window | same (no centred bar) | low | S | `activateNeighbor` → `showNothing`; MISSING 28 can close: the window stays |
| Back on a tab a link opened (no history) | U (no "Close Tab and Go Back" string found) | Closes the tab and returns to its opener; Back's tooltip is "Close Tab and Go Back" (PR #1401) | Back is disabled; nothing happens | missing | med | S | probe: canGoBack false, Back did nothing; MISSING 64 |
| ⌘-click or middle-click Back / Forward | Goes back or forward in a new tab (RN, C) | Not checked | Plain navigation (only the history list's rows take ⌘-click) | missing | low | S | `PageToolbar.swift:158`, `SidebarView.swift:1574` |
| ⇧⌘T | Reopens with history; ⌘Z also reopens (RN, C) | Original window, index and group, with history | Original place with history; a Today tab returns outside its folder; ⌘Z reopens only with a setting that is **off** by default | differs | low | S | MISSING 30; `SettingsCatalog.swift` `undoReopensClosedTab` default false |
| Pinned tab: navigating within its site | Stays in the tab; the row shows the host as a second line; a click on the icon goes back to the pinned URL (RN, C) | Same; the favicon turns into ↩ on hover; ⌘↩ resets | Same (host line, slash, icon click); Back to Pinned URL has **no key** | differs (no key) | low | S | `SidebarView.swift:2465`; `MainMenu.swift` |
| ⌘-click a pinned tab's icon | Goes to the pinned URL and opens the page it was on in a new tab (RN, C) | Not found | ⌘-click starts a multi-selection | missing | low | S | `SidebarView.swift:1243` |
| Separate From Pinned Tab | Moves the current page to a Today tab and resets the pin (BIN, L) | Not found | None | missing | low | S | – |
| ⌘W on a pinned tab or favorite | Unloads it, keeps it pinned, selects the tab used before, scrolls to it and flashes a dashed ring; the tooltip is "Close and Keep Pinned ⌘W" (CRA live, C) | Unloads it ("Unload Tab ⌘W"), back to the pinned URL | Unloads it, back to the pinned URL, then the nearest neighbour | differs (successor) | med | S | same fix as the close row above |
| Favorites: ⌘1–⌘9 | "Go to Sidebar Item N"; a setting can leave favorites out of the count (RN, C) | Top Apps, then pinned, then the list; ⌘9 last | Favorites, then pinned, then Today (folders skipped); ⌘9 last | same | – | – | `BrowserWindowController.swift:1866` |
| Next / previous tab | ⌥⌘↓ / ⌥⌘↑ (CRA menu read, C) | ⌥⌘↓/↑ and ⇧⌘]/[ | ⇧⌘] / ⇧⌘[ only; skips sleeping tabs | differs | med | S | `MainMenu.swift:111` |
| ⌃Tab | Recent-tab switcher (C) | Steps the list since 0.2.47; switcher has no default key | Arc's switcher | same | – | – | – |
| ⌃Tab after a background tab opened | The new background tab (owner, 2026-11-25; this row first guessed the tab before, from CRA's "last 10 tab switches") | The unseen tab right after its opener, newest first (`recentTabIds`, `state/pins/tabCleanup.ts`) | Same, `switcherOrder` (2026-11-25) | same | – | – | `BrowserWindowController.swift` `// MARK: Tab switcher` |
| Auto-archive of Today | After 12 h (or 24 h, 7 d, 30 d) of not being viewed, **while running**; skips tabs playing media; archived tabs go to the Archive (RN, C) | Off by default (Arc preset 12 h); sweeps every ≤ 30 min; to "Recently Cleaned" with Undo | **Only at launch**, only unloaded tabs, counted from when the tab was last **selected** (not left); archived tabs vanish (no Archive, not in Recently Closed) | differs | med | M | `SidebarModel.swift:265`, called only from `BrowserWindowController.swift:97`; MISSING Arc 5 |
| Clear Today (⇧⌘K) | Archives the unpinned tabs except the selected one ("Clear unselected Today tabs"), skips media, ⌘Z undoes the whole clear (RN/BIN, C) | ⇧⌘K keeps the active and audible tabs | File › Clear Today's Tabs, **no key**, closes the active tab too, no undo for the batch (⇧⌘T brings back one at a time); no Clear button | differs | med | S | `BrowserWindowController.swift:1847`; MISSING Ardia 9 (button) |
| Archive Tabs Below / Above (row menu) | In the tab menu (BIN, RN) | Close Tabs Below / Above (⌥ swaps) | None | missing | low | S | row menus |
| Duplicate | Menu item, keeps history; ⌥-drag a row duplicates it (RN, C) | Right after the source, history kept | Right after the source, history kept; no ⌥-drag | differs (no ⌥-drag) | low | S | `BrowserWindowController.swift:2070` |
| Rename | Double-click; a one-time "Double-click to rename" hint (RN/BIN, C) | Double-click the title | Double-click the title; no hint | differs (hint) | low | S | MISSING 16 |
| Mute | Menu and the row's speaker (C) | Same; ⌥ gives Mute Site | Same | same | – | – | – |
| Multi-select | ⌘-click, ⇧-click, ⌘W closes all, ⇧⌘C copies all, menu (RN/BIN, C) | Same | Same; no Escape to end it | same | – | – | MISSING top priority 1 |
| Middle-click a row | Closes it (L) | Closes it; unloads a pinned one | Closes a Today tab or unloads a live pinned row; **a favorite tile ignores it** | differs (tiles) | low | S | `SidebarView.swift:2355`; `FavoriteTileView` has no `otherMouseDown` |
| ⇧⌘C | Copies the URL with trackers stripped; ⇧⌥⌘C copies as Markdown, ⌃⇧⌘C as a quote (CRA/RN, C) | Strips trackers; ⌥⇧⌘C Markdown | Copies the raw URL; no Markdown or quote copy | differs | low | S | `BrowserWindowController.swift` `copyURL` |
| ⌘N | A new window with its own Today tabs (RN 0.106, C) | New window | Brings the one normal window forward; Ray never has two normal windows | missing | med | L | `AppController.swift:57` |
| Page full screen (YouTube's F, a video's full-screen button) | The video fills the screen; sidebar and toolbar go (C: Chrome behaviour Arc keeps) | Hides the sidebar, strip and side panel for the full-screen tab (`App.tsx:57-77`) | The element goes full screen **inside the page card**: the sidebar and address bar stay, the window doesn't go full screen. Ray doesn't implement the engine's `window:tab:didChangeFullscreen:` | bug | high | M | probe: innerWidth 1085 before and after, `fullscreenElement` set; `ac_window_host_tabs.mm:168`, `ac_browser_window_exclusive_access.mm:31` |

## Sidebar

| Behaviour | Arc | Ardia 0.2.48 | Ray | Verdict | Hurt | Fix | Evidence |
|---|---|---|---|---|---|---|---|
| A click switches on press or release | U (Chrome, Safari switch on press) | Press, for a plain click on a tab that isn't active or selected (`state/sidebar/heldTabPress.ts:76-117`) | **Press** already: `SidebarRowView.mouseDown` calls `onClick` (and the tile's too). MISSING 61 and ARDIA-WATCH 23 say release; they are out of date. A plain click on a selected tab ends the selection at the release | same | – | – | `SidebarView.swift:2341`, `:2080` |
| Double-click a row | Rename (RN, C) | Rename | Rename | same | – | – | – |
| Double-click a favorite | U | Back to Pinned URL | Nothing | differs from Ardia | low | S | – |
| Double-click empty sidebar space | New tab (opens the command bar) (RN, C) | Same | Nothing | missing | med | S | – |
| Drag a row out of the window | A new window with that tab (RN, C) | A drag-out zone 40 pt outside | Nothing (a drop more than 40 pt outside is ignored) | missing | med | L (needs ⌘N's windows) | `SidebarView.swift:960` |
| Drop a link, text or file from a page or Finder into the sidebar | Text makes a search tab; links and files open (RN, C) | Not checked | Nothing: Ray registers no dragged types | missing | med | M | no `registerForDraggedTypes` in `Host/` |
| Drop a tab on a tab | Split View (RN, C) | Split View | – | missing | – | L | MISSING Arc 3 |
| ⌥-drag a row | Duplicates it (RN, C) | Not found | Moves it | missing | low | S | – |
| Drag over a closed folder | Folders **don't** open (RN: "no longer expand when you drag items into them") | No spring-load | Springs open after 0.6 s | differs | low | S (drop the spring) | `SidebarView.swift` `springDelay` |
| Drag between favorites, pinned, Today, folders | Allowed; into favorites a tab goes last (C) | Same, plus Split and profile moves | Same | same | – | – | – |
| Drag the sidebar's edge all the way left | Hides the sidebar (RN, C) | Not checked | Rubber-bands at 240 pt | differs | low | S | `SidebarResize.swift` |
| Hover a Today tab | ✕ (C) | ✕ "Close Tab ⌘W" | ✕ | same | – | – | – |
| Hover the current pinned tab | – "Close and Keep Pinned ⌘W" (CRA live, C) | – "Unload Tab ⌘W" | – (no tooltip) | same (tooltip missing) | low | S | `SidebarView.swift:2476` |
| Hover a pinned tab that isn't current | ✕ "Archive this tab" (BIN, L) | ✕ "Remove Pinned Tab" on a closed row | Nothing on an unloaded pinned row | differs | low | S | `closable` in `SidebarView.swift:2462` |
| Tab hover card (title and full URL) | Tooltips after ~1.6 s (CRA) | A hover card after 800 ms (0.2.47) | Only a pinned tab away from home has a tooltip | differs | low | M (mock first) | – |
| Peek with the sidebar hidden | At the left edge; holding ⌥ also shows it (RN 2021, C) | 3 pt strip; nothing while the app is in the background | 5 pt strip (24 pt past it while active); peeks from a background window; no ⌥ | differs | low | S | MISSING 33 |
| Peek over a full-screen window | Works as windowed (Ardia's notes) | Slides out over a full-screen page (0.2.47-n6) | Not tried | U | – | – | ARDIA-WATCH 33 |
| The active tab scrolled out of view | An overflow indicator, and the list scrolls to the tab on navigation (RN, C) | A pill at the list's edge; a click reveals it | Nothing: switching tabs (⌃Tab, ⌘1–9, Switch to Tab) or a new tab at the top never scrolls the list | missing | med | S (scroll) / M (indicator, mock first) | `scrollToVisible` only in rename and folder motion; MISSING 70 |
| The active tab inside a closed folder | Stays shown under the folder (C) | Same | Same | same | – | – | `SidebarView.swift:651` |
| Keyboard in the sidebar | ⌘. focuses the sidebar; arrows move, collapsed pinned skipped (RN, C) | None | None | missing | low | M | – |
| Row menus | Arc's (partly recovered: Archive Tabs Below, Separate From Pinned Tab, Copy as Markdown) | Ardia's own, larger | Arc's order and words for what Ray has | same, minus the items above | low | S | MISSING 34 |
| Empty-area right-click | U | New Tab, Reopen Closed Tab, New Group, collapse Pinned… | Nothing | missing | low | S | – |
| New tab button | "+" at the bottom of the sidebar; ⌘-hover gives Paste and Go (RN, C) | A "New Tab" row, bottom by default (Arc preset top) | A "New Tab" row under the divider | differs (look-level) | low | – | owner's earlier pick |
| Width | Draggable; double-click resets (RN, C) | 160–400 | 240–480, double-click resets | same | – | – | – |

## Command bar

| Behaviour | Arc | Ardia 0.2.48 | Ray | Verdict | Hurt | Fix | Evidence |
|---|---|---|---|---|---|---|---|
| ⌘L | With the toolbar showing, edits the URL in place; otherwise the bar with the URL prefilled and selected (CRA, C) | The bar prefilled and selected; a click on the address edits in place (0.2.46) | Always the centred bar, prefilled and selected | differs (with the page address bar on) | med | M (mock first) | `BrowserWindowController.swift:2693` |
| ⌘L then Return, address unchanged | Reloads the page (RN, C) | Prefilled bar shows no rows until you edit; Return goes to the address | **Switches to another tab**: the unchanged address counts as nothing typed, so the rows are other open tabs and Return picks the first | bug | high | S | probe: on c, ⌘L Return went to d; `BrowserWindowController.swift:2755` |
| Nothing typed (⌘T) | Suggestions ranked by recent tab switches and engagement (RN/BIN, partial) | Up to 8 most recently used other tabs | Other open tabs in **sidebar order** (up to 10), then most-visited pages to make 5 | differs (order) | med | S | `Suggestions.swift:464` |
| Ranking | Learns which row you pick for what you typed; recent switches, engagement, match, recency, custom names; current page down-ranked (BIN/CRA, C) | Score: match + visits − age + bookmark + open tab − current page | Arc's leading page by word starts and HistoryQuick frecency, then fixed order | differs (no learning) | low | L | CLAUDE.md, command bar |
| Inline completion | Host completion (C) | One word, visited hosts | Visited or often-used hosts, else the registrable domain | same | – | – | – |
| Return | ⌘T: new tab; ⌘L: this tab (C) | Same | Same | same | – | – | – |
| ⇧Return | Instant Links: the top search result (RN, C; an AI feature) | A new window | Same as Return | differs | low | – | left out with Arc Max |
| ⌘Return / ⌥Return | U | ⌘↩ new tab, ⌥↩ Split View, ⇧⌘↩ force a search, ⌃↩ www.…com | Not handled: ⌘↩ does nothing; ⌥↩ falls to the text field (`insertNewlineIgnoringFieldEditor`, not tried) | missing | med | S | `CommandBarView.swift:566` |
| ↑ ↓ | Move through rows (C) | Wrap; put the row in the field | Put the row in the field (Chrome's temporary text) | same | – | – | – |
| Tab | With nothing typed, opens the actions list; site search scopes (RN/BIN, C) | Scope, else accept the completion, else next row | Scope when offered, else next row | differs (empty Tab) | low | S | `CommandBarView.swift` `tabPressed` |
| Escape | Closes (L); a second level U | Undo the arrowing, leave the scope, then close | Undo the arrowing, then close; focus back to the page | same | – | – | – |
| A click on the sidebar while the bar is open | The sidebar takes the click (RN 1.27, C) | Outside click closes the bar | The click only closes the bar; the sidebar doesn't get it | differs | low | S | `CommandBarView.swift:221` |
| Switch to Tab rows | Open tabs as "Switch to Tab" (CRA, C) | Same | Same; never the active tab | same | – | – | – |
| Remove a suggestion | ⌘⌥⌫ or the row's ✕ (RN, C) | Not found | None | missing | low | S | – |
| Actions | Menu commands, Collapse Pinned, View Archive… (RN, C) | Menu commands and its own | Menu commands and Settings rows | same, minus Arc-only features | – | – | – |
| Bar in a new window | A new window opens with the bar in it (RN, C) | – | – (one window) | missing | low | – | with ⌘N |

## What to fix first

**Status (2026-11-23, `fix: arc tab and bar rules`):** 1, 2, 3, 5, 6, 7, 8, 9, 10, 12 and 15 are fixed (8 without a
Back to Pinned URL key; 12 without ⌥↩ Split View). Left: 4 (needs an engine hook), 11, 13, 14 and the bigger items
below; `docs/MISSING.md` Known limitations 73 tracks them. Fixing 3 found that Chrome had been choosing the tab after
every ⌘W: it activates its own pick before Ray hears of the close, so Ray's neighbour rule never ran.

Ranked by hurt × how often it happens ÷ size. Items 1–9 are app-side and small; none needs a mock except where noted.

1. **⌘L then Return switches tabs** (bug). Treat the unchanged address as typed (or show no rows until it is edited, as
   Ardia does) so Return reloads, as Arc's does. S, `BrowserWindowController.swift:2755`. Add a check.
2. **Page full screen stays inside the card** (bug). Implement `window(_:tab:didChangeFullscreen:)`: hide the
   sidebar, toolbar and notes for that tab and take the window full screen (and back), as Chrome and Ardia do. M.
3. **Closing a tab shows its neighbour** (MISSING 63). Go to the tab used before it among awake tabs, a neighbour only
   when none; same for ⌘W on pinned tabs and favorites. S.
4. **Links from pinned tabs and favorites to other sites move the pin away.** Until Peek is decided, open them in a new
   Today tab (Arc's behaviour with Peek off). S–M (needs a navigation hook for same-tab clicks: check what the engine
   offers).
5. **⌃Tab goes to a background tab you never saw** (bug). A background tab's `lastActive` starts unset (or at
   `.distantPast`) until it is shown. S.
6. **⌘T then Return, and the empty bar's order.** List other tabs most recent first (as Arc's recent-switch ranking
   and Ardia do), so Return goes back to the last tab, not the top of the sidebar. S.
7. **The sidebar never scrolls to the active tab** (switching, a new tab at the top, ⌘W's successor). Scroll it into
   view; the overflow indicator is a separate, mock-first item (MISSING 70). S.
8. **Arc's keys:** ⌥⌘↓/↑ next/previous tab, ⇧⌘K Clear Today, ⌘⌥V paste as a new tab, ⇧⌥⌘C copy as Markdown, ⌘Z
   reopens a closed tab on by default, ⌘-click or middle-click on Back/Forward opens a new tab. S each.
9. **Back on a link-opened tab closes it and returns to the opener** (MISSING 64; Ardia's rules: link-opened,
   opener alive, not pinned, no history). S.
10. **Clear Today as Arc's:** keep the selected tab and tabs playing sound, one ⌘Z for the whole clear. S.
11. **Auto-archive while running** (every half hour, from when a tab was last left, skipping media), and keep what it
    archives in Recently Closed until the Archive exists. M.
12. **Command bar Return modifiers:** ⌘↩ opens in a new tab from ⌘L; ⌥↩ waits for Split View; make sure ⌥↩ can't put
    a newline in the field. S.
13. **Sized pop-ups as small windows** (OAuth sign-ins), with Ardia's "Open pop-ups as tabs" as the option. M.
14. **Drops into the sidebar:** links, text (a search tab) and files make tabs where dropped; ⌥-drag duplicates. M.
15. **Double-click on empty sidebar space opens a new tab**; the sidebar takes clicks while the bar is open; ⌘T again
    closes the bar. S each.

Bigger items that also matter to Arc feel but aren't small: several normal windows (⌘N, drag a tab out), ⌘L editing in
the page address bar in place (mock first), Little Arc, Peek, Split View, Spaces (all in `docs/MISSING.md`).

**Docs corrected by this audit:** MISSING 61 (switch on mouse down) describes the code wrongly: rows and tiles already
switch at the press. MISSING 28 (⌘W on the last Today tab with only pinned tabs left) is answered by the code: the
window stays, with nothing shown.

## Everything else Ray is missing now

Outside tabs, sidebar and command bar: `docs/MISSING.md`'s open items plus what Ardia 0.2.47–0.2.48 shipped that Ray
lacks, each with its value for someone leaving Arc. Big ones first.

**Arc features (value for Arc switchers: these are what they used every day)**
- **Spaces** (and per-Space colour or gradient themes): Arc's core organisation; most switchers have several. Highest.
- **Profiles**: work and personal logins side by side, tied to Spaces in Arc.
- **Split View**: used daily by many Arc users; Ardia has it, drag a tab on a tab included.
- **Little Arc / Little Ardia** for links from other apps (⌥⌘N, also from any app in Ardia): Arc's default for every
  link from Slack or Mail.
- **Peek** for links from pinned tabs and favorites (open decision): keeps pinned apps home.
- **Air Traffic Control / link routing** (Ardia 0.2.47: by app or site to a profile, window, Little Ardia or group):
  power users depend on it; their Arc rules import nowhere today.
- **Archive view**: Arc users go back to archived tabs; Ray deletes them.
- **Live Folders** (GitHub, Linear, Notion, Drive) and **Live Calendar**: smaller audience, loved by those who use them.
- **Built-in ad blocker** (open decision): Arc had none built in either; Ardia ships uBlock and custom filter lists.
- **Boosts**, **Capture**, **Easels / Notes / Library**: niche; Boosts matter to a vocal few.
- **Collapse the pinned section**; **sidebar on the right**; **media controls in the sidebar**; **unread counts** on
  pinned web apps; **sync between Macs**: small, each a habit for some.
- **Developer bar on localhost** (Arc's striped bar; Ardia 0.2.47-n8): developers notice it at once.

**From Ardia 0.2.47 / 0.2.48 (and earlier Ardia settings)**
- **Reader mode** (⌥⌘R): Arc had none; a nice extra, not a switching need.
- **Hide Element** (⇧⌘H, per site, with a list to restore): Arc's Boost "zap" did this; Boost users will look for it.
- **Minimalism mode** (⌃⌘M) and **Interface Size** (80–150 %): accessibility and focus; Interface Size helps on small
  or large screens.
- **Open pop-ups as tabs** as a setting (Ray only does tabs today; windows should be the default).
- **Custom new-tab address**: matters only to people who used a start page; Arc had none.
- **Tab hover card** (title, full URL): Arc showed tooltips; low.
- **Mouse-button shortcuts** (middle and buttons 4–5 to any command): mouse users expect back/forward buttons to work;
  check Ray's buttons 4–5 first.
- **Sleep a tab from its menu**, **Memory Saver** settings (Moderate / Balanced / Maximum, keep-active sites): Arc had
  tab sleeping; Ray sleeps nothing at all (MISSING 11).
- **Battery saver**, **compact toolbar**, **hide the address bar while scrolling**, **new tabs at the bottom**: small.
- **Block autoplay / notification requests everywhere**, Autoplay in Site controls: privacy-minded users ask.
- **Plugins and a command-line tool**, **Linux / Windows builds**, **WebKit per page**, **FairPlay streaming**:
  Ardia's direction, not Arc parity; skip unless the owner wants them.

**Chrome features not wired**
- **Device pickers** (WebUSB, Bluetooth, HID, Serial): needed for hardware keys and some dev tools; requests get
  nothing today.
- **Cast**; **extension side panels and extension keyboard shortcuts**; **install imported extensions by Web Store
  id**; **drop a .crx**, **user scripts** (Tampermonkey); **Share from the page menu**; **web notifications not
  checked**: extension shortcuts and side panels hit extension-heavy switchers first.
- **Swipe-and-hold history list** (Dia's): small.

**Engine and platform**
- **Engine two milestones behind** (Chromium 156; Chrome stable 158, Ardia on 158): the security gap is the biggest
  risk for anyone switching now.
- **Keep history past 90 days** (one launch argument): imported Arc history is deleted on the next expiry pass. Do
  this before the Arc shutdown wave.
- **Google Endpoint Verification**, **pages blank under a same-size window**, **blank page after a Space switch**,
  **Meet presenter preview**, **upscaling in a shared tab**: each bites a specific group (Workspace users, Meet users).

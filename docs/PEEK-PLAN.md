# Peek: plan for the owner's decision

Peek is Arc's preview of a link: a card floats over the dimmed page, and you either close it (the page under it
hasn't moved) or open it fully as a tab. PLAN.md's "Open decisions" asks whether to bring back Ardia's engine hook
or build Peek on plain tabs. This plan answers that from three working implementations and from Ray's own engine.
Researched 2026-11-24 against Ray 0.11.0 (engine v0.2.48, Chromium 158).

**Recommendation in one line:** build Peek on plain tabs (Ray-only, ships in the next app build), then add one small
RayCore-only fixup (0012) for the click Arc peeks most, a plain click from a pinned tab or favorite to another site.
Don't bring back Ardia's hook: it isn't what makes Ardia's Peek work, and Ray doesn't need it.

## What Arc does (the target)

- **Shift-click on a link**, in any tab: opens Peek. ⌘-click (background tab) and ⌘⇧-click keep their meanings.
- **A plain click on a link to another site from a pinned tab or favorite**: opens Peek, so the pinned app stays
  home. A link to the same site navigates the pinned tab as usual. Today tabs navigate in place.
- **What the card offers:** close (✕, Escape, or a click on the dimmed page: the source page is unchanged), open as
  a tab (the live page moves to the top of Today, history and scroll kept; ⌘O), and open in Split View.
- **Settings › Links:** "Shift-click a link to open it in Peek" and "Open links to other sites in Peek (only affects
  Favorites and Pinned tabs)". Arc's own defaults weren't captured by anyone; all three references default both on.
- **Look** (Open Arc's measured capture, 1920 × 985 window): the card spans the window's height minus 12 pt above
  and 13 pt below, about 80 % of the page's width, its centre 4.5 pt right of the page's; the page behind shrinks
  about 9.5 pt on every side and dims; three 34 × 33 round buttons in a column 13 pt right of the card (close,
  expand, split), 44 pt apart. The address field shows the Peek page's host while it's open; the source favorite
  gets a small badge.

## How each reference does it

### Open Arc (Chromium, own embedder; `chromium-patches/157/0031-…Peek.patch`, `app/Sources/OpenArcShell/LinkPeek/`)

**Engine (532-line patch, all in its own embedder dir, no Chromium file touched).**
- `openarc::LinkPreviewPolicy`, a `WebContentsUserData` holding the tab's triggers (`OtherSite`, `ShiftClick`) and a
  callback. `OACTab (OACLinkPreview)` exposes `linkPreviewTriggers` (none by default).
- **Other site:** `OpenArcContentBrowserClient::CreateThrottlesForNavigation` adds `LinkPreviewNavigationThrottle`
  for primary-main-frame navigations of tabs with the trigger. `WillStartRequest` lets through anything that isn't
  a renderer-initiated, user-gesture link click (`WasInitiatedByLinkClick`, `PAGE_TRANSITION_LINK`), a POST or a
  non-http(s) URL; it reads the page's site from the engine (`GetPrimaryMainFrame()->GetLastCommittedOrigin()`,
  http(s) only, not opaque) and compares registrable domains (`SameDomainOrHost`, private registries included). A
  different site is reported and cancelled with `CANCEL_AND_IGNORE` (no request, no history entry, no error page).
- **Shift-click:** in the tab's `OpenURLFromTab`, a renderer-initiated user-gesture `NEW_WINDOW` link (Blink's
  Shift-click) to http(s), no POST, is reported and dropped (returns nullptr).
- The delegate hears `-tab:didInterceptLinkToURL:trigger:` from a posted task, never re-entrantly.

**Shell (SwiftUI, ~800 lines).** `LinkPeekModel`, one per window: on the report it makes a new engine tab on the
*URL* (the source's profile and colour scheme), with no sidebar entry until expanded. A second Peek replaces the
first; choosing another tab or Space closes it; `window.close()` in the Peek closes it. Expand (⤢, ⌘O) adopts the
live engine tab as a new top Today tab (no reload); split makes a split row (copy of the source left, Peek right).
Tabs the Peek page opens are handled as if the source asked. B196: a `target=_blank` / `window.open` to another
site from a pinned tab also opens in Peek. Escape and ⌘O are caught by a local key monitor. A tab on no screen
loads the link itself. Triggers are re-sent to each live tab when a tab is pinned/unpinned or a switch changes.

**Weak spots.** The re-made tab loads the URL fresh: the original initiator, referrer and `Sec-Fetch-Site` are lost,
so the request goes out as browser-initiated (SameSite=Strict cookies now sent; see Security). No auth exclusions.

### Ardia (Ray's source; `packages/ardiacore/ios/ArdiaWebView+Peek.mm`, `page_script.js`, `apps/browser/src/state/peek/`, `packages/shell/ios/PeekStage*.swift`)

**Click capture is in the page script, not the engine.** `page_script.js` listens for clicks in every frame,
finds the link through `composedPath()` (with cached prototype getters so the page can't spoof them), skips
`download` links, editable content and non-http(s), and for the chosen modifier (Shift, ⌥ or off), or a plain
click leaving the host in a tab marked `otherSites`, calls `preventDefault` and posts `peekLink`. Native
(`peekLink:frame:main:`) only trusts it against real input: a left mouse-up over that page view, within 10 s, with
exactly the matching modifiers, not used before, no press since (a local `NSEvent` monitor records them). If it
refuses, it sends `peekRefused` and the page re-clicks the link itself (or downloads it, or opens a new
window/background tab as the click would have).

**The engine part is only the "temporary" tab.** The Peek page is a normal tab flagged `temporary` with
`temporarySource` (its own hidden window, "ownWindow"). `chromium-temporary-tab-restore-hook.patch` patches
`components/sessions/core/tab_restore_service_helper.cc`: a function pointer `g_ardia_live_tab_skips_restore`
(set in `ac_seams.mm` to `LiveTabSkipsRestore`) makes `PopulateTab` record no navigations for temporary tabs (and
automation windows), so they never reach Chrome's Recently Closed, and fixes a window entry's selected index to the
Peek's source. That hook is what Ray dropped (`engine-ray/drop-patches.txt`, fixup 0003 removes its setter);
`RayCore.h` still has `temporary` and `setTemporarySource:`, which do nothing without it.

**UI.** `PeekStage` (native, Core Animation) grows a card from the click point, the page drawn at tab size and
scaled (`peekGeometry.ts`: 5.5 % inset, at least 16 pt), a scrim, pinch to expand, spring motion and an optional
mesh warp; a small bar "Peek: <host>" with buttons (open as tab, Split View when it fits). Settings:
`peekModifier` (shift), `peekLinksToOtherSites` (on), `newTabLinksOpenIn` (tab, peek or Little Ardia: Ardia's
default is Peek for `target=_blank`), `peekButtons` placement. "Landing": a peeked link that lands back on the
source's host within 8 s (a link wrapper such as an `l.facebook.com` redirect) closes Peek and navigates the source
(or opens a tab). A haptic tick on first load. No auth exclusions.

**Why Ray can't copy it.** PLAN.md decided "Page script: our own, minimal. No Peek … messages", and for good reason:
the page script cancels the click before the native side decides, so a refusal re-clicks from script (a second
synthetic click the page can observe), and the whole thing is a few hundred lines of page-facing JavaScript plus a
global event monitor to tell real clicks from fakes.

### Circa (CEF 158, AppKit; `native/Sources/Orbit/Peek/`)

**Engine side is CEF's own hooks**, wrapped as `routeNavigations` (CEF's before-browse, can cancel) and
`routeNewTargets` (before-popup, hands over the new surface with its opener and original request).

**Routing is one pure function, `BrowserPeekRouting.decide`**, fed by engine metadata
(`BrowserNavigationMetadata`: link activation vs form/redirect/back-forward/reload/script, method, body):
- only http(s) with a host, no `user:pass@`, main frame, left button, a user link activation (unknown metadata never
  peeks); a navigation (not a new target) only if it's a GET without body, since it gets replayed;
- **excluded for every trigger, Shift included:** meeting links (`meet.google.com`, Zoom `/j/ /my/ /wc/ /s/`,
  Teams, Around) and **authentication flows** (`isAuthenticationFlow`): a first host label of `auth`, `accounts`,
  `login`, `signin`, `identity`, `sso`, `oauth`; a path starting `/oauth`, `/o/oauth2`, `/saml`, `/sso`,
  `/login/oauth`; or a query with both `client_id=` and `redirect_uri=`;
- Shift alone → Peek; no modifiers + pinned/favorite + a different registrable domain (Public Suffix List, private
  section) → Peek; a pinned tab whose home is on another site already doesn't peek.

A cancelled navigation is **re-opened from the source document** (`reopenLinkFromDocument`, "NAV-INITIATOR") so
the request keeps its initiator, falling back to opening by URL. The Peek owns a real surface; Open as Tab and
Open in Split hand the live surface over (`BrowserPeekTransfer`, refused transfers go back to Peek, no reload).
UI: a full-window overlay (clear scrim as a hit shield; the content card dims and recedes), the card with its own
toolbar (back, forward, reload), springs for present/dismiss/promote, a crossfade with Reduce Motion. Escape
(unless a text field is editing) and ⌘W close the Peek, not the tab; back/forward/reload/copy URL act on the Peek
when it has focus; find and zoom follow it; the command bar or address field editing closes it; permission requests
from the Peek page are decided as this window's.

### Side by side

| | Open Arc | Ardia | Circa |
|---|---|---|---|
| Shift-click | engine: `OpenURLFromTab` drops `NEW_WINDOW` | page script + mouse-up check | CEF new target, Shift |
| Pinned → other site | engine: navigation throttle, cancel | page script, `otherSites` | CEF before-browse, cancel + reopen |
| `_blank` from pinned → other site | shell (B196) | shell (`newTabLinkRoute`) | CEF new target |
| Site test | registrable domain, engine's committed origin | host minus `www.`, page's `location` | registrable domain (PSL) |
| Request kept (initiator, referrer) | no: reloads by URL | yes for refusals (re-click) | yes: reopened from the document |
| Auth / meeting links excluded | no | no | yes |
| Peek tab out of Recently Closed | n/a (own embedder) | Chromium-layer hook | n/a (CEF) |
| Expand keeps the live page | yes | yes | yes |

## What Ray already has

- **Shift-click already reaches Ray as its own disposition.** Chrome turns a Shift-click into `kNewWindow`;
  `ACWebContentsDelegate::OpenURLFromTab` opens it as a tab and `window:didInsertTab:opener:disposition:` reports
  `"window"` (`ac_browser.mm` `DispositionName`) with the opener. Ray's `didInsert` makes a Today tab of it today.
  `target=_blank` arrives as `"foreground_tab"` with its opener. So both of these can become Peek **with no engine
  change**, and the tab keeps the page's original request (initiator, referrer, opener).
- **Sized pop-ups (OAuth sign-ins) are already never tabs**: disposition `"popup"` goes to `PopupWindow`.
- **A tab can live in its own hidden `RayCoreWindow` and lend its view**: `LittleRay` and `PopupWindow` do exactly
  that, and `adoptFromPopup` moves a live page into the main window as a Today tab with its history (Open as Tab).
- **Engine origin:** `RayCoreTab.committedOrigin` is the engine's committed origin of the opener.
- **Restore list:** Ray's ⇧⌘T takes only tabs it tagged (`ac_tab_restore_tag` / `ac_tab_restore_take`), but any
  closed tab with history lands in Chrome's TabRestoreService (`-close` passes `CLOSE_CREATE_HISTORICAL_TAB`), which
  keeps 25 entries: a run of dismissed Peeks would push out the tabs ⇧⌘T should bring back, and they'd show in
  chrome://history's Recently closed and `chrome.sessions`. `ac_tab_restore_take` with `keep: false` removes a tagged
  entry, and RayCore already has the no-record path (`DeleteTabClosedByHost(…, ClosedTabRecord::kNone)`, used by
  `unloadKeepingHistory`).
- **What's missing:** a plain click that would navigate the tab itself is invisible to Ray until it commits
  (docs/ARC-BEHAVIOUR-AUDIT.md row "Links from a pinned tab or favorite to another site": "needs an engine hook for
  same-tab link navigations (none in `RayCore.h`)"). That is the only part that needs the engine.

## Engine: fixup 0012 (RayCore only)

`engine-ray/fixups/0012-link-preview-throttle.patch`, a patch on `engine/raycore/` only (Ray's own layer, like 0008
and 0009). No Chromium source file and no series patch. `tools/engine/sync-engine.sh` applies it on every sync, so
it survives Ardia bumps as long as `ac_main_delegate.cc`'s `CreateThrottlesForNavigation` and `ac_browser.mm`'s
pending-open code keep their shape.

**Files.**
- `raycore/src/ray/core/ac_link_preview.{h,mm}` (new, ~180 lines): `raycore::LinkPreviewPolicy`
  (`WebContentsUserData`: `bool other_site`) and `LinkPreviewThrottle`.
- `raycore/src/ray/core/ac_main_delegate.cc`: one line in `CreateThrottlesForNavigation`, after
  `MaybeAddNavigationHoldThrottle`: `MaybeAddLinkPreviewThrottle(registry);` (added only for a primary-main-frame
  navigation of a tab whose policy is on, so every other navigation pays nothing).
- `raycore/src/ray/core/raycore_tab.mm` + `public/RayCore.h`: the property, and `-close` closing a `temporary` tab
  with `ClosedTabRecord::kNone` (also `closeNow`).
- `raycore/src/ray/core/ac_browser.mm`: `"peek"` as the reported disposition for a tab opened by the throttle (a
  flag on the pending open, `TabBridge::set_open`, since `WindowOpenDisposition` has no such value).
- The raycore BUILD.gn `sources` list.

**The throttle, outlined.**

```cpp
ThrottleCheckResult LinkPreviewThrottle::WillStartRequest() {
  NavigationHandle* nav = navigation_handle();
  WebContents* contents = nav->GetWebContents();
  auto* policy = LinkPreviewPolicy::FromWebContents(contents);
  if (!policy || !policy->other_site()) return PROCEED;            // switched off since it was added
  if (!nav->IsInPrimaryMainFrame() || !nav->IsRendererInitiated() ||
      !nav->WasInitiatedByLinkClick() || !nav->HasUserGesture() || nav->IsPost() ||
      !ui::PageTransitionCoreTypeIs(nav->GetPageTransition(), ui::PAGE_TRANSITION_LINK) ||
      !nav->GetURL().SchemeIsHTTPOrHTTPS())
    return PROCEED;                                                // forms, scripts, redirects, reloads, history
  const url::Origin& page = contents->GetPrimaryMainFrame()->GetLastCommittedOrigin();  // engine's, never the page's
  if (page.opaque() || !(page.scheme() == "http" || page.scheme() == "https")) return PROCEED;
  if (net::registry_controlled_domains::SameDomainOrHost(nav->GetURL(), page, INCLUDE_PRIVATE_REGISTRIES))
    return PROCEED;
  // Ask Ray (auth flows, meeting links, JumpCloud, settings), on the next run-loop turn, never re-entrantly.
  PostAsk(weak_this, nav->GetURL());   // calls -tab:shouldPeekLinkToURL:decision:, 1 s deadline → Resume()
  return DEFER;
}
// decision(YES): CancelDeferredNavigation(CANCEL_AND_IGNORE), then post OpenPeek(): source->OpenURL with
//   url, referrer, initiator_origin, initiator_frame_token + process id, PAGE_TRANSITION_LINK,
//   is_renderer_initiated = true, user_gesture = true, disposition kNewForegroundTab, pending open marked "peek".
// decision(NO) or no answer: Resume().
```

Two choices that differ from Open Arc, both on purpose:
- **The engine re-opens the request from the source**, keeping initiator and referrer (Circa's "NAV-INITIATOR"),
  instead of Ray loading the URL in a fresh tab: a fresh browser-initiated load would send SameSite=Strict cookies
  that the cross-site click never would.
- **Ray decides, the engine only filters.** `DEFER` plus one delegate question keeps all policy in Swift (which
  tabs, the settings, the exclusions below), testable with the test commands, and the engine part small and fixed.
  One main-loop hop before the request starts; if Ray doesn't answer in 1 s the navigation goes on as before.

**RayCore.h.**

```objc
@interface RayCoreTab (LinkPreview)
/// Plain clicks on links to another site (registrable domain) are asked about before they leave. NO by default.
@property(nonatomic) BOOL peeksLinksToOtherSites;
@end

@protocol RayCoreTabDelegate <NSObject>
@optional
/// On the main thread from a posted task. Call `decision` once: YES cancels the click in this tab and opens it
/// as a new tab with disposition "peek" (window:didInsertTab:opener:disposition:); NO lets the tab navigate.
- (void)tab:(RayCoreTab*)tab
    shouldPeekLinkToURL:(NSString*)url
               decision:(void (^)(BOOL peek))decision;
@end
```

It's `@optional`, so per CLAUDE.md a near-miss Swift name only warns: treat that warning as an error. The existing
`temporary` property becomes useful again without the Chromium-layer hook: a temporary tab closes with no restore
entry.

**Build.** RayCore objects plus the framework relink: per CLAUDE.md, run raycore's `apply.sh` under
`scripts/locked chromium` on the prepared tree, then step 5 (`05-build.sh`) incrementally. No step 1/3/4 and no
`gclient sync`; never clean the cache. Expect one incremental build per iteration, not the multi-hour full build.

## Ray's side

### Routing (`Host/Peek.swift`, `PeekRouting`, pure and unit-tested)

`decide(trigger, sourceRole, openerOrigin, url) -> peek | tab | inPlace`, Circa's shape:
- **Triggers:** `shiftClick` (`didInsert` with `"window"` and an opener), `newTarget` (`"foreground_tab"` from a
  pinned tab or favorite whose committed origin is another site than the URL), `otherSite` (the fixup's question).
  ⌘-click (`"background_tab"`), ⌘⇧-click and pop-ups keep their current handling.
- **Never Peek:** anything not http(s) (Peek never sees `javascript:`, `data:`, `file:`, app schemes; the engine
  already sends app URLs to `tab:didRequestAppURL:`), `user:pass@` URLs, private-window rules unchanged (the Peek
  uses the source's profile), Circa's meeting links, **authentication flows** (Circa's list above, plus
  `JumpCloudLogin.match` so the relay still sees a normal tab, plus any host Ray currently has a `PopupWindow` open
  for, which is a sign-in in progress), and a source with no `committedOrigin`.
- Excluded clicks: a Shift-click or `_blank` becomes a Today tab as today; an `otherSite` click navigates in place
  (`decision(NO)`), so a pinned app's "Sign in with Google" works as in Chrome.
- Sides are compared only on engine values: `opener.committedOrigin` (or the throttle's own committed origin) and
  the URL the engine reports. Nothing a page says about itself is read.

### The card (`PeekController`, one per window; `BrowserWindowController` `// MARK: Peek`)

- **The tab:** moved into the controller's own hidden `RayCoreWindow` with `adoptTab` (PopupWindow's way), marked
  `temporary` with `setTemporarySource:` the source tab, `noteShown(byHost: true)`. It never gets a `SidebarEntry`,
  so Today, folders, tab groups (`TabGroupSync`) and ⌃Tab don't see it. One Peek per window; a new one replaces it.
- **Where:** a `PeekView` in the window's root above the page card and toolbar, **below `floating`** (a peeking
  sidebar covers it, Ray's subview rule), Panels and notes above it. The source page stays attached and visible
  (never hide a page on screen: Chrome drops its compositor) under a dim layer; `PageContainerView` isn't asked to
  show a second page.
- **Look:** the owner's pick of `docs/mocks/peek.html` (A Arc's layout, recommended; B Ardia's bar; C A with back/forward), offering Arc's measured layout (Open Arc's numbers
  above, buttons in a column right of the card) against Ardia's (a bar on the card). Surfaces as Ray's own:
  `SurfaceBackdrop` shadow and edge, the profile colour for nothing but focus rings, `HoverIconButton.make` for the
  buttons (VoiceOver names "Close", "Open as Tab", later "Open in Split View"). The address shown on the card goes
  through `AddressInput.addressParts` (host leads; `user:pass@` hidden). The sidebar's address field shows the
  Peek's host while it's open, the source row a small badge.
- **Motion:** grows from the clicked link's spot for `otherSite` (the throttle can't know the point, so from the
  source row's area or the card's centre otherwise) on the sidebar's spring (`Spring.caAnimation`, 0.26 s, 0.86),
  out in 140 ms like Panels; a crossfade only with Reduce Motion. Layers, not timers.
- **Closing:** ✕, Escape, a click on the dimmed page, ⌘W, a tab switch, a Space or window change, the command bar
  opening, the Peek page's `window.close()`. Close = `tab.close()` on a temporary tab (fixup 0012: no restore entry).
  Before 0012: tag the tab (`ac_tab_restore_tag`, key `peek:<uuid>`) and after the close `ac_tab_restore_take`
  with `keep: false`, which removes that entry.
- **Open as Tab (⌘O, the button):** `adoptFromPopup(tab, after: source, foreground: true)` and
  `temporary = NO`: the live page, history, scroll and form state kept. Arc puts it at the top of Today; Ray's
  rule so far (Little Ray) is the top of Today too. Split View waits for Split View.
- **What the Peek page opens:** tabs go to the main window after the source (`popupAdoptions`, as Little Ray),
  pop-ups get `PopupWindow`s, downloads go to the profile's list (if the Peek's own navigation turns into a download,
  the Peek closes and the download note shows). A Peek link that lands back on the source's site within 8 s
  (Ardia's "landing", link wrappers) closes the Peek and navigates the source.
- **Prompts from the Peek page:** permissions, password and address saves, page questions and the share picker are
  window-delegate calls; the Peek's `RayCoreWindow` delegate forwards them to the owner controller, which shows them
  over the Peek card (it's their tab). This is the gap `PopupWindow` still has (MISSING Known limitations 73): fix
  both with one forwarding helper. Until then the Peek denies permission requests (deny by default is the safe side).
- **Settings:** two catalog entries in Settings › Tabs, Arc's words: "Shift-click a link to open it in Peek"
  (`peekShiftClick`, on) and "Open links to other sites in Peek" with the grey line "Only affects Favorites and
  Pinned tabs" (`peekOtherSites`, on). `observe` both; on a change, and when a tab is pinned, unpinned, made a
  favorite or bound, set `tab.peeksLinksToOtherSites` (pinned/favorite and the setting on).
- **State log and tests:** state log `peek` (`open`, `trigger`, `frame`, `steps`, `lastClosedBy`, `excluded`), test
  command `peek open <url>|close|escape|astab|click <x> <y>`; checks `peek-shift-click`, `peek-pinned-other-site`
  (same site stays in place, other site peeks, pinned tab's URL unchanged), `peek-new-target`, `peek-open-as-tab`
  (history kept, no reload), `peek-not-recently-closed`, `peek-auth-excluded`, `peek-javascript-never`,
  `peek-prompts`. New entries in `tests/affected.mjs` for `Host/Peek.swift` and the MARK.

### Key routing

The Peek page is the first responder while the card is open, and its key events reach the Peek's own
`RayCoreWindow` delegate (`preHandleKeyEvent` / `handleKeyEvent`), which the controller answers:
- **Escape:** in `handleKeyEvent` (the page didn't use it), as Little Ray does; a page that eats Escape (a video in
  full screen, a modal) keeps it, and the card's ✕ and the dimmed page still close.
- **⌘W:** reserved (`preHandleKeyEvent`), closes the Peek, never the source tab (Circa, Arc).
- **⌘O:** Open as Tab; the Little Ray menu item "Open in Ray" becomes "Open Little Ray or Peek in Ray" as Arc names it.
- **Back, forward, reload, find, zoom, ⇧⌘C** act on the Peek page while it has focus (Circa's `pageCommandSurface`).
- **⌘T, ⌘L, ⌃Tab** close the Peek first, then do their thing. Every other key goes to the main menu as now.
- The swipe indicator follows the Peek page (`ChromeSwipeHook` is global; the indicator's clip view moves to the
  card while it's open).

## Security

- **The engine's origin, never the page's.** Same-site is decided from `GetLastCommittedOrigin()` in the throttle
  and `committedOrigin` in Ray; the URL is the engine's `NavigationHandle` URL or the inserted tab's. No page
  script, no page message, nothing a page reports is read (unlike Ardia's `location`-based test).
- **Never `javascript:`** (or any non-http(s) scheme): the throttle and `PeekRouting` both refuse it, and Open as
  Tab adopts the live tab, never re-loads a URL string.
- **Only real user link clicks:** `WasInitiatedByLinkClick`, `HasUserGesture`, renderer-initiated, `PAGE_TRANSITION_LINK`,
  GET, primary main frame. Scripted navigations, forms, redirects, reloads and history moves never peek.
- **The request keeps its initiator and referrer** (re-opened from the source), so SameSite and `Sec-Fetch-*`
  are what the click would have sent: a page can't turn a cross-site click into a first-party request.
- **Auth flows excluded** (Circa's rules, `JumpCloudLogin`, open sign-in pop-ups); sized pop-ups were never tabs.
  A page can't push a sign-in into a Peek where the relay and the prompts don't follow.
- **Prompts** from the Peek show over the Peek only, with the full origin, deny by default, 0.5 s dead buttons, as
  every prompt (the security checklist); until forwarding lands, the Peek denies.
- **Private windows:** the Peek uses the source's profile; a private Peek never writes Settings.json or restore
  entries (the TabRestoreService is the normal profile's anyway).
- **Logs:** URLs only in test builds' state log, never `NSLog` in normal runs.
- **Deadline:** an unanswered question resumes the navigation after 1 s, so a hang in Ray never strands a click.

## Effort and shipping

| Step | What | Size | Needs an engine build |
|---|---|---|---|
| 0 | Mock `docs/mocks/peek.html` (Arc's layout vs Ardia's bar), owner's pick | ½ day | no |
| 1 | Peek on plain tabs: Shift-click, `_blank` from pinned/favorites, card, Open as Tab, closing, keys, settings, restore-list cleanup by tag, checks, docs | 3–4 days | **no** (app only, next release) |
| 2 | Fixup 0012: throttle, `peeksLinksToOtherSites`, the question, `"peek"` disposition, temporary tabs closed without a record; Ray's `otherSite` routing and its checks | 1½–2 days, plus incremental builds | **yes, incremental**: raycore `apply.sh` + `05-build.sh`, no full rebuild |
| 3 | Prompt forwarding for Peek and `PopupWindow` together | 1 day | no |
| later | Open in Split View, once Split View lands | ½ day | no |

Step 1 alone already gives Arc's Shift-click Peek and keeps `target=_blank` links from pinned apps out of Today. Step
2 is what keeps pinned apps home on plain clicks (Arc behaviour audit's #4). Both fit well before 2026-12-22.

## Recommendation: plain tabs, plus a RayCore-only fixup; not Ardia's hook

- **Ardia's hook isn't Ardia's Peek.** `chromium-temporary-tab-restore-hook.patch` only keeps temporary tabs out of
  Chrome's Recently Closed (and fixes a window entry's selected index). The clicks come from Ardia's page script,
  which PLAN.md ruled out. Restoring the hook would bring back a Chromium-layer patch in `components/sessions` (a
  series patch, the messier kind of engine change: re-added by hand under the lock, outside `apply.sh`'s layers) to
  solve something Ray can do in RayCore (`ClosedTabRecord::kNone`) or even with today's `ac_tab_restore_take`.
- **Plain tabs are already most of it.** Shift-click and `_blank` arrive as `didInsert` dispositions with their
  opener and original request; Little Ray and pop-up windows already host a live tab in their own `RayCoreWindow`
  and hand it to Today with history. Step 1 ships in an app-only release.
- **The one real engine need is small and Ray's own.** The pinned-tab click needs a navigation throttle, which is
  Open Arc's proven design (~200 lines, no Chromium file), done in RayCore where Ray already adds three throttles,
  with Circa's two improvements: the request re-opened from the source, and Ray deciding with auth flows excluded.

Decision for the owner: approve step 0's mock and steps 1–2, and change PLAN.md's Peek rows ("Peek: No", "Page
script: … No Peek … messages" stays true: this plan sends nothing through the page script).

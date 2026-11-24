# Boosts: plan

Arc's Boosts for Ray: per-site colours, fonts, text size and case, custom CSS and JavaScript, and Zap to remove page
elements. This is the plan and the questions for the owner; the look is in `docs/mocks/boosts.html` (pick one option
per row). No app code until the owner picks. Written 2026-11-24 in a cloud session (no Mac build), after Spaces,
Profiles, app icons, Split View, Air Traffic Control and Peek in the owner's order.

Weighed against PLAN.md's goal: Boosts are niche (ARC-BEHAVIOUR-AUDIT: "Boosts matter to a vocal few") but they are
the Arc feature Arc refugees name when asked what Chrome lacks, and Zap ("Hide Element") is the part most people
used. They must not cost page loads anything for people with no Boosts, and must not let one site's page reach
another site's Boost.

## 1. What the references do

| | Boosts? | How it injects | Notes |
|---|---|---|---|
| **Arc** | Yes | Each Boost was a local, unpacked Chrome extension (a `manifest.json`, `content.js`, `styles.css`), which is why Arc's code Boosts behaved exactly like content scripts | Entry points (Open Arc's observations of Arc 1.x): the brush in the URL bar's Site Control Center (its capture row has New Boost; its "⋯" has Manage Boosts…), the sidebar's "+" › New Boost, Window › View Boosts… and the command bar's "View Boosts…" (Library › Boosts; empty state "Nothing Boosted Yet! Click [brush] in URL bar to make your own, or grab one from the Boost Gallery."). The editor is a narrow floating column over the page's right side: colour wheel (centre is the site's own colours), invert lightness, contrast/brightness, a grid of "Aa" fonts, text size, text case, Zap, Code. Zap: hover outlines an element, click hides it, "zap all related" hides its kind, a list of zapped elements to bring back. Code opened a separate editor window with the Boost's files. Site Control Center listed the site's Boosts with on/off switches. Sharing went through Arc's Boost Gallery (arc.net links); Boosts with JavaScript could not be shared. All of that service goes away with Arc |
| **Circa** (`third_party/circa`, MIT) | Yes, the most complete open one | **A new engine hook.** `ACRBoostsReplace(profile, json, revision)` sends a whole per-profile snapshot to the browser, which pushes it over mojo to every renderer; `orbit_boost_renderer.cc` inserts each matching Boost's CSS at document start as a **user-origin** stylesheet (`InsertStyleSheet(…, kUser)`, replaced in one task on update, so edits show with no reload) and runs its JS once per document in **its own isolated world** with CSP `default-src 'none'; script-src 'unsafe-eval'; connect-src 'none'`. Only http(s), never opaque origins | Model (`BrowserBoost.swift`): host pattern (exact ASCII host, optional subdomains, https only unless widened, default port), colour scheme (hue, saturation, invert, contrast, brightness), font, text zoom 0.25–5, text case, zap selectors, custom CSS and JS; **JS needs a device-local opt-in that sync and migration never carry**. Compiler escapes the font name as CSS hex escapes and checks every zap selector lexically (no `{};@`, no comments, balanced brackets). Limits: 256 Boosts, 64 KB per source, 2 MB in all. One store per profile (`boosts.json`), memory-only in private windows. Zap's picker evaluates script in the page only to inspect; what it saves goes through the registry. Library › Boosts, Site controls, a 183×588 editor, AI-generated CSS/JS staged for review |
| **Ardia** (`v0.2.48`) | No | — | Loads component extensions from the app bundle (`loadComponentExtension:` for its uBlock Origin Lite reader), the same call Ray's engine has |
| **Phi** (`phibrowser-mac`) | No | — | WKUserScript only in its own account/extension web views |
| **Open Arc** | No (README: "Not included") | — | Its Site Control Center and Library carry Arc's Boost entry points as inert items, with Arc's wording (quoted above) |
| **Crest, Cra** | No | — | — |

## 2. How Ray could inject

Ray's engine today (`engine/raycore/src/ray/core/public/RayCore.h`, `engine/chromium/src/chrome/browser/ray/ac_*.cc`):

- `RayCoreEngine.pageScript`: one script for every frame, run in the **main world** (`ac_content_renderer_client.cc`,
  `ISOLATED_WORLD_ID_GLOBAL`), the same text in every renderer.
- `RayCoreTab.executeJavaScript:frame:` / `evaluate:completion:`: main world, after the fact.
- `RayCoreProfile.loadComponentExtension:` / `unloadComponentExtension:`: loads an unpacked extension from a path as a
  component extension (hidden from chrome://extensions, can't be turned off by the user; Ardia uses it).
- `ac_extensions_configure` `userScripts`: turns on Chrome's "Allow User Scripts" for an extension that asks for it.
- `ac_extension_storage_get/set/remove` and `ac_extension_storage_watch` (`extensionStorage.changed` events): Ray reads
  and writes an extension's `chrome.storage` and hears its changes. A two-way channel with no new engine code.
- `RayCoreTab.tabId`: Chrome's tab id, what `chrome.scripting` targets.

### Option A: a built-in MV3 extension (`Resources/Boosts/`)

Ray ships a small extension in the app bundle (fixed `key` so its id is stable; `permissions`: `scripting`,
`userScripts`, `storage`; `host_permissions`: `<all_urls>`; `incognito: "split"`), loaded with
`loadComponentExtension:` only once the profile has a Boost (no cost otherwise), and `userScripts` turned on through
`ac_extensions_configure` only once a Boost has JavaScript switched on.

- **CSS** (colours, fonts, size, case, zaps, custom CSS): Ray compiles each Boost to one stylesheet (Circa's compiler,
  section 3) and writes it as a file in the extension's folder under the data dir (`<data>/Boosts/extension/css/<id>.css`;
  the bundled extension is copied there on first use so Ray can add files). The service worker registers it with
  `chrome.scripting.registerContentScripts({id, matches, css: [file], runAt: "document_start", allFrames: true,
  persistAcrossSessions: true})`, so it is in every matching document before first paint, from the next launch
  without waiting for the worker.
- **Live edits** while the editor is open: `chrome.scripting.insertCSS({target: {tabId, allFrames: true}, css,
  origin: "USER"})` and `removeCSS` for the edited tab only, so a colour drag repaints without a reload; Done
  writes the file and re-registers.
- **JS**: `chrome.userScripts.register({id, matches, js: [{code}], runAt: "document_idle", allFrames: false, world:
  "USER_SCRIPT", worldId: <boost id>})` with `userScripts.configureWorld({worldId, csp: "script-src 'self'
  'unsafe-eval'; connect-src 'none'; object-src 'none'", messaging: false})`: each Boost's JS in its own world, no
  network, no channel back to Ray or the extension. Runs once per document; an edit applies on reload (as Arc).
- **Ray → extension**: Ray writes the compiled snapshot (`{revision, boosts: [{id, matches, cssFile, js?}]}`) into the
  extension's `chrome.storage.local` with `ac_extension_storage_set`; the worker's `storage.onChanged` diffs it against
  what's registered and registers, updates or unregisters. On launch Ray compares revisions and rewrites when stale.
- **Extension → Ray** (Zap): the picker is a content script Ray injects into the edited tab's main frame only
  (`scripting.executeScript`, isolated world, never the page's world). It reports what's under the pointer to the
  worker; the worker writes `{tabId, origin: sender.origin, documentId, pick}` to `chrome.storage.session`, which Ray
  hears through `ac_extension_storage_watch`.
- **Limits**: registered content scripts put their CSS in as **author-origin** sheets, which a page's own
  `!important` rule of higher specificity can beat (Arc's Boosts had the same limit, being extensions). The compiled
  rules all carry `!important` and the colour layer is a filter on the root, so in practice they win; the live preview
  is user-origin. Chrome forbids content scripts on chrome://, the Web Store, other extensions and `ray://` pages,
  which is what we want.
- To verify on the Mac before building: `ac_extensions_configure` finds a component extension (`ray::Find`);
  `userScripts` availability for a component extension in M158 (`IsUserScriptsAPIPermissionAvailable`); files added to
  a loaded component extension's folder are read at registration (no content verification for component
  extensions); `RayCoreTab.tabId` is the id `chrome.scripting` takes.

### Option B: the page script through RayCore

Push each tab's Boosts with `callPage` after the page script installs, and let `page_script.js` add a `<style>` and run
the JS.

- Runs in the **main world**: the page sees, removes and spoofs the Boost's styles and reads its JS, and Boost JS
  shares globals with the page. Breaks the Security checklist (page script minimal; "never act on it across tabs").
- Arrives after document start (a round trip per document): the page paints unboosted first (a flash on every load).
- `pageScript` is one global string; per-site content means messages per frame, and iframes return on the page
  script's first line.
- PLAN.md: the page script is "our own, minimal" by decision.

Cheapest on paper, wrong in practice. **Rejected.**

### Option C: a new engine hook (Circa's design on RayCore)

An engine fixup (`engine-ray/fixups/0012`): `RayCoreProfile.setBoosts:(NSString*)json revision:` keeps the profile's
snapshot in the browser process and sends it to each renderer over the `ACRendererConfig` mojo interface that already
carries the page script (`SendPageScript`); `ACPageObserver` gets `DidCreateDocumentElement` → insert each matching
Boost's CSS with `InsertStyleSheet(…, WebCssOrigin::kUser)` and keep the keys (replaced in one task on update, so
edits show live with no reload and no extension); JS through `ExecuteScriptInIsolatedWorld` in a world allocated per
Boost id, CSP as Circa's. Matching on the renderer from `document.Url()` and `GetSecurityOrigin()` (never the page's
claims), http(s) only, opaque origins never.

- Best fidelity: user-origin CSS (wins over author `!important`), first paint boosted, live edits everywhere at once.
- Costs: about 400 lines of C++ in our own fixup, a Mac engine rebuild (hours, under `scripts/locked chromium`), and a
  fixup to carry through every Ardia bump (PLAN.md: keep our patches few and small). Zap still needs a picker:
  either an isolated-world evaluate added to the same hook, or the page channel (main world, which the page can
  spoof: only hover highlights, never what's saved).
- Circa's patch is MIT and readable (`third_party/circa/native/OrbitChromium/cef-patches/engine-r21/cef.patch`,
  `orbit_boost_renderer.cc`), but CEF-shaped: a port, not a copy.

### Effort

| | Engine | Ray (store, compiler, plumbing, checks) | UI (after the mock picks) | Risk |
|---|---|---|---|---|
| A. Built-in extension | none, or one small fixup if `ray::Find`/`userScripts` refuse a component extension | 3–4 days (store, compiler, extension worker ~300 lines, storage channel, Zap picker, checks) | 5–7 days (site controls, editor, Zap, code, Settings pane) | Author-origin CSS; extension service worker wake-up on first edit after idle (~50 ms) |
| B. Page script | none | 2 days | same | Security and flash: not shippable |
| C. Engine hook | 2–3 days + a rebuild + every bump | 2–3 days (no extension, same store and compiler) | same | Carrying a fixup; engine builds only on the owner's Mac |

### Recommendation

**Option A now, data model ready for C.** It needs no engine rebuild (the cloud can't build the engine and the Mac
is busy with Spaces), it puts isolation, matching and origin checks in Chrome's own extension machinery, which has
had years of hostile pages, and it is how Arc itself did Boosts, so sites behave as they did in Arc. Boosts are
stored and compiled by Ray (section 3), not by the extension, so if the author-origin cascade or the worker's wake-up
shows up as a real problem, Option C replaces only the delivery layer (`BoostDelivery` protocol: `replace(snapshot)`,
`preview(tab, css)`, `endPreview(tab)`), with the same store, compiler, UI and checks.

## 3. Model and compiler

`Host/Boosts.swift` (`Boost`, `BoostStore`), `Host/BoostCompiler.swift`; after Circa's `BrowserBoost` and
`BrowserBoostCompiler` (MIT: keep its copyright line in the file header and in `NOTICE`, as for Cra).

```
Boost {
  id: UUID, title: String (≤ 200, one line; default the host), created, updated: Date, revision: UInt64,
  site: BoostSite { host: String (ASCII, punycode, lowercase), subdomains: Bool, schemes: [https] or [http, https] },
  enabled: Bool,
  look: { hue: Double?, saturation: Double?, invert: Bool?, contrast: Double?, brightness: Double? }?,
  font: BoostFont? (one of Ray's list, not free text), textScale: Double? (0.75–1.5 steps), textCase: upper|lower|title?,
  zaps: [BoostZap { selector, label (what the picker saw, ≤ 80), all: Bool }] (≤ 256),
  css: String (≤ 64 KB), js: String (≤ 64 KB),
  jsAllowed: Bool   // device-local, never exported or synced, reset by any import
}
```

- **Site, never a URL glob.** Made from the tab's `committedOrigin` (engine) at creation: its host, `https` (or
  `http` when the site is plain http), default port only, subdomains off. Settings can tick "and its subdomains".
  No "all websites" Boost in v1 (Settings › Appearance does app-wide looks). `matches` are generated from the
  validated host (`https://host/*`, plus `https://*.host/*` with subdomains); IP hosts exact only; dev hosts allowed
  (owners test on localhost).
- **Colours** compile to one root rule: `html { filter: hue-rotate(…) saturate(…) contrast(…) brightness(…) }` plus
  `invert(1) hue-rotate(180deg)` for invert lightness, with media (`img, video, picture, canvas, svg image,
  [style*="background-image"]`) given the inverse filter so photos stay photos (Arc's look; Dark Reader's simple
  mode). Centre of the wheel = no colour rule.
- **Fonts**: a fixed list (System, New York, SF Mono, Avenir Next, Georgia, Futura, Menlo, Optima, Baskerville,
  Gill Sans: macOS's own, nothing downloaded), compiled with CSS hex escapes (Circa's), applied to text, never to icon
  fonts (Circa's `textSelector` skips `i`, Material Symbols/Icons; add Font Awesome's `[class*="fa-"]`).
- **Size**: not `:root { zoom }` (Circa's), which stacks on Ray's per-host page zoom, already a user setting. Size
  compiles to `html { font-size: calc(100% * s) !important }`, which scales rem-based sites and leaves px ones alone.
- **Zaps**: `selector { display: none !important }`, selectors checked as Circa's `validSelector` before they're
  saved, from Ray's own picker only. "All like it" stores a class-based selector; "This one" an `nth-of-type` path
  from the nearest id.
- **Custom CSS** last in the cascade, as typed. **JS** only when `jsAllowed`.
- Limits: 256 Boosts per profile, 64 KB per source, 2 MB compiled; over a limit the editor says so and keeps the last
  good version.

## 4. Security (CLAUDE.md's checklist)

- **Never on another site.** A Boost runs only where Chrome's match pattern, built from its validated host, matches
  the document's URL in the renderer. Ray never widens a pattern from page text; subdomains only by the user's tick.
  Not in `about:blank`/`srcdoc`/`blob:` frames that inherit an origin (`matchOriginAsFallback` off), not on `data:`,
  `file:`, `chrome:`, `ray:`, the Web Store or other extensions' pages.
- **Origin from the engine.** The editor, Zap and "New Boost" take the host from the active tab's `committedOrigin`,
  never `tab.url` or anything the page says. A Zap pick is accepted only when the worker's `sender.tab.id` is the
  edited tab, `sender.origin` equals that tab's `committedOrigin`, `sender.documentId` is the document the picker was
  injected into, and the tab is still showing it; anything else is dropped. A navigation to another origin ends
  Zap and closes the editor (`closesOn: .otherSite`).
- **No string-built JS.** Ray builds no JS at all: settings go to the extension as JSON (`JSONSerialization`
  through `EngineCalls`), CSS is built from typed values (numbers formatted by Ray, the font from Ray's list and
  hex-escaped, selectors validated), and the user's own JS is passed through untouched as data. The picker is a static
  file in the extension, never generated.
- **JS is opt-in and walled off.** Off until the user turns on "Run JavaScript on <host>" on that Boost (a
  `PanelQuestion` with the full origin, the action dead for 0.5 s, Cancel by default, Return cancels). Each Boost's JS
  in its own user-script world (or isolated world in Option C) with no network (`connect-src 'none'`) and no
  messaging, so it can change the page but not send it anywhere or reach Ray. Consent is device-local: never
  exported, never synced, cleared by any import or by editing the Boost's site.
- **Zap's picker** runs in an isolated world in the edited tab's top frame only, while Zap is on; it reports a
  selector, a short label and a rect, sizes checked (selector ≤ 2,048, label ≤ 80), and is removed on Done, Escape,
  a tab switch or a navigation.
- **Private windows** use the normal profile's Boosts (read-only) through the split incognito extension; editing
  is off there (owner question 4).
- **Logs**: no hosts, selectors or code in `NSLog` in normal runs; the state log (test builds) has counts, ids and
  revision.
- **Checks** (`tests/checks.mjs`, fixtures only): a Boost for `a.test` never applies on `b.test`, on
  `evil.a.test.b.test`, on `a.test` over http when made for https, or in an `about:blank` iframe on another site; a
  forged Zap message (wrong tab, wrong origin, stale document) is dropped; JS does nothing until allowed and can't
  `fetch`; a font name with quotes and `}` compiles to an escaped string; a selector with `{` is refused; the Boost
  survives a relaunch; with no Boosts the extension isn't loaded.

## 5. Storage, sharing and sync

- `Boosts.json` in the data dir next to `Sidebar.json` and `Settings.json` (one per profile once Profiles land;
  Boosts belong to the profile, not a Space, as in Arc and Circa). Sorted keys, saved 0.2 s after a change and on
  quit, written atomically; unknown keys kept; a bad entry is dropped on load, not the file. The extension's
  `chrome.storage.local` and its CSS files are a cache rebuilt from it (revision compare at launch).
- **Sharing**: Arc's Boost Gallery dies with Arc. Ray exports one Boost as a `.rayboost` file (JSON: the Boost
  without `jsAllowed`, a format version) from Settings or the editor's menu, and opens one from Finder or a drop:
  it shows what it changes and its code, adds it switched off with JS not allowed. A public gallery is out of scope
  (no accounts, no posting).
- **Sync** (MISSING #16, not built): the format is ready for it (UUIDs, revision, `updated`), merge by Boost id,
  newest revision wins per field group; `jsAllowed` never leaves the Mac.
- **Arc import** (later, `Importer/`): Arc keeps Boosts as unpacked extension folders in its Application Support;
  read `styles.css` and `content.js` (and the simple Boost's settings if readable) into Ray Boosts with JS not
  allowed. Needs a look at a real Arc profile's layout on the owner's Mac first.

## 6. UI (the mocks)

`docs/mocks/boosts.html`, one pick per row, light and dark:

1. **New Boost from Site controls**: A a Boost tile in the quick actions with the site's Boosts as switch rows; B a
   "Boost this site" row at the top of the panel; C a brush button in the address bar (Arc's), Site controls only
   listing.
2. **Editor, colours and fonts**: A Arc's narrow column over the page's right side; B a `Panels` panel from the
   sliders button with Style and Code tabs; C a bar along the page's bottom.
3. **Editor, code**: A the same panel grown wide with CSS and JS tabs; B a window of its own (Arc's); C a pane docked
   beside the page with live preview.
4. **Zap**: A outline on hover, click zaps, a held note at the top with the zapped list (Arc's); B click asks "Zap
   this / Zap all like it" (Circa's); C outline with a breadcrumb to pick the parent before zapping.
5. **Settings › Boosts**: A a list of `SettingsItemRow`s with switches that open to what each changes; B grouped by
   site; C cards with a picture of the boosted site (Arc's Library).

Commands either way: View › Boost This Site (no default key; Arc had none), Zap Element (⇧⌘H, the audit's "Hide
Element"), the command bar's "Boost <site>", "Zap", "Settings: Boosts". New Settings pane `boosts` in "Your data"
(`SettingsBoosts.swift`), `ray://settings/boosts`.

## 7. Build order (once picked)

1. `Boost`, `BoostStore`, `BoostCompiler` + unit tests (`tests/BoostCompilerTests.swift`: escaping, selector
   checks, matches, limits).
2. `Resources/Boosts/` extension and `BoostDelivery` (Option A), loaded on the first Boost; state log `boosts`
   (count, revision, registered ids, extension loaded); checks `boosts-match`, `boosts-relaunch`, `boosts-no-cost`.
3. Site controls entry and the editor's Style page with live preview; check `boosts-editor`.
4. Zap with the picker and its checks (`boosts-zap`, `boosts-zap-forged`).
5. Code page and the JS opt-in (`boosts-js-optin`, `boosts-js-no-network`).
6. Settings › Boosts, export/import; docs (CLAUDE.md Layout, MISSING Done, README "What works").

## 8. Questions for the owner

1. One pick per mock row (section 6).
2. Option A now (no engine rebuild), keeping C for later? (Recommended.)
3. Boosts with JavaScript: allowed with the per-Boost opt-in and no network (recommended), or CSS-only in v1?
4. Private windows: apply your Boosts there (recommended, read-only), or none?
5. Sharing: `.rayboost` files only (recommended), or nothing in v1?
6. Zap's key: ⇧⌘H (the audit's Hide Element) or none?

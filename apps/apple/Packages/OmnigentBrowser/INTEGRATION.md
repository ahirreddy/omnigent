# Hosting browser tabs (integration guide)

This is the contract between `OmnigentBrowser` and the app's unified tab strip. The browser package
draws no tab strip. It gives the tab system one model per browser tab, a content view for the
selected tab, Codable restore state, and the profile, history and bookmark stores. Everything below
is in `import OmnigentBrowser` and works on both engines (Chromium in the Developer ID edition,
WebKit everywhere, including the App Store edition).

## One environment per app

```swift
let browser = BrowserEnvironment.standard(
  provider: services.browserProvider,        // DefaultBrowserEngineProvider (with or without Chromium)
  preferences: services.browserPreferences)  // the persisted engine choice
```

`BrowserEnvironment` (`@Observable`, main actor) owns everything shared by browser tabs:

| Member | What it is |
|---|---|
| `profiles: BrowserProfileStore` | Named persistent profiles and the default-profile setting |
| `settings: BrowserSettings` | Search engine, bookmarks bar visibility, new-tab URL |
| `presenter: BrowserPromptPresenter` | Dialogs, permissions, downloads, certificate interstitials for every tab |
| `recentlyClosed: BrowserRecentlyClosedStore` | Restore states of closed tabs, newest first (for ⇧⌘T) |
| `history(for: profileID) -> BrowserHistoryStore` | Per-profile history |
| `bookmarks(for: profileID) -> BrowserBookmarkStore` | Per-profile bookmarks |
| `liveTabs: [BrowserTabModel]` | Every open model (weak), used for "switch to tab" suggestions |
| `makeTab(profileID: UUID? = nil, url: URL? = nil) -> BrowserTabModel` | A new tab; nil profile means `profiles.defaultProfileID`, nil URL means `settings.newTabURL` |
| `restoreTab(_ state: BrowserTabRestoreState) -> BrowserTabModel` | A tab from saved state; nothing loads until it is activated |
| `onOpenTab: ((BrowserTabModel, BrowserTabOpenContext) -> Void)?` | Set once by the tab system. Called for popups, target=_blank, "Open Link in New Tab", View Source, and history/bookmark "open in new tab". The model is already created; insert it into the strip. Without a handler, page popups open in a popup window. |
| `onSwitchToTab: ((UUID) -> Void)?` | Set once. The omnibox's "Switch to tab" suggestion asks the strip to select that tab ID. |
| `onCloseTab: ((BrowserTabModel) -> Void)?` | Set once. A page called `window.close()`, or the tab's profile is being deleted; remove the tab (call `model.close()`). Without it the model closes itself. |
| `openTab(url: URL?, profileID:opener:disposition:)` | Makes a tab and hands it to `onOpenTab` (what the profile menu's "New Tab in Profile" uses) |
| `reopenClosedTab() -> BrowserTabModel?` | Pops `recentlyClosed` and restores it |
| `flush() throws(BrowserError)` | Writes pending history, zoom and closed-tab changes (also done at app termination) |
| `clearBrowsingData(profileID:types:since:) async throws(BrowserError)` | Clears history, cookies, cache, site data and permissions for one profile |

Files live under `BrowserEnvironment.standardDirectory` = `Application Support/<bundle id>/Browser/` (`profiles.json`,
`Profiles/<profile id>/{history,bookmarks,zoom}.json`). Tests use
`BrowserEnvironment(directory:provider:preferences:presenter:defaults:)` with a temporary directory.

## One model per browser tab

`BrowserTabModel` (`@Observable`, `Identifiable`, main actor). Read these for the tab chip:

| Property | Notes |
|---|---|
| `id: UUID` | Stable across restore; use it as the strip's tab ID |
| `profileID: UUID`, `profile: BrowserUserProfile?` | The tab's profile; fixed for the tab's life (Chrome semantics) |
| `title: String`, `displayTitle: String` | `displayTitle` falls back to the host, then "New Tab" |
| `url: URL?` | The committed URL (restore placeholders already mapped to the real URL) |
| `favicon: BrowserFavicon?` | `pngData`, plus `image` (SwiftUI `Image`) |
| `isLoading`, `estimatedProgress` | For a spinner or progress ring |
| `canGoBack`, `canGoForward` | |
| `isAudible`, `isMuted` | Show a speaker icon when `isAudible || isMuted`; `toggleMute()` |
| `isPinned: Bool` (settable) | Stored in the restore state; the strip owns its meaning |
| `isActivated: Bool` | False until the content view first appears (lazy restore) |
| `restoreRevision: Int` | Increments whenever `snapshotForRestore()` would change; observe it to schedule a save |
| `lastError: BrowserError?`, `pageError: BrowserError?` | Command failures (print, DevTools on WebKit, bookmarks) and page load errors; the content view shows both |

Commands: `activate()`, `load(_:)`, `submitOmnibox(_:)`, `goBack()`, `goForward()`, `reload()`,
`reloadIgnoringCache()`, `stopLoading()`, `toggleMute()`, `zoomIn()`, `zoomOut()`, `resetZoom()`,
`showFindBar()`, `showDevTools()`, `printPage()`, `viewSource()`, `toggleBookmark()`, and
`close() -> BrowserTabRestoreState` (closes the engine tab, pushes the state onto
`environment.recentlyClosed`, and returns it). Errors from these surface in `lastError` and in the
content view's banner; none are dropped.

## The content view

```swift
BrowserTabContentView(model: model, environment: browser, keyboardShortcuts: true)
```

Shows the toolbar (back, forward, reload/stop, omnibox with history, bookmark and open-tab
suggestions, bookmark star, mute, zoom badge, downloads, profile chip, overflow menu), the optional
bookmarks bar, the find bar, and the page with its prompts and banners. It calls `model.activate()`
on appear (keyed by the model object, so swapping models in the same view works), so a restored
background tab loads only when first shown. Show one content view for the selected tab.

Keyboard shortcuts inside the view (active only while it is in the window): ⌘L omnibox, ⌘F find,
⌘G / ⇧⌘G next/previous match, ⌘+ ⌘− ⌘0 zoom, ⌘R reload, ⇧⌘R hard reload, ⌥⌘I DevTools,
⌘P print, ⌥⌘U view source, ⌘D bookmark, ⌘Y history. They also work while a Chromium page has focus
(the web layer passes keys the page did not use to the window). For menu-bar items instead, add
`BrowserTabCommands()` (macOS) to the scene's `.commands` and pass `keyboardShortcuts: false`; the
content view publishes `\.browserTab` and `\.browserTabSheet` as focused scene values. The strip
keeps ⌘T, ⌘W, ⇧⌘T and ⌘1–9.

## Restore

```swift
let state: BrowserTabRestoreState = model.snapshotForRestore()  // Codable, Sendable, versioned
let model = browser.restoreTab(state)                            // later, after relaunch
```

`BrowserTabRestoreState` holds `version`, `id`, `profileID`, `url`, `title`, `faviconPNG`,
`history` (`BrowserNavigationHistory`: entries of URL and title, plus `currentIndex`),
`webKitInteractionState` (WebKit's opaque state), `isPinned` and `isMuted`. Decoding a newer
version throws `BrowserError.restoreStateUnsupported`. Back and forward history restore on both
engines (WebKit through `interactionState`; Chromium by rebuilding the entries, see README). A
restored model shows its saved title and favicon immediately and loads when activated.

Persist it however the strip persists its other kinds. For standalone use (or as a pattern),
`BrowserPersistentFile<Value: Codable>` writes JSON atomically with a debounce
(`schedule(_:)`, `flush()`), and `BrowserSessionSnapshot` is a ready-made `{version, tabs,
selectedTabID}` container.

## Profiles

- `BrowserUserProfile`: `id`, `name`, `color: BrowserProfileColor`, `avatar: BrowserProfileAvatar`
  (`.initials`, `.symbol(String)`, `.emoji(String)`), `browserProfile` (the storage identity
  `user:<uuid>`, persistent; Chromium `Profile-<key>` request context, WebKit
  `WKWebsiteDataStore(forIdentifier:)`).
- `BrowserProfileStore`: `profiles`, `defaultProfileID` (settable), `profile(id:)`,
  `create(name:color:avatar:)`, `update(_:)`, `delete(id:)`. A "Personal" profile exists on first
  launch; the last profile cannot be deleted. Deleting removes its history, bookmarks, zoom and
  permissions, and its engine data. Close that profile's tabs first (`liveTabs` filtered by
  `profileID`).
- Views: `BrowserProfileChip(profile:)` (avatar plus name, for a tab or toolbar),
  `BrowserProfileAvatarView(profile:size:)` (just the avatar, for a tab chip),
  `BrowserProfilePicker(store:onPick:)` (menu content listing profiles for "New Tab in Profile"),
  `BrowserProfileManagerView(environment:)` (create, rename, recolor, pick avatar, set default,
  delete).
- Agent browser actions keep their own ephemeral `agent:<conversation>` profiles;
  `AgentBrowserController` refuses any `user:` profile.
- Settings and data views: `BrowserSettingsView(environment:)` (a `Section`),
  `BrowserHistoryView`, `BrowserBookmarksManagerView`, `BrowserClearDataView`,
  `BrowserSiteSettingsView`, `BrowserDownloadsView(center:settings:profileIdentifier:)`.

## Wiring the tab system needs (outside this package)

1. Create one `BrowserEnvironment` in `AppServices` and pass it to the tab strip.
2. Set `browser.onOpenTab` and `browser.onSwitchToTab`.
3. New browser tab (⌘T when the user picks "Browser", or a profile from `BrowserProfilePicker`):
   `browser.makeTab(profileID:)`.
4. Persist `snapshotForRestore()` per browser tab; restore with `browser.restoreTab(_:)`.
5. ⇧⌘T for a browser tab: `browser.restoreTab(state)` with the state `close()` returned (or
   `browser.recentlyClosed.popLast()`).
6. Settings: `BrowserSettingsView(environment:)` adds search engine, bookmarks bar and profiles
   next to `BrowserEngineSettingsView`.
7. The standalone `BrowserWindow` keeps using `BrowserController`/`BrowserView`, which are
   unchanged, until the strip replaces it.

A working host of all of this, without a real strip, is the proof harness
`Packages/OmnigentWebLayer/Example/Sources/BrowserTabHarness.swift`.

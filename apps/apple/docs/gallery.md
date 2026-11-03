# Component gallery

The gallery is a catalog of the native UI at three levels, for browsing and critique:

- **Components**: each reusable view in `OmnigentUIComponents`, grouped by area, in its
  important states (empty, loading, error, long text, needs you, read only, ...).
- **Pages**: whole screens with realistic data, built on the playground's scenarios.
- **Flows**: multi-step journeys with a step list and Back/Next. Each step is the previous
  step's model with one more action applied, using the same view-state types and actions
  the app uses. Entries with an interactive playground also have a **Live** mode.

It lives in `Packages/OmnigentUI/Sources/OmnigentUIComponents/Gallery/Catalog/`. The
public entry points are `GalleryCatalogView`, `GalleryLaunchOptions` and
`GallerySnapshotExport`.

## Running it

### Mac

```sh
cd apps/apple/Packages/OmnigentUI
swift run OmnigentPlayground --gallery
# Start on an entry, a state or flow step, and a device:
OMNIGENT_GALLERY_ENTRY=flows.decisions.approval OMNIGENT_GALLERY_STATE=review \
  OMNIGENT_GALLERY_DEVICE=iPhone swift run OmnigentPlayground --gallery
```

On the Mac, pass the entry, state and device as environment variables: an argument
with a value (`--gallery-entry <id>`) keeps SwiftUI from opening the first window
(AppKit appears to treat the value as a document to open). `--export-gallery` works because it runs
from the app delegate. `OMNIGENT_PLAYGROUND_SNAPSHOT=<file.png>` captures the gallery
window as it does the playground's.

In a normal playground run, **Playground > Open Gallery** (Command-Shift-G) opens it
in its own window. The **Component Gallery** scenario shows it too.

The sidebar lists the three sections, grouped by area, with search over titles,
summaries, areas, keywords and state titles. The inspector (the slider button) holds
the global controls:

- Appearance: Light, Dark, or Both side by side
- Theme: every built-in palette and Custom (an Appearance settings pane is in the
  catalog too, and editing it restyles the gallery)
- Device: the Mac window (1280x820), iPhone 17 Pro (402x874), iPhone SE (375x667),
  iPad Pro 13" (1032x1376) and 11" (834x1210), iPad Split View at a third, half and two
  thirds of the 13" landscape screen, and iPhone Duo (its 466x678 outer display folded, its
  951x669 inner display, one continuous screen with a crease down the middle, unfolded).
  **Landscape** rotates iPhones and iPads; **Unfolded** opens the Duo. Components follow
  the device's size classes and composer style.
- **Device frame** (on by default) draws iPhone, iPad and Duo pages in a bezel with the
  status bar, the Dynamic Island, the home indicator, the SE's home button, the Split View
  divider and the Duo's crease. Inside, the page gets the device's safe-area insets,
  horizontal and vertical size classes, display scale and hinge posture. With the frame
  off the page is the bare screen. Pages scale to fit unless **Fit pages** is off.
  The Duo's geometry comes from its simulator profile and, folded, from the running
  simulator: the outer display's spine corners are 8 pt and its status bar and Dynamic
  Island take an 84 pt column on the right. Unfolded, shell pages show the session list at
  its usual width beside the destination, as the app's split view does; content runs
  across the crease, which the display draws through.
- Text size (every Dynamic Type size), Increase contrast, Reduce transparency, Reduce motion and
  Right to left
- **Show every component state**: all states stacked, or one at a time with a picker

On the Mac each canvas is its own hosting view, so light, dark and increased contrast
reach AppKit controls the way a window's appearance does. These canvases have no window
toolbar. **Open in Window** (the toolbar button) shows the current state in a real
titled window with its toolbar and sheets. Flows use Command-[ and Command-] for Back
and Next.

### iOS and iPadOS

Debug builds of the app show the gallery when launched with `-OmnigentGallery`
(optionally `--gallery-entry <id>`, `--gallery-state <id>` and `--gallery-device <id>`):

```sh
just run-ios   # or build in Xcode, then:
xcrun simctl launch booted ai.omnigent.ios -OmnigentGallery
```

In Xcode, add `-OmnigentGallery` under Scheme > Run > Arguments. The device picker
starts on this device's family. **Full Screen** shows the selected state at the
device's real size; the close button is at the top trailing corner.

## Snapshot export

Every entry, or a filtered subset, renders in light and dark to PNGs, with an
`index.html` contact sheet and a `manifest.json` (entries, states, notes and file
names) for tools:

```sh
cd apps/apple/Packages/OmnigentUI
swift run OmnigentPlayground --export-gallery /tmp/omnigent-gallery
swift run OmnigentPlayground --export-gallery /tmp/omnigent-gallery \
  --gallery-filter composer,flows.decisions --gallery-theme nord \
  --gallery-devices mac,iPhone,iPhone-landscape,iPadPro13,iPadSplitThird,duo-unfolded \
  --gallery-frames on --gallery-appearances dark
open /tmp/omnigent-gallery/index.html
```

`--gallery-accessibility contrast,reduce-transparency,reduce-motion` renders under those
settings. `--gallery-capture window` captures each render through the window server (the window
sits behind the desktop, out of sight), so Liquid Glass and scroll edge effects draw; it needs
Screen Recording permission for the terminal. Without it, `cacheDisplay` draws neither glass nor
what sits in it, so `GlassSurface` is flattened to a material.

```sh
swift run OmnigentPlayground --export-gallery /tmp/glass --gallery-filter pages.transcript \
  --gallery-devices mac,iPhone,iPadPro13 --gallery-capture window \
  --gallery-accessibility reduce-transparency
```

The same options work as environment variables (`OMNIGENT_GALLERY_EXPORT`,
`OMNIGENT_GALLERY_FILTER`, `OMNIGENT_GALLERY_THEME`, `OMNIGENT_GALLERY_DEVICES`,
`OMNIGENT_GALLERY_FRAMES`, `OMNIGENT_GALLERY_APPEARANCES`, `OMNIGENT_GALLERY_ACCESSIBILITY`,
`OMNIGENT_GALLERY_CAPTURE`). A filter term matches an
entry id or title. A device id is `mac`, `iPhone`, `iPhoneSE`, `iPadPro13`, `iPadPro11`,
`iPadSplitThird`, `iPadSplitHalf`, `iPadSplitTwoThirds` or `duo`, with `-landscape` for
iPhones and iPads or `-unfolded` for the fold. Pages render on each listed device they
support (Mac and iPhone by default), framed unless `--gallery-frames off`. The process
exits 0 after printing the output paths, 1 if a render or write fails, and 2 for a
bad option.

Files are named `<entry id>--<state id>[--<device id>]--<theme>-<light|dark>.png`. Flow
steps are numbered, for example
`flows.decisions.approval--03-review--mac--omni-dark.png`.

The inspector's **Export PNGs** does the same from the app for this entry, the
search results or everything, at the inspector's theme and accessibility settings.
On iOS it writes to `Documents/GallerySnapshots`.

The render test writes the whole catalog too:

```sh
OMNIGENT_UI_RENDER_DIR=/tmp/ui swift test --filter GalleryCatalogRenderTests
# One area while iterating:
OMNIGENT_GALLERY_FILTER=components.composer OMNIGENT_UI_RENDER_DIR=/tmp/ui \
  swift test --filter GalleryCatalogRenderTests
```

On the Mac a navigation stack's bar lives in the window toolbar, which a canvas does not
have, so shell pages on touch devices draw an inline navigation bar in its place
(`CatalogNavigationBar`). On iOS the real bar draws.

The Mac export draws through a real `NSHostingView` in a window that is never shown,
like `RenderSupport` in the tests, so lists and text fields draw. Window toolbars and
system sheets do not appear in captures. Pages draw their modals in place
(`CatalogSheetOverlay`), and the tab strip is drawn where the titlebar would be.

## Adding to the catalog

Each area has one file (`CatalogComposer.swift`, `CatalogDecisions.swift`, ...)
with an enum whose `entries` the registry (`CatalogRegistry.swift`) concatenates.
Reuse the sample data in `Preview/PreviewData*.swift` and the existing playgrounds
rather than adding new fixtures.

### A component

```swift
.component(
  .composer, "queue", "Queue Strip",
  summary: "Follow-ups queued behind the running turn.",
  systemImage: "list.number", canvas: .column(width: 720), keywords: ["steer"],
  states: [
    CatalogState("queued", "Queued") { CatalogStack { QueueStrip(...) } },
    CatalogState("failed", "Failed", note: "What to look at.") { ... },
  ])
```

`canvas` is `.column(width:)` (the height follows the content) or
`.fixed(width:height:)` for surfaces such as a sidebar or a sheet. A state's view is
made once per presentation; for a state that needs `@State` (a draft, a binding),
write a small private view that owns it.

### A page

```swift
.page(
  .inbox, "inbox", "Inbox", summary: "...", systemImage: "tray",
  states: [scenario("triage", "Triage", .inbox) { model in model.inbox = ... }])
```

`scenario(_:_:_:configure:)` builds a `PlaygroundModel` for a playground scenario and
lets you adjust it; `CatalogShell` lays it out for the device (session list and
detail on Mac and iPad landscape, the destination alone on iPhone). Use
`canvas: .phone` for iPhone-only pages, or `.device([...])` to limit devices.

### A flow

```swift
static var example: CatalogFlowScript<SteeringFlowModel> {
  CatalogFlowScript(
    initial: { _ in SteeringFlowModel() },
    steps: [
      Step("running", "The agent is working", note: "..."),
      Step("steer", "Send steers", note: "...") { model in model.steer() },
      Step("queue", "Queue instead", note: "...", branchesFrom: "running") { model in ... },
    ],
    render: { model, context in AnyView(SteeringFlowScreen(model: model)) })
}
```

Steps apply the app's own actions to the model. `branchesFrom` starts a step from an
earlier one instead of the step before it (approve, reject or tell the agent
instead). Register it with `.flow(area, name, title, summary:, script:, live:)`;
`live` points at an interactive playground when there is one. Add a test in
`GalleryCatalogTests.swift` that checks the model at the steps that matter.

## Tests

- `GalleryCatalogTests`: unique, file-name-safe ids; search; grouping and export
  filters; flow navigation; every flow's models; launch-option parsing; the export plan.
- `GalleryDeviceTests`: the device list and postures, safe areas, size classes, the
  Duo's displays and crease, framed and bare layouts, and the device and frame launch options.
- `GalleryCatalogRenderTests`: every entry and state in light and dark through the
  exporter (framed pages on Mac and iPhone), one framed page per device and posture, and a
  contrast check. It takes about thirteen minutes, mostly CoreGraphics rasterizing blurs.

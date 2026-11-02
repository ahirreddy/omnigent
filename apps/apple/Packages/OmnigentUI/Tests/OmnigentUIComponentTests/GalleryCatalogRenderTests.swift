#if os(macOS)
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Renders every catalog entry, every state, in light and dark (pages on Mac and iPhone)
  /// through the snapshot exporter. With `OMNIGENT_UI_RENDER_DIR` set the PNGs, `index.html` and
  /// `manifest.json` stay in `<dir>/gallery` for review; `OMNIGENT_GALLERY_FILTER` (comma
  /// separated) narrows the entries while iterating on one area.
  @Suite("Gallery catalog rendering", .serialized)
  struct GalleryCatalogRenderTests {
    @Test("every entry renders in both appearances")
    func renderEverything() async throws {
      let keep = RenderSupport.outputDirectory.map { $0.appending(path: "gallery") }
      let directory =
        keep
        ?? FileManager.default.temporaryDirectory.appending(
          path: "gallery-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
      let preferences = ThemePreferences(defaults: CatalogSettings.scratchDefaults)
      preferences.mode = .system
      preferences.paletteID = OmnigentTheme.omni.id
      let filters = (ProcessInfo.processInfo.environment["OMNIGENT_GALLERY_FILTER"] ?? "")
        .split(separator: ",").map(String.init)
      let entries = GalleryCatalog.filtered(GalleryCatalog.entries, by: filters)
      let job = CatalogExportJob(
        entries: entries, directory: directory, preferences: preferences,
        settleTime: .milliseconds(40))
      let report = try await CatalogExporter.run(job)
      let plan = CatalogExporter.plan(job)
      #expect(report.images.count == plan.count)
      for (item, url) in zip(plan, report.images) {
        let image = try #require(
          NSBitmapImageRep(data: try Data(contentsOf: url)), "\(item.fileName)")
        let entry = try #require(GalleryCatalog.entry(item.entryID))
        let layout = CatalogLayout(canvas: entry.canvas, screen: item.screen)
        #expect(CGFloat(image.pixelsWide) >= layout.width, "\(item.fileName) is too narrow")
        if let height = layout.height {
          #expect(CGFloat(image.pixelsHigh) >= height, "\(item.fileName) is too short")
        }
      }
      #expect(FileManager.default.fileExists(atPath: report.index.path))
      let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: report.manifest))
      #expect((manifest as? [Any])?.count == entries.count)
      if keep == nil { try FileManager.default.removeItem(at: directory) }
    }

    @Test("a component state draws something in light and dark")
    func inkAndContrast() async throws {
      let entry = try #require(GalleryCatalog.entry("components.composer.composer"))
      let state = try #require(entry.states.first)
      let preferences = ThemePreferences(defaults: CatalogSettings.scratchDefaults)
      var luminance: [ColorScheme: Double] = [:]
      for scheme in [ColorScheme.light, .dark] {
        let mac = CatalogScreen(.mac)
        let traits = CatalogTraits(theme: .omni, scheme: scheme, screen: mac)
        let data = try await CatalogExporter.render(
          state, context: CatalogContext(screen: mac, preferences: preferences), traits: traits,
          layout: CatalogLayout(canvas: entry.canvas, screen: mac), name: state.id)
        let image = try #require(NSBitmapImageRep(data: data))
        let rendered = RenderSupport.Rendered(image: image)
        #expect(RenderSupport.inkCoverage(rendered) > 0.01)
        luminance[scheme] = RenderSupport.averageLuminance(rendered)
      }
      #expect((luminance[.light] ?? 0) > (luminance[.dark] ?? 1))
    }

    @Test("one framed page per device and posture draws at the device's size")
    func framedDevices() async throws {
      let entry = try #require(GalleryCatalog.entry("pages.transcript.conversation"))
      let state = try #require(entry.states.first)
      let preferences = ThemePreferences(defaults: CatalogSettings.scratchDefaults)
      for screen in CatalogScreen.all {
        let layout = CatalogLayout(canvas: entry.canvas, screen: screen)
        let data = try await CatalogExporter.render(
          state, context: CatalogContext(screen: screen, preferences: preferences),
          traits: CatalogTraits(theme: .omni, scheme: .dark, screen: screen), layout: layout,
          name: screen.id, settleTime: .milliseconds(40))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(CGFloat(image.pixelsWide) >= layout.width, "\(screen.id)")
        #expect(CGFloat(image.pixelsHigh) >= layout.height ?? 0, "\(screen.id)")
        #expect(RenderSupport.inkCoverage(RenderSupport.Rendered(image: image)) > 0.01)
        if let directory = RenderSupport.outputDirectory {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try data.write(to: directory.appending(path: "gallery-frame-\(screen.id).png"))
        }
      }
    }
  }
#endif

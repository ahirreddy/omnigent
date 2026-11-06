import Foundation
import Testing

@testable import OmnigentBrowser

#if os(macOS)
  import AppKit
  import SwiftUI
#endif

/// The touch address pill's domain display, and renders of the address rows: the iPhone and
/// iPad pill rows and the Mac toolbar. Set `OMNIGENT_BROWSER_RENDER_DIR` to write them as PNGs.
@MainActor
@Suite("Address bar")
struct AddressBarTests {
  @Test func thePillShowsTheDomainOnly() throws {
    let page = BrowserAddressDisplay(url: try testURL("https://www.example.com/path?q=1"))
    #expect(page.domain == "example.com")
    #expect(page.isSecure)
    let local = BrowserAddressDisplay(url: try testURL("http://127.0.0.1:6767/c/abc"))
    #expect(local.domain == "127.0.0.1")
    #expect(!local.isSecure)
    #expect(BrowserAddressDisplay(url: nil).isEmpty)
    #expect(BrowserAddressDisplay(url: try testURL("about:blank")).isEmpty)
    #expect(BrowserAddressDisplay(url: "data:text/html,hi").domain == "data:text/html,hi")
  }

  #if os(macOS)
    @Test func addressRowsRender() throws {
      let (environment, _) = try makeEnvironment()
      let model = environment.makeTab(url: try testURL("http://127.0.0.1:6767/c/abc"))
      let tabs = AnyView(
        Button("Tabs", systemImage: "2.square") {}.labelStyle(.iconOnly))
      try Self.renderBothSchemes(
        BrowserTouchTopBar(
          model: model, environment: environment, sheet: .constant(nil), isCompact: true,
          showSessions: {}, tabsButton: tabs),
        width: 390, name: "iphone-row")
      try Self.renderBothSchemes(
        BrowserTouchTopBar(
          model: model, environment: environment, sheet: .constant(nil), isCompact: false),
        width: 834, name: "ipad-row")
      try Self.renderBothSchemes(
        BrowserTabToolbar(model: model, environment: environment, sheet: .constant(nil)),
        width: 900, name: "mac-toolbar")
    }

    private static func renderBothSchemes(_ view: some View, width: CGFloat, name: String) throws {
      for scheme in [ColorScheme.light, .dark] {
        let png = try render(AnyView(view), width: width, scheme: scheme)
        #expect(!png.isEmpty)
        try write(png, name: "\(name)-\(scheme == .dark ? "dark" : "light")")
      }
    }

    /// Draws through a real `NSHostingView`, so text fields and glass draw as in the app.
    private static func render(_ view: AnyView, width: CGFloat, scheme: ColorScheme) throws
      -> Data
    {
      _ = NSApplication.shared
      let host = NSHostingView(
        rootView: view.environment(\.colorScheme, scheme).frame(width: width)
          .background(scheme == .dark ? Color.black : Color.white))
      host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      let size = CGSize(width: width, height: max(host.fittingSize.height, 40))
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.appearance = host.appearance
      window.contentView = host
      host.frame = CGRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      window.orderOut(nil)
      return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private static func write(_ png: Data, name: String) throws {
      guard let directory = ProcessInfo.processInfo.environment["OMNIGENT_BROWSER_RENDER_DIR"]
      else { return }
      let folder = URL(filePath: directory, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try png.write(to: folder.appending(path: "\(name).png"))
    }
  #endif
}

internal import AppKit
internal import Foundation
internal import OmnigentBrowser
internal import OmnigentBrowserChromium
internal import SwiftUI

/// Sample host for the OmnigentBrowser engines.
///
/// Arguments: `--engine chromium|system` overrides the stored choice for this launch,
/// `--screenshot <path>` writes a PNG of the window once the page loads and then quits.
@main
struct BrowserExampleApp: App {
  @State private var model = ExampleModel()

  var body: some Scene {
    WindowGroup("Omnigent Browser Example") {
      BrowserView(controller: model.controller)
        .frame(minWidth: 960, minHeight: 640)
        .task { await model.runScreenshotIfRequested() }
    }
  }
}

@Observable
final class ExampleModel {
  let provider = DefaultBrowserEngineProvider.withChromium()
  let preferences: BrowserPreferences
  let controller: BrowserController
  private let screenshotPath: String?
  private let thenEngine: BrowserEngineKind?

  init() {
    let arguments = ProcessInfo.processInfo.arguments
    preferences = BrowserPreferences(provider: provider)
    if let kind = Self.value(after: "--engine", in: arguments).flatMap(BrowserEngineKind.init) {
      preferences.engine = kind
    }
    screenshotPath = Self.value(after: "--screenshot", in: arguments)
    thenEngine = Self.value(after: "--then", in: arguments).flatMap(BrowserEngineKind.init)
    controller = BrowserController(
      profile: .server("example"),
      preferences: preferences,
      provider: provider,
      initialURL: URL(string: "https://example.com"))
  }

  private static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }

  func runScreenshotIfRequested() async {
    guard let screenshotPath else { return }
    do {
      try await captureWindow(to: URL(fileURLWithPath: screenshotPath))
      NSApp.terminate(nil)
    } catch {
      FileHandle.standardError.write(Data("BrowserExample: \(error)\n".utf8))
      exit(1)
    }
  }

  private func captureWindow(to url: URL) async throws {
    try await waitForPage()
    if let thenEngine {
      let previous = controller.tab
      log("loaded with \(controller.activeEngine?.rawValue ?? "none"); switching to \(thenEngine)")
      controller.switchEngine(to: thenEngine)
      log("previous tab closed=\(previous?.state.isClosed ?? false)")
      try await waitForPage()
    }
    try await writeScreenshot(to: url)
  }

  private func log(_ message: String) {
    FileHandle.standardOutput.write(Data("BrowserExample: \(message)\n".utf8))
  }

  private func waitForPage() async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while true {
      if case .engineUnavailable(_, let error) = controller.content {
        throw error
      }
      if let tab = controller.tab, !tab.state.isLoading, !tab.state.title.isEmpty {
        break
      }
      if ContinuousClock.now >= deadline {
        throw BrowserError.snapshotFailed("Timed out waiting for the page to load.")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func writeScreenshot(to url: URL) async throws {
    try await Task.sleep(for: .seconds(1))
    guard let tab = controller.tab, let window = NSApp.windows.first(where: \.isVisible),
      let contentView = window.contentView
    else {
      throw BrowserError.tabNotReady
    }
    let title = try await tab.evaluateJavaScript("document.title")
    let pageURL = tab.state.url?.absoluteString ?? "nil"
    log(
      "engine=\(tab.engineKind.rawValue) url=\(pageURL) title=\(tab.state.title) js(document.title)=\(title)"
    )

    let pagePNG = try await tab.takeSnapshotPNG()
    guard let page = NSImage(data: pagePNG),
      let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
    else {
      throw BrowserError.snapshotFailed("Could not decode snapshots.")
    }
    contentView.cacheDisplay(in: contentView.bounds, to: rep)
    guard let windowImage = rep.cgImage else {
      throw BrowserError.snapshotFailed("Could not render the window.")
    }
    // The page is composited from the engine's own snapshot: out-of-process web content does
    // not render through cacheDisplay.
    let pageRect = tab.platformView.convert(tab.platformView.bounds, to: contentView)
    let composite = NSImage(size: contentView.bounds.size)
    composite.lockFocusFlipped(contentView.isFlipped)
    NSColor.windowBackgroundColor.setFill()
    contentView.bounds.fill()
    NSImage(cgImage: windowImage, size: contentView.bounds.size).draw(in: contentView.bounds)
    page.draw(in: pageRect)
    let engine =
      tab.engineKind == .chromium
      ? "Chromium (out-of-process web host)"
      : tab.engineKind.displayName
    let caption =
      "Engine: \(engine)   URL: \(tab.state.url?.absoluteString ?? "-")   Title: \(tab.state.title)"
    NSAttributedString(
      string: caption,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
      ]
    ).draw(at: NSPoint(x: 12, y: contentView.isFlipped ? 6 : contentView.bounds.height - 22))
    composite.unlockFocus()
    guard let tiff = composite.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else {
      throw BrowserError.snapshotFailed("PNG encoding failed.")
    }
    try png.write(to: url)
  }
}

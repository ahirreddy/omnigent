import CoreGraphics
import Foundation
import OmnigentViewTesting
import Testing

@testable import OmnigentBrowser

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Annotate's picker on the real system engine, in its own content world.
@MainActor
@Suite("Design tools on WebKit", .serialized)
struct DesignPickerWebKitTests {
  init() { SystemSideEffects.install() }

  @Test("the picker reads the element at a point, where the page's scripts can't reach it")
  func pickerRunsInItsOwnWorld() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "DesignPickerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let page = directory.appending(path: "page.html")
    // The page breaks the built-ins the picker calls, in its own world.
    try """
    <!doctype html><title>Picker</title><body style="margin:0">
    <button id=go class="primary large" data-testid=buy aria-label="Buy now"
      style="position:absolute;left:0;top:0;width:200px;height:100px">Buy</button>
    <script>JSON.stringify = () => 'tampered'; document.elementFromPoint = () => null;</script>
    </body>
    """.write(to: page, atomically: true, encoding: .utf8)
    let tab = try SystemBrowserEngine().makeTab(
      profile: .ephemeral("design-picker"), initialURL: page)
    defer { tab.close() }
    tab.platformView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    #expect(try await waitUntil { !tab.state.isLoading && tab.state.title == "Picker" })
    #expect(tab.evaluatesInIsolatedWorld)

    let script = try #require(BrowserDesignPicker.script(at: CGPoint(x: 0.1, y: 0.1)))
    let hit = try #require(
      try BrowserDesignPicker.hit(from: try await tab.evaluateIsolatedJavaScript(script)))
    #expect(hit.element.tag == "button" && hit.element.id == "#go")
    #expect(hit.element.classes == ".primary.large" && hit.element.testID == "buy")
    #expect(hit.element.ariaLabel == "Buy now" && hit.element.text == "Buy")
    #expect(hit.rect == CGRect(x: 0, y: 0, width: 200, height: 100))
    #expect(hit.viewport == CGSize(width: 400, height: 300))
    // The same element answers with the same key; the page never sees the picker's globals.
    let again = try #require(
      try BrowserDesignPicker.hit(from: try await tab.evaluateIsolatedJavaScript(script)))
    #expect(again.isSameElement(as: hit))
    #expect(
      try await tab.evaluateJavaScript("typeof window.omnigentElementNext") == .string("undefined"))
    // Below the button is the body: no element.
    let below = try #require(BrowserDesignPicker.script(at: CGPoint(x: 0.9, y: 0.9)))
    #expect(
      try BrowserDesignPicker.hit(from: try await tab.evaluateIsolatedJavaScript(below)) == nil)
  }

  @Test("the page says where it sits as it scrolls and zooms, for Draw's marks")
  func viewportFollowsScrollAndZoom() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "DesignViewportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let page = directory.appending(path: "page.html")
    try """
    <!doctype html><title>Viewport</title><body style="margin:0;height:3000px"></body>
    """.write(to: page, atomically: true, encoding: .utf8)
    let tab = try SystemBrowserEngine().makeTab(
      profile: .ephemeral("design-viewport"), initialURL: page)
    defer { tab.close() }
    tab.platformView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    #expect(try await waitUntil { !tab.state.isLoading && tab.state.title == "Viewport" })
    let read = { () async throws -> BrowserDesignViewport in
      try BrowserDesignViewport.viewport(
        from: try await tab.evaluateIsolatedJavaScript(BrowserDesignViewport.script))
    }
    #expect(try await read() == BrowserDesignViewport(origin: .zero, width: 400))
    _ = try await tab.evaluateJavaScript("window.scrollTo(0, 300); 0")
    #expect(try await read().origin == CGPoint(x: 0, y: 300))
    tab.setZoomFactor(2)
    var zoomed = try await read()
    for _ in 0..<100 where zoomed.width != 200 {
      try await Task.sleep(for: .milliseconds(20))
      zoomed = try await read()
    }
    #expect(zoomed.width == 200)
  }
}

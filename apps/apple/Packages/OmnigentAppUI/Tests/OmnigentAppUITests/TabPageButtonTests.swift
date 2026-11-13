import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// A button a tab's own page shows, clicked in the mounted window.
@MainActor
@Suite("Tab pages: their own buttons", .serialized, .timeLimit(.minutes(1)))
struct TabPageButtonTests {
  private static let sessionID = "demo-design"

  @Test("Show Chat on an agent browser tab with no pages goes back to the session's chat")
  func agentBrowserShowChat() async throws {
    let session = try await connectedDemo()
    let selection = WindowSelection(.session(Self.sessionID))
    let screen = OffscreenWindow(
      AppWindowRoot(session: session, selection: selection), width: 1200, height: 800)
    defer { screen.close() }
    try await pause(screen, .milliseconds(250))
    let group = try #require(session.tabs.current)
    let browser = group.open(.agentBrowser(sessionID: Self.sessionID))
    try await settle(screen, untilShowing: "No Agent Browser")
    #expect(group.selectedID == browser.id)

    try clickAccessible("Show Chat", in: screen)
    try await settle(screen, until: "the chat") {
      group.selected?.content == .chat(sessionID: Self.sessionID)
    }
    #expect(group.selected?.content == .chat(sessionID: Self.sessionID))
  }
}

/// Clicks, with a real mouse down and up, the element VoiceOver names or identifies as `name`.
/// SwiftUI builds its accessibility tree only while an assistive client asks; the request stays
/// in this process.
@MainActor
func clickAccessible<Content: View>(_ name: String, in screen: OffscreenWindow<Content>) throws {
  let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
  _ = unsafe NSApp.perform(setter, with: true, with: "AXEnhancedUserInterface")
  defer { _ = unsafe NSApp.perform(setter, with: false, with: "AXEnhancedUserInterface") }
  screen.settle(0.3)
  // SwiftUI's elements answer these by name without adopting AppKit's protocol.
  func attribute(_ key: String, of element: NSObject) -> Any? {
    element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
  }
  let window = screen.activeWindow
  var pending: [Any] = screen.allViews
  var seen = Set<ObjectIdentifier>()
  while let next = pending.popLast() {
    guard let element = next as? NSObject, seen.insert(ObjectIdentifier(element)).inserted
    else { continue }
    let names = ["accessibilityIdentifier", "accessibilityTitle", "accessibilityLabel"]
      .compactMap { attribute($0, of: element) as? String }
    let onScreen = (attribute("accessibilityFrame", of: element) as? NSValue)?.rectValue
    if names.contains(name), let onScreen, !onScreen.isEmpty, let root = window.contentView {
      let frame = root.convert(window.convertFromScreen(onScreen), from: nil)
      try screen.click(CGPoint(x: frame.midX, y: frame.midY))
      return
    }
    pending.append(contentsOf: attribute("accessibilityChildren", of: element) as? [Any] ?? [])
  }
  throw OffscreenWindowError.notFound(name)
}

#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// Holds the panel's selected comment, as the viewer does.
  private struct KeyedPanelHost: View {
    let review: FileReviewContext
    @State private var selected: String?

    var body: some View {
      FileCommentsPanel(review: review, selectedID: $selected, close: {})
    }
  }

  /// Editing a comment by keyboard: Return and Command-Return save, Escape cancels.
  @MainActor
  @Suite("File comments panel keys", .serialized)
  struct FileCommentsPanelKeyTests {
    private typealias Screen = OffscreenWindow<KeyedPanelHost>

    private func hosted(_ spy: ReviewSpy) -> Screen {
      let review = ReviewFixtures.context(comments: [ReviewFixtures.comment("open-one")], spy: spy)
      return OffscreenWindow(KeyedPanelHost(review: review), width: 340, height: 520)
    }

    /// Clicks Edit on the only comment (after Hide) and types into its field.
    private func edit(_ screen: Screen, typing text: String) async throws {
      try #require(screen.appKitButtons.count == 4, "Hide, Edit, Resolve, Delete")
      try screen.click(screen.appKitButtons[1])
      await flush(screen)
      let field = try #require(
        screen.allViews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
      try #require(field.stringValue == "Check this")
      try screen.click(field)
      try screen.type(text)
      await flush(screen)
    }

    private func isEditing(_ screen: Screen) -> Bool {
      screen.allViews.contains { ($0 as? NSTextField)?.isEditable == true }
    }

    @Test("Return in the comment's field saves the edit and closes the editor")
    func returnSaves() async throws {
      let spy = ReviewSpy()
      let screen = hosted(spy)
      defer { screen.close() }
      try await edit(screen, typing: " now")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(await settle(screen) { spy.updates.count == 1 })
      #expect(spy.updates.first?.id == "open-one")
      #expect(spy.updates.first?.open == nil)
      #expect(spy.updates.first?.body?.contains("now") == true, "\(spy.updates)")
      #expect(await settle(screen) { !isEditing(screen) })
    }

    @Test("Command-Return saves the edit too, as the Save button's key")
    func commandReturnSaves() async throws {
      let spy = ReviewSpy()
      let screen = hosted(spy)
      defer { screen.close() }
      try await edit(screen, typing: " now")
      #expect(try screen.pressShortcut("\r", keyCode: 36, modifiers: .command))
      #expect(await settle(screen) { spy.updates.count == 1 })
      #expect(spy.updates.first?.body?.contains("now") == true, "\(spy.updates)")
      #expect(await settle(screen) { !isEditing(screen) })
    }

    @Test("Escape closes the editor and leaves the comment as it was")
    func escapeCancels() async throws {
      let spy = ReviewSpy()
      let screen = hosted(spy)
      defer { screen.close() }
      try await edit(screen, typing: " now")
      #expect(isEditing(screen))
      try screen.press(keyCode: 53, characters: "\u{1B}")
      #expect(await settle(screen) { !isEditing(screen) })
      #expect(await settle(screen) { screen.appKitButtons.count == 4 }, "the actions are back")
      #expect(spy.updates.isEmpty)
      #expect(try screen.shows("Check this"))
    }
  }
#endif

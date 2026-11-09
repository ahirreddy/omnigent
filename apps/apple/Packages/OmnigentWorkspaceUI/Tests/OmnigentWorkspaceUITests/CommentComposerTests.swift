#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// Presents the composer as the viewer does, so Cancel has a sheet to close.
  private struct ComposerSheetHost: View {
    let span: FileTextSpan
    let add: (String, FileTextSpan) async throws(WorkspaceFailure) -> Void
    @State private var isOpen = false

    var body: some View {
      Button("Comment") { isOpen = true }
        .sheet(isPresented: $isOpen) { CommentComposer(span: span, add: add) }
    }
  }

  /// Writing a comment on a span.
  @MainActor
  @Suite("Comment composer", .serialized)
  struct CommentComposerTests {
    private static let span = FileTextSpan(
      path: "a.txt", start: 0, end: 3, firstLine: 2, lastLine: 4, text: "one\ntwo")

    private func hosted(_ spy: ReviewSpy) -> OffscreenWindow<CommentComposer> {
      let review = ReviewFixtures.context(spy: spy)
      return OffscreenWindow(
        CommentComposer(span: Self.span, add: review.add), width: 420, height: 260)
    }

    private func field<Content: View>(_ screen: OffscreenWindow<Content>) throws -> NSTextField {
      try #require(screen.allViews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    /// Add Comment, the last control once it's on.
    private func clickAdd<Content: View>(_ screen: OffscreenWindow<Content>) throws {
      let add = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: add.midX, y: add.midY))
    }

    @Test("Add Comment waits for text and then adds it")
    func adds() async throws {
      let spy = ReviewSpy()
      let screen = hosted(spy)
      defer { screen.close() }
      // While off, the button isn't listed: a click right of Cancel lands on it.
      let cancel = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: cancel.maxX + 50, y: cancel.midY))
      await flush(screen)
      #expect(spy.added.isEmpty, "nothing to add yet")
      try screen.click(try field(screen))
      try screen.type("Why?")
      await flush(screen)
      try clickAdd(screen)
      #expect(await settle(screen) { spy.added.count == 1 })
      #expect(spy.added.first?.0 == "Why?")
      #expect(spy.added.first?.1 == Self.span)
      let read = try shownString(screen)
      #expect(read.contains("lines 2-4"), "read: \(read)")
    }

    @Test("a failed add shows why and keeps the text")
    func fails() async throws {
      let spy = ReviewSpy()
      spy.failure = WorkspaceFailure(.server, message: "Could not comment")
      let screen = hosted(spy)
      defer { screen.close() }
      let input = try field(screen)
      try screen.click(input)
      try screen.type("Why?")
      await flush(screen)
      try clickAdd(screen)
      await flush(screen)
      let read = try shownString(screen)
      #expect(read.contains("Could not comment"), "read: \(read)")
      #expect(input.stringValue == "Why?")
      #expect(spy.added.isEmpty)
    }

    @Test("Cancel closes the sheet without adding")
    func cancels() async throws {
      let spy = ReviewSpy()
      let review = ReviewFixtures.context(spy: spy)
      let screen = OffscreenWindow(
        ComposerSheetHost(span: Self.span, add: review.add), width: 420, height: 300)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(await settle(screen) { screen.window.attachedSheet != nil })
      let cancel = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: cancel.midX, y: cancel.midY))
      #expect(await settle(screen) { screen.window.attachedSheet == nil })
      #expect(spy.added.isEmpty)
    }

    @Test("adding closes the sheet")
    func addCloses() async throws {
      let spy = ReviewSpy()
      let review = ReviewFixtures.context(spy: spy)
      let screen = OffscreenWindow(
        ComposerSheetHost(span: Self.span, add: review.add), width: 420, height: 300)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(await settle(screen) { screen.window.attachedSheet != nil })
      try screen.click(try field(screen))
      try screen.type("Why?")
      await flush(screen)
      try clickAdd(screen)
      #expect(await settle(screen) { screen.window.attachedSheet == nil })
      #expect(spy.added.first?.0 == "Why?")
    }
  }
#endif

#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// Holds the panel's selected comment, as the viewer does.
  private struct PanelHost: View {
    let review: FileReviewContext
    let close: () -> Void
    @State private var selected: String?

    init(review: FileReviewContext, close: @escaping () -> Void, selected: String?) {
      self.review = review
      self.close = close
      _selected = State(initialValue: selected)
    }

    var body: some View {
      FileCommentsPanel(review: review, selectedID: $selected, close: close)
    }
  }

  /// The comments panel: Open and Sent, Address All, and each comment's actions.
  @MainActor
  @Suite("File comments panel", .serialized)
  struct CommentsPanelTests {
    private func hosted(
      _ review: FileReviewContext, selected: String? = nil, close: @escaping () -> Void = {}
    ) -> OffscreenWindow<PanelHost> {
      OffscreenWindow(
        PanelHost(review: review, close: close, selected: selected), width: 340, height: 520)
    }

    private static let open = ReviewFixtures.comment("open-one")
    private static let sent = ReviewFixtures.comment(
      "sent-one", body: "Already sent", isOpen: false)

    /// Address All, Hide, then each comment's actions.
    private func buttons(_ screen: OffscreenWindow<PanelHost>) -> [NSButton] {
      screen.appKitButtons
    }

    @Test("Open and Sent split the comments and each counts its own")
    func tabs() async throws {
      let screen = hosted(ReviewFixtures.context(comments: [Self.open, Self.sent]))
      defer { screen.close() }
      let openText = try shownString(screen)
      #expect(openText.contains("Check this"), "read: \(openText)")
      #expect(!openText.contains("Already sent"), "read: \(openText)")
      let picker = try #require(screen.segmentedPickers.first)
      try screen.clickSegment(1, of: picker)
      // A lazy stack keeps the old card's text in the tree, hidden: its actions tell the tabs apart.
      #expect(await settle(screen) { buttons(screen).count == 3 }, "Hide, Reopen and Delete")
      let sentText = try shownString(screen)
      #expect(sentText.contains("Already sent"), "read: \(sentText)")
    }

    @Test("empty tabs say so, and a read-only viewer is told")
    func empty() throws {
      let screen = hosted(ReviewFixtures.context(canComment: false))
      defer { screen.close() }
      let read = try shownString(screen)
      #expect(read.contains("No open comments"), "read: \(read)")
      #expect(read.contains("read-only access"), "read: \(read)")
    }

    @Test("Address All sends the open comments")
    func addressAll() async throws {
      let spy = ReviewSpy()
      let screen = hosted(ReviewFixtures.context(comments: [Self.open], spy: spy))
      defer { screen.close() }
      let addressAll = try #require(screen.controlFrames.first)
      try screen.click(CGPoint(x: addressAll.midX, y: addressAll.midY))
      #expect(await settle(screen) { spy.sentAll == 1 })
    }

    @Test("a failed Address All shows the reason")
    func addressAllFails() async throws {
      let spy = ReviewSpy()
      spy.failure = WorkspaceFailure(.server, message: "Agent unavailable")
      let screen = hosted(ReviewFixtures.context(comments: [Self.open], spy: spy))
      defer { screen.close() }
      let addressAll = try #require(screen.controlFrames.first)
      try screen.click(CGPoint(x: addressAll.midX, y: addressAll.midY))
      await flush(screen)
      let read = try shownString(screen)
      #expect(read.contains("Agent unavailable"), "read: \(read)")
    }

    /// Where Address All sits: a disabled bordered button isn't among the controls.
    private static let addressAllPoint = CGPoint(x: 255, y: 20)

    @Test("Address All does nothing without open comments or a send hook")
    func addressAllOff() async throws {
      let spy = ReviewSpy()
      let none = hosted(ReviewFixtures.context(comments: [Self.sent], spy: spy))
      defer { none.close() }
      try none.click(Self.addressAllPoint)
      await flush(none)
      var review = ReviewFixtures.context(comments: [Self.open], spy: spy)
      review.sendAll = nil
      let noHook = hosted(review)
      defer { noHook.close() }
      try noHook.click(Self.addressAllPoint)
      await flush(noHook)
      #expect(spy.sentAll == 0)
      let working = hosted(ReviewFixtures.context(comments: [Self.open], spy: spy))
      defer { working.close() }
      try working.click(Self.addressAllPoint)
      #expect(await settle(working) { spy.sentAll == 1 }, "the same point reaches it when it's on")
    }

    @Test("the close button hides the panel")
    func close() throws {
      var closed = 0
      let screen = hosted(ReviewFixtures.context(comments: [Self.open]), close: { closed += 1 })
      defer { screen.close() }
      try screen.click(try #require(buttons(screen).first))
      #expect(closed == 1)
    }

    @Test("Resolve marks an open comment addressed")
    func resolve() async throws {
      let spy = ReviewSpy()
      let screen = hosted(ReviewFixtures.context(comments: [Self.open], spy: spy))
      defer { screen.close() }
      let actions = buttons(screen)
      try #require(actions.count == 4, "Hide, Edit, Resolve, Delete")
      try screen.click(actions[2])
      #expect(
        await settle(screen) {
          spy.updates == [CommentUpdate(id: "open-one", body: nil, open: false)]
        })
    }

    // A synthetic click doesn't fire a destructive borderless button, though it does a plain one.
    @Test("Delete removes a comment")
    func delete() async throws {
      let spy = ReviewSpy()
      let screen = hosted(ReviewFixtures.context(comments: [Self.open], spy: spy))
      defer { screen.close() }
      let delete = try #require(buttons(screen).last)
      #expect(delete.hasDestructiveAction)
      delete.performClick(nil)
      #expect(await settle(screen) { spy.deleted == ["open-one"] })
    }

    /// Opens the editor on the only comment, returning its field.
    private func startEditing(_ screen: OffscreenWindow<PanelHost>) async throws -> NSTextField {
      try screen.click(buttons(screen)[1])
      await flush(screen)
      return try #require(
        screen.allViews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    @Test("Edit opens a field with the text, Save sends the trimmed text")
    func edit() async throws {
      let spy = ReviewSpy()
      let screen = hosted(ReviewFixtures.context(comments: [Self.open], spy: spy))
      defer { screen.close() }
      let field = try await startEditing(screen)
      #expect(field.stringValue == "Check this")
      try screen.click(field)
      try screen.type(" please  ")
      await flush(screen)
      // Save and Cancel end the list.
      let save = try #require(screen.controlFrames.dropLast().last)
      try screen.click(CGPoint(x: save.midX, y: save.midY))
      #expect(await settle(screen) { spy.updates.count == 1 })
      #expect(spy.updates.first?.id == "open-one")
      #expect(spy.updates.first?.open == nil)
      #expect(spy.updates.first?.body?.hasSuffix("please") == true, "\(spy.updates)")
      #expect(await settle(screen) { buttons(screen).count == 4 }, "the card's actions are back")
    }

    @Test("Cancel leaves the comment as it was")
    func editCancel() async throws {
      let spy = ReviewSpy()
      let screen = hosted(ReviewFixtures.context(comments: [Self.open], spy: spy))
      defer { screen.close() }
      let field = try await startEditing(screen)
      #expect(buttons(screen).count == 1, "the actions give way to the editor")
      #expect(field.stringValue == "Check this")
      let cancel = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: cancel.midX, y: cancel.midY))
      #expect(await settle(screen) { buttons(screen).count == 4 }, "the card's actions are back")
      #expect(spy.updates.isEmpty)
    }

    @Test("a failed action reports its reason in the panel")
    func actionFails() async throws {
      let spy = ReviewSpy()
      spy.failure = WorkspaceFailure(.forbidden, message: "Not allowed here")
      let screen = hosted(ReviewFixtures.context(comments: [Self.open], spy: spy))
      defer { screen.close() }
      try screen.click(buttons(screen)[2])
      await flush(screen)
      let read = try shownString(screen)
      #expect(read.contains("Not allowed here"), "read: \(read)")
      #expect(spy.updates.isEmpty)
    }

    @Test("a sent comment offers Reopen; one the viewer didn't write can't be changed")
    func sentAndForeign() async throws {
      let spy = ReviewSpy()
      let foreign = ReviewFixtures.comment("theirs", isOpen: false, canModify: false)
      let screen = hosted(ReviewFixtures.context(comments: [foreign], spy: spy))
      defer { screen.close() }
      let picker = try #require(screen.segmentedPickers.first)
      try screen.clickSegment(1, of: picker)
      await flush(screen)
      let actions = buttons(screen)
      #expect(actions.count == 2, "Hide and Reopen: no Edit or Delete")
      try screen.click(actions[1])
      #expect(
        await settle(screen) { spy.updates == [CommentUpdate(id: "theirs", body: nil, open: true)] }
      )
    }

    @Test("a read-only viewer gets no actions on a comment")
    func readOnlyActions() throws {
      let screen = hosted(ReviewFixtures.context(comments: [Self.open], canComment: false))
      defer { screen.close() }
      #expect(buttons(screen).count == 1, "only Hide")
    }

    @Test("a long comment folds to four lines until Show more")
    func showMore() async throws {
      let long = ReviewFixtures.comment(
        "long", body: (1...12).map { "Line number \($0) of the comment" }.joined(separator: "\n"),
        anchor: "  old pond  ", author: nil)
      let screen = hosted(ReviewFixtures.context(comments: [long]))
      defer { screen.close() }
      // The cut text is still laid out, so the card's height tells folded from unfolded.
      func actionsTop() -> CGFloat {
        screen.appKitButtons.last.map { $0.convert($0.bounds, to: screen.host).minY } ?? 0
      }
      let folded = actionsTop()
      #expect(try shownString(screen).contains("Show more"))
      let showMore = try #require(buttons(screen).dropFirst().first)
      try screen.click(showMore)
      await flush(screen)
      #expect(try shownString(screen).contains("Show less"))
      #expect(actionsTop() > folded + 60, "eight more lines at about 16 points each")
    }

    @Test("selecting a sent comment from outside switches to Sent")
    func selectionSwitchesTab() async throws {
      let box = SelectionBox()
      let screen = OffscreenWindow(
        BoxedPanel(box: box, review: ReviewFixtures.context(comments: [Self.open, Self.sent])),
        width: 340, height: 520)
      defer { screen.close() }
      box.selected = "sent-one"
      await flush(screen)
      let read = try shownString(screen)
      #expect(read.contains("Already sent"), "read: \(read)")
      box.selected = "missing"
      await flush(screen)
    }

    @Test("comment times read as today, yesterday or a date")
    func times() throws {
      let calendar = Calendar(identifier: .gregorian)
      let now = Date(timeIntervalSince1970: 1_793_502_799)
      #expect(FileCommentTime.label(now, now: now, calendar: calendar).hasSuffix("Today"))
      let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
      #expect(FileCommentTime.label(yesterday, now: now, calendar: calendar).hasSuffix("Yesterday"))
      let old = try #require(calendar.date(byAdding: .day, value: -40, to: now))
      let label = FileCommentTime.label(old, now: now, calendar: calendar)
      #expect(!label.contains("Today"))
      #expect(!label.contains("Yesterday"))
    }
  }

  /// The selected comment, changed from outside the panel.
  @MainActor
  @Observable
  private final class SelectionBox {
    var selected: String?
  }

  private struct BoxedPanel: View {
    @Bindable var box: SelectionBox
    let review: FileReviewContext

    var body: some View {
      FileCommentsPanel(review: review, selectedID: $box.selected, close: {})
    }
  }
#endif

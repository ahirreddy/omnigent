#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import SwiftUI

  @testable import OmnigentWorkspaceUI

  /// One comment update a review context was asked for.
  struct CommentUpdate: Equatable {
    let id: String
    let body: String?
    // Mirrors the context's own `Bool?`: `nil` keeps the state.
    // swiftlint:disable:next discouraged_optional_boolean
    let open: Bool?
  }

  /// Records what a review context was asked to do.
  @MainActor
  final class ReviewSpy {
    var added: [(String, FileTextSpan)] = []
    var revealed: [UInt64] = []
    var attached: [FileTextSpan] = []
    var asked: [FileTextSpan] = []
    var updates: [CommentUpdate] = []
    var deleted: [String] = []
    var sentAll = 0
    var failure: WorkspaceFailure?
  }

  /// Builds review contexts and comments for the viewer tests.
  @MainActor
  enum ReviewFixtures {
    /// An editor that saves only when asked and answers `result`.
    static func editor(
      path: String = "poems/haiku.txt", text: String = "old pond\n",
      lineEnding: LineEnding = .lf, result: FileSaveResult = .saved,
      failure: WorkspaceFailure? = nil
    ) -> FileEditor {
      let write: (String, String?) async throws(WorkspaceFailure) -> FileSaveResult = { _, _ in
        if let failure { throw failure }
        await Task.yield()
        return result
      }
      let editor = FileEditor(path: path, text: text, lineEnding: lineEnding, write: write)
      editor.autosaveDelay = nil
      return editor
    }

    static func comment(
      _ id: String, line: UInt64? = 1, body: String = "Check this", anchor: String? = "old pond",
      author: String? = "ada", isOpen: Bool = true, canModify: Bool = true
    ) -> FileCommentLine {
      FileCommentLine(
        id: id, line: line, body: body, anchor: anchor, author: author,
        createdAt: Date(timeIntervalSince1970: 1_793_502_799), isOpen: isOpen, canModify: canModify)
    }

    /// A context whose every action reports to `spy`.
    static func context(
      comments: [FileCommentLine] = [], canComment: Bool = true, spy: ReviewSpy = ReviewSpy()
    ) -> FileReviewContext {
      var review = FileReviewContext(
        comments: comments, canComment: canComment,
        add: { body, span throws(WorkspaceFailure) in
          if let failure = spy.failure { throw failure }
          spy.added.append((body, span))
        },
        reveal: { spy.revealed.append($0) },
        attach: { spy.attached.append($0) },
        ask: { spy.asked.append($0) })
      review.update = { comment, body, open throws(WorkspaceFailure) in
        if let failure = spy.failure { throw failure }
        spy.updates.append(CommentUpdate(id: comment.id, body: body, open: open))
      }
      review.delete = { comment throws(WorkspaceFailure) in
        if let failure = spy.failure { throw failure }
        spy.deleted.append(comment.id)
      }
      review.sendAll = { () throws(WorkspaceFailure) in
        if let failure = spy.failure { throw failure }
        spy.sentAll += 1
      }
      return review
    }
  }

  /// Fails a test when a condition doesn't come true while the run loop turns.
  @MainActor
  func settle<Content: View>(
    _ screen: OffscreenWindow<Content>, until condition: () -> Bool
  ) -> Bool {
    for _ in 0..<40 {
      if condition() { return true }
      screen.settle(0.02)
    }
    return condition()
  }

  /// Everything a window shows as text selectable or static in AppKit views.
  @MainActor
  func textViews<Content: View>(in screen: OffscreenWindow<Content>) -> [NSTextView] {
    screen.allViews.compactMap { $0 as? NSTextView }
  }

  extension OffscreenWindow {
    /// Every control that takes a click, top to bottom then left to right: `controlFrames` lists
    /// only the bordered and plain buttons; borderless ones, menus, pickers and fields are AppKit
    /// controls of their own. The view under test must fill its window, or proxies are off.
    var controls: [CGRect] {
      var frames = controlFrames
      for view in allViews {
        let isField = (view as? NSTextField)?.isEditable == true
        if view is NSButton || view is NSSegmentedControl || isField {
          frames.append(view.convert(view.bounds, to: host))
        }
      }
      return frames.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// Clicks a control by its place in `controls`.
    func clickAny(_ index: Int) throws {
      let frames = controls
      guard frames.indices.contains(index) else {
        throw OffscreenWindowError.notFound("control \(index) of \(frames.count)")
      }
      try click(CGPoint(x: frames[index].midX, y: frames[index].midY))
    }

    /// The segmented picker found in the window, in order.
    var segmentedPickers: [NSSegmentedControl] {
      allViews.compactMap { $0 as? NSSegmentedControl }
    }

    /// Clicks a segment with a real click.
    func clickSegment(_ index: Int, of picker: NSSegmentedControl) throws {
      let frame = picker.convert(picker.bounds, to: host)
      let width = frame.width / CGFloat(max(picker.segmentCount, 1))
      try click(CGPoint(x: frame.minX + width * (CGFloat(index) + 0.5), y: frame.midY))
    }

    /// The pop-up buttons, as `Menu` and menu-style `Picker` draw themselves.
    var popUps: [NSPopUpButton] { allViews.compactMap { $0 as? NSPopUpButton } }
  }

  /// The rightmost and leftmost painted columns in a band of a rendered view.
  @MainActor
  enum InkScan {
    /// Bands of rows holding ink in the columns `xRange`, top to bottom.
    static func bands(
      _ image: NSBitmapImageRep, xRange: ClosedRange<Int>, scale: CGFloat
    ) -> [ClosedRange<Int>] {
      var bands: [ClosedRange<Int>] = []
      var start: Int?
      for row in 0..<image.pixelsHigh {
        let hasInk = xRange.contains { isInk(image, $0, row) }
        if hasInk, start == nil { start = row }
        if !hasInk, let begun = start {
          bands.append(begun...(row - 1))
          start = nil
        }
      }
      if let begun = start { bands.append(begun...(image.pixelsHigh - 1)) }
      return bands.filter { CGFloat($0.count) >= 3 * scale }
    }

    /// The last column holding ink in a band of rows.
    static func rightEdge(_ image: NSBitmapImageRep, band: ClosedRange<Int>) -> Int? {
      (0..<image.pixelsWide).reversed().first { column in
        band.contains { isInk(image, column, $0) }
      }
    }

    private static func isInk(_ image: NSBitmapImageRep, _ column: Int, _ row: Int) -> Bool {
      guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else {
        return false
      }
      let background = image.colorAt(x: image.pixelsWide - 2, y: row)?.usingColorSpace(.deviceRGB)
      return abs(color.redComponent - (background?.redComponent ?? 1)) > 0.08
    }
  }
#endif

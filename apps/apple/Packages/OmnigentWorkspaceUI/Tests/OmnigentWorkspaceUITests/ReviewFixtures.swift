#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
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

  /// Waits for a condition while tasks and the run loop proceed. A task on the main actor runs only
  /// once the test suspends, which a nested run loop alone never lets it do.
  @MainActor
  func settle<Content: View>(
    _ screen: OffscreenWindow<Content>, until condition: () -> Bool
  ) async -> Bool {
    for _ in 0..<200 {
      screen.settle(0.005)
      if condition() { return true }
      await Task.yield()
      if condition() { return true }
      do {
        try await Task.sleep(for: .milliseconds(5))
      } catch {
        return condition()
      }
    }
    screen.settle(0.005)
    return condition()
  }

  /// Lets started tasks run and the view update.
  @MainActor
  func flush<Content: View>(_ screen: OffscreenWindow<Content>) async {
    for _ in 0..<4 {
      screen.settle(0.02)
      await Task.yield()
    }
    screen.settle(0.02)
  }

  /// All the text a window draws, as one string to search.
  @MainActor
  func shownString<Content: View>(_ screen: OffscreenWindow<Content>) throws -> String {
    try screen.shownText().joined(separator: "\n")
  }

  /// Everything a window shows as text selectable or static in AppKit views.
  @MainActor
  func textViews<Content: View>(in screen: OffscreenWindow<Content>) -> [NSTextView] {
    screen.allViews.compactMap { $0 as? NSTextView }
  }

  extension OffscreenWindow {
    /// Every control that takes a click, in reading order: `controlFrames` plus the fields and
    /// segmented pickers it may leave out. The view under test must fill its window.
    var controls: [CGRect] {
      var frames = controlFrames
      for view in allViews {
        let isField = (view as? NSTextField)?.isEditable == true
        guard view is NSButton || view is NSSegmentedControl || isField else { continue }
        let frame = view.convert(view.bounds, to: host)
        let isKnown = frames.contains {
          abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2
        }
        if !isKnown { frames.append(frame) }
      }
      return frames.sorted(by: Self.inReadingOrder)
    }

    /// Left to right along a row, whose controls differ by a few points in height; else downward.
    private static func inReadingOrder(_ left: CGRect, _ right: CGRect) -> Bool {
      abs(left.midY - right.midY) < 8 ? left.minX < right.minX : left.midY < right.midY
    }

    /// Clicks a control by its place in `controls`.
    func clickAny(_ index: Int) throws {
      let frames = controls
      guard frames.indices.contains(index) else {
        throw OffscreenWindowError.notFound("control \(index) of \(frames.count)")
      }
      try click(CGPoint(x: frames[index].midX, y: frames[index].midY))
    }

    /// The borderless buttons and toggles, which AppKit draws: not menus, in layout order.
    var appKitButtons: [NSButton] {
      allViews.compactMap { $0 as? NSButton }
        .filter { !($0 is NSPopUpButton) && !$0.isHiddenOrHasHiddenAncestor }
        .sorted {
          Self.inReadingOrder($0.convert($0.bounds, to: host), $1.convert($1.bounds, to: host))
        }
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

    /// The view as it paints now.
    func bitmap() throws -> NSBitmapImageRep {
      guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw OffscreenWindowError.notFound("a bitmap")
      }
      host.cacheDisplay(in: host.bounds, to: image)
      return image
    }

    /// The context menu at a point, from whichever view under it holds one: inside a scroll view
    /// the deepest view may not be the one SwiftUI gave it to.
    func contextMenuUnder(_ point: CGPoint) throws -> NSMenu? {
      if let menu = try contextMenu(at: point) { return menu }
      let location = host.convert(point, to: nil)
      let event = NSEvent.mouseEvent(
        with: .rightMouseDown, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
      guard let event else { throw OffscreenWindowError.eventUnavailable }
      for view in allViews.reversed()
      where view.convert(view.bounds, to: host).contains(point) {
        if let menu = view.menu(for: event) { return menu }
      }
      return nil
    }

    /// The menu a `Menu` opens: its popup's by position.
    func menu(ofPopUp index: Int) throws -> NSMenu {
      let frame = popUps[index].convert(popUps[index].bounds, to: host)
      return try openMenu(CGPoint(x: frame.midX, y: frame.midY))
    }
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
      // Black text on a clear background differs only in alpha.
      return abs(color.redComponent - (background?.redComponent ?? 1)) > 0.08
        || abs(color.alphaComponent - (background?.alphaComponent ?? 1)) > 0.08
    }
  }
#endif

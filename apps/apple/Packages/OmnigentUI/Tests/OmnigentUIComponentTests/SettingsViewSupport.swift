#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI

  /// Records what a view's closures were called with, in order.
  @MainActor
  final class ActionLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
      entries.append(entry)
    }
  }

  /// A failure to find something in a sheet or dialog the view presented.
  enum PresentationError: Error, CustomStringConvertible {
    case noSheet
    case noButton(String, available: [String])

    var description: String {
      switch self {
      case .noSheet: "The view presented no sheet."
      case .noButton(let title, let available):
        "No button named \(title) in the sheet; it has \(available)."
      }
    }
  }

  extension OffscreenWindow {
    /// Lets what the view started with `Task` or `.task` run: a run loop spun inside this test's
    /// job holds them back on the main queue, so the test has to suspend.
    func letTasksRun(passes: Int = 4) async throws {
      for _ in 0..<passes {
        settle(0.01)
        try await Task.sleep(for: .milliseconds(10))
      }
      settle(0.01)
    }

    /// The sheet or dialog on this window; it sits with the window, past every display.
    var presentedSheet: NSWindow? { window.attachedSheet }

    /// The titled AppKit buttons of the presented sheet, which is how a dialog draws its choices.
    var sheetButtonTitles: [String] {
      presentedSheet.map { Self.buttons(in: $0).map(\.title) } ?? []
    }

    /// Presses a dialog's button by title.
    /// - Parameter title: The button's title.
    /// - Throws: `PresentationError` when no such button is showing.
    func pressSheetButton(_ title: String) throws {
      guard let sheet = presentedSheet else { throw PresentationError.noSheet }
      let buttons = Self.buttons(in: sheet)
      guard let button = buttons.first(where: { $0.title == title }) else {
        throw PresentationError.noButton(title, available: buttons.map(\.title))
      }
      button.performClick(nil)
      settle()
    }

    private static func buttons(in sheet: NSWindow) -> [NSButton] {
      var found: [NSButton] = []
      var pending = sheet.contentView.map { [$0] } ?? []
      while let view = pending.popLast() {
        if let button = view as? NSButton, !button.title.isEmpty { found.append(button) }
        pending.append(contentsOf: view.subviews)
      }
      return found
    }
  }
#endif

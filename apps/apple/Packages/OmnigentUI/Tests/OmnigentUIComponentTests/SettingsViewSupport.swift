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

  /// Holds a value a view edits through a binding, so a test can read what the controls wrote.
  @MainActor
  @Observable
  final class EditedValue<Value> {
    var value: Value

    init(_ value: Value) {
      self.value = value
    }

    var binding: Binding<Value> {
      Binding(get: { self.value }, set: { self.value = $0 })
    }
  }

  /// A failure to find an AppKit control in the window.
  struct MissingControl: Error, CustomStringConvertible {
    let description: String
  }

  // SwiftUI draws each control with a private AppKit class; these find them by that name.
  extension OffscreenWindow {
    private func views(named name: String) -> [NSView] {
      allViews.filter { String(describing: Swift.type(of: $0)).hasPrefix(name) }
    }

    /// Every `Toggle` drawn as a switch or checkbox, in layout order.
    var switches: [NSControl] {
      views(named: "PlatformSwitch").compactMap { $0 as? NSControl }
    }

    /// Every `TextField`, in layout order.
    var fields: [NSTextField] {
      views(named: "AppKitTextField").compactMap { $0 as? NSTextField }
    }

    /// Every `Picker` and `Menu` drawn as a pop-up button, in layout order.
    var popUps: [NSButton] {
      views(named: "SwiftUIPopupButton").compactMap { $0 as? NSButton }
    }

    /// Every segmented `Picker`, in layout order.
    var segmentedControls: [NSSegmentedControl] {
      views(named: "SwiftUISegmentedControl").compactMap { $0 as? NSSegmentedControl }
    }

    /// The frames of the plain buttons, in reading order: every control that isn't a field, picker,
    /// switch or stepper. A disabled button isn't a control, so check what clicking one did.
    var buttonFrames: [CGRect] {
      let root = activeWindow.contentView
      let others: [NSView] =
        switches + fields + popUps + segmentedControls
        + allViews.filter { $0 is NSStepper || $0 is NSDatePicker }
      let otherFrames = others.map { $0.convert($0.bounds, to: root) }
      return controlFrames.filter { frame in
        !otherFrames.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
      }
    }

    /// Clicks a plain button by its position in `buttonFrames`.
    func clickButton(at index: Int) throws {
      let frames = buttonFrames
      guard frames.indices.contains(index) else {
        throw MissingControl(description: "button \(index) of \(frames.count)")
      }
      try click(CGPoint(x: frames[index].midX, y: frames[index].midY))
    }

    /// Replaces a field's text with real key presses, as selecting all and typing does.
    func replaceText(in field: NSTextField, with text: String) throws {
      try click(field)
      field.currentEditor()?.selectAll(nil)
      if text.isEmpty {
        try press(keyCode: 51, characters: "\u{7F}")
      } else {
        try type(text)
      }
      settle(0.02)
    }

    /// Opens a pop-up and chooses one of its items, however deep.
    func choose(_ title: String, inPopUp popUp: NSButton) throws {
      let frame = popUp.convert(popUp.bounds, to: activeWindow.contentView)
      let menu = try openMenu(CGPoint(x: frame.midX, y: frame.midY))
      try choose(title, in: menu)
    }

    /// The titles a pop-up offers, separators and section headers included.
    func titles(inPopUp popUp: NSButton) throws -> [String] {
      let frame = popUp.convert(popUp.bounds, to: activeWindow.contentView)
      return try openMenu(CGPoint(x: frame.midX, y: frame.midY)).items.map(\.title)
    }

    /// Clicks a segment; a segmented picker sizes them about equally.
    func click(segment index: Int, of control: NSSegmentedControl) throws {
      let frame = control.convert(control.bounds, to: activeWindow.contentView)
      let width = frame.width / CGFloat(control.segmentCount)
      try click(CGPoint(x: frame.minX + width * (CGFloat(index) + 0.5), y: frame.midY))
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

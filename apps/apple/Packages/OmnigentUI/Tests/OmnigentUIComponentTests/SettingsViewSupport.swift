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
        .filter { !($0 is NSSecureTextField) }
    }

    /// Every `SecureField`, in layout order.
    var secureFields: [NSSecureTextField] {
      allViews.compactMap { $0 as? NSSecureTextField }
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
        switches + fields + secureFields + popUps + segmentedControls
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

    /// Sets a switch by clicking its side: a click on the right turns it on, the left off.
    func set(_ control: NSControl, isOn: Bool) throws {
      let frame = control.convert(control.bounds, to: activeWindow.contentView)
      try click(CGPoint(x: isOn ? frame.maxX - 6 : frame.minX + 6, y: frame.midY))
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
  }

  /// A settings pane in the grouped form it lives in, with its own defaults.
  @MainActor
  func settingsForm<Pane: View>(
    store: UserDefaults, width: CGFloat = 800, height: CGFloat = 800,
    @ViewBuilder _ pane: () -> Pane
  ) -> OffscreenWindow<some View> {
    SystemSideEffects.reset()
    return OffscreenWindow(
      Form { pane() }.formStyle(.grouped).defaultAppStorage(store), width: width, height: height)
  }

  /// A view as a sheet over an empty window, which is the only way its toolbar draws off screen.
  @MainActor
  func sheetScreen<Content: View>(
    store: UserDefaults? = nil, @ViewBuilder _ content: @escaping () -> Content
  ) -> OffscreenWindow<some View> {
    SystemSideEffects.reset()
    let screen = OffscreenWindow(
      Color.clear.sheet(isPresented: .constant(true), content: content)
        .defaultAppStorage(store ?? .standard), width: 800, height: 700)
    screen.settle(0.3)
    return screen
  }

  extension OffscreenWindow {
    /// A sheet's own buttons, top to bottom with its toolbar last; its navigation bar leads with an inert control.
    var sheetButtons: [CGRect] { Array(buttonFrames.dropFirst()) }

    func clickSheetButton(at index: Int) throws {
      try clickButton(at: index + 1)
    }
  }

  extension CGRect {
    /// The point a click on this frame lands on.
    var center: CGPoint { CGPoint(x: midX, y: midY) }
  }

  /// Holds an async action open until the test lets it finish.
  @MainActor
  final class AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
      isOpen = true
      for waiter in waiters { waiter.resume() }
      waiters = []
    }
  }
#endif

public import SwiftUI

#if os(macOS)
  import AppKit
#endif

extension View {
  /// Puts the keyboard in `surface`'s terminal when this view comes on screen in the focused
  /// pane, or later when the surface becomes ready, so typing reaches it without a click. A
  /// terminal leaving the screen gives the keyboard up. On iOS the user taps to type, so a tab
  /// switch never raises the software keyboard.
  /// - Parameters:
  ///   - surface: The terminal; `nil` while it is not ready.
  ///   - isShown: Whether the view is on screen, not a hidden kept tab.
  ///   - isActive: Whether it is in the window's focused pane.
  /// - Returns: The view.
  public func terminalKeyboardFocus(
    _ surface: TerminalSurfaceController?, isShown: Bool, isActive: Bool
  ) -> some View {
    #if os(macOS)
      modifier(TerminalKeyboardFocus(surface: surface, isShown: isShown, isActive: isActive))
    #else
      self
    #endif
  }
}

#if os(macOS)
  /// Whether a terminal that came on screen still takes the keyboard once it is ready. It does
  /// unless a list key showed it, a sheet is up, or the user has since moved into another place
  /// that takes typing (a text field, a page, another terminal).
  final class TerminalFocusRequest {
    /// How long a request waits, so the click or key that showed the terminal finishes and the
    /// tab it hid gives the keyboard up first.
    static let settleDelay = Duration.milliseconds(100)

    /// The window the terminal's page is in, once it is.
    weak var window: NSWindow? {
      didSet { recordBaseline() }
    }
    /// Whether the terminal takes the keyboard when it is ready.
    private(set) var isPending = false
    /// What had the keyboard when the terminal came on screen.
    private weak var baseline: AnyObject?
    private var needsBaseline = false

    /// The terminal came on screen in the focused pane, after `event`.
    func begin(after event: NSEvent?) {
      isPending = !Self.movesThroughList(event)
      needsBaseline = isPending
      recordBaseline()
    }

    /// The terminal left the screen or the focused pane.
    func cancel() {
      isPending = false
    }

    /// Gives `view` the keyboard if the request still holds.
    /// - Returns: Whether `view` has the keyboard.
    @discardableResult
    func complete(_ view: NSView) -> Bool {
      guard isPending, let window = unsafe view.window else { return false }
      isPending = false
      let current = window.firstResponder
      let movedAway = Self.owner(of: current) !== baseline && current is any NSTextInputClient
      guard window.attachedSheet == nil, current === view || !movedAway else { return false }
      return window.makeFirstResponder(view)
    }

    /// A hidden terminal gives the keyboard up, so typing reaches what is shown.
    static func release(_ view: NSView) {
      guard let window = unsafe view.window, window.firstResponder === view else { return }
      window.makeFirstResponder(nil)
    }

    /// A plain key such as an arrow moving through the sidebar keeps that list's focus; a
    /// shortcut such as Control-Tab or Shift-Command-] does not.
    static func movesThroughList(_ event: NSEvent?) -> Bool {
      guard let event, event.type == .keyDown else { return false }
      return event.modifierFlags.isDisjoint(with: [.command, .control])
    }

    /// The text field a shared field editor is editing, else `responder` itself.
    static func owner(of responder: NSResponder?) -> AnyObject? {
      if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate {
        return field
      }
      return responder
    }

    private func recordBaseline() {
      guard needsBaseline, let window else { return }
      baseline = Self.owner(of: window.firstResponder)
      needsBaseline = false
    }
  }

  /// Runs a ``TerminalFocusRequest`` each time the terminal comes on screen in the focused pane.
  private struct TerminalKeyboardFocus: ViewModifier {
    let surface: TerminalSurfaceController?
    let isShown: Bool
    let isActive: Bool
    @State private var request = TerminalFocusRequest()

    /// A focus attempt: again when the surface becomes ready or the terminal shows again.
    private struct Attempt: Equatable {
      let surface: ObjectIdentifier?
      let wantsKeyboard: Bool
    }

    func body(content: Content) -> some View {
      let wantsKeyboard = isShown && isActive
      let attempt = Attempt(
        surface: surface.map(ObjectIdentifier.init), wantsKeyboard: wantsKeyboard)
      content
        .background { FocusWindowReader(request: request) }
        .onChange(of: wantsKeyboard, initial: true) { _, wants in
          if wants { request.begin(after: NSApp.currentEvent) } else { request.cancel() }
        }
        .task(id: attempt) {
          guard wantsKeyboard, let view = surface?.view else { return }
          do {
            try await Task.sleep(for: TerminalFocusRequest.settleDelay)
          } catch {
            return
          }
          request.complete(view)
        }
        .onChange(of: isShown) { _, shown in
          if !shown, let view = surface?.view { TerminalFocusRequest.release(view) }
        }
    }
  }

  /// Tells a request which window the terminal's page is in, before its surface is ready.
  private struct FocusWindowReader: NSViewRepresentable {
    let request: TerminalFocusRequest

    func makeNSView(context: Context) -> ReaderView {
      let view = ReaderView()
      view.request = request
      return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
      weak var request: TerminalFocusRequest?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        request?.window = unsafe window
      }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
  }
#endif

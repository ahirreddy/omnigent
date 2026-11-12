import SwiftUI

#if os(macOS)
  import AppKit
#endif

extension View {
  /// The composer's focus rules: `focusRequest` focuses the editor (a menu command or the
  /// palette), a hidden kept tab gives up focus, and on iPhone a run opens with the keyboard
  /// hidden until the user taps to edit.
  /// - Parameters:
  ///   - isFocused: The editor's focus.
  ///   - focusRequest: Increments when the host asks for focus.
  /// - Returns: The view.
  func readingPostureFocus(_ isFocused: FocusState<Bool>.Binding, focusRequest: Int) -> some View {
    modifier(ReadingPostureFocus(isFocused: isFocused, focusRequest: focusRequest))
  }
}

extension View {
  /// Keeps the keyboard and the pointer out of an editor that takes no input (a read-only or
  /// archived session). `disabled` alone leaves a text editor that has the keyboard typing.
  /// - Parameters:
  ///   - isEditable: Whether the editor takes input.
  ///   - focus: The editor's focus.
  /// - Returns: The view.
  func locksEditor(unless isEditable: Bool, focus: FocusState<Bool>.Binding) -> some View {
    modifier(EditorLock(isEditable: isEditable, isFocused: focus))
  }
}

private struct EditorLock: ViewModifier {
  let isEditable: Bool
  let isFocused: FocusState<Bool>.Binding
  /// The keyboard was asked for while locked (a session still loading when it comes on
  /// screen); the editor gets it once it takes input.
  @State private var owesFocus = false

  func body(content: Content) -> some View {
    content
      .disabled(!isEditable)
      .allowsHitTesting(isEditable)
      .onChange(of: isFocused.wrappedValue, initial: true) { _, focused in
        guard focused, !isEditable else { return }
        owesFocus = true
        isFocused.wrappedValue = false
      }
      .onChange(of: isEditable) { _, editable in
        if !editable {
          if isFocused.wrappedValue { isFocused.wrappedValue = false }
        } else if owesFocus {
          owesFocus = false
          if Self.collectsOwedFocus { isFocused.wrappedValue = true }
        }
      }
  }

  /// Whether the keyboard is still free for the editor: not when a text field took it while
  /// the session loaded (a rename begun in the sidebar).
  private static var collectsOwedFocus: Bool {
    #if os(macOS)
      OwedFocus.isFree(firstResponder: NSApp.keyWindow?.firstResponder)
    #else
      true
    #endif
  }
}

#if os(macOS)
  enum OwedFocus {
    /// Whether nothing is being typed into: a text field's editor is not the first responder.
    static func isFree(firstResponder: NSResponder?) -> Bool {
      !(firstResponder is NSText)
    }
  }
#endif

/// The key press that brought a composer on screen, and whether the keyboard stays where it was.
enum ComposerShowingKey {
  /// A plain key (an arrow moving through the sidebar) keeps the keyboard in its list. A Command
  /// shortcut (New Session, the next session) asked for the page, so its composer takes it.
  static func keepsFocusElsewhere(isKeyDown: Bool, hasCommand: Bool) -> Bool {
    isKeyDown && !hasCommand
  }
}

private struct ReadingPostureFocus: ViewModifier {
  let isFocused: FocusState<Bool>.Binding
  let focusRequest: Int
  /// UIKit makes the editor first responder again when a screen left with the keyboard up
  /// reappears; that restoration is refused for a moment after appearing. A touch on the
  /// composer ends the moment, so a deliberate first tap still focuses.
  @State private var refusesRestoredFocusUntil = Date.distantPast
  /// When focus was last refused, in case the tap that caused it is reported after the refusal.
  @State private var refusedAt = Date.distantPast
  @Environment(\.isTabContentHidden) private var isHiddenTab
  @Environment(\.isActiveTabPane) private var isActivePane

  #if os(macOS)
    /// Takes the keyboard when the composer comes on screen, so typing reaches it. Moving through
    /// the sidebar with the keyboard keeps its focus; the wait lets a click on a list row finish.
    private func focusOnShowing() async {
      let event = NSApp.currentEvent
      let keepsFocus = ComposerShowingKey.keepsFocusElsewhere(
        isKeyDown: event?.type == .keyDown,
        hasCommand: event?.modifierFlags.contains(.command) ?? false)
      guard !isHiddenTab, isActivePane, !keepsFocus else { return }
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        return
      }
      isFocused.wrappedValue = true
    }
  #endif

  func body(content: Content) -> some View {
    content
      #if os(macOS)
        .task(id: isHiddenTab) { await focusOnShowing() }
      #endif
      .onChange(of: focusRequest) { _, _ in
        refusesRestoredFocusUntil = .distantPast
        isFocused.wrappedValue = true
      }
      // A kept tab leaving the screen gives up the keyboard, so typing reaches the shown tab.
      .onChange(of: isHiddenTab) { _, hidden in
        if hidden, isFocused.wrappedValue { isFocused.wrappedValue = false }
      }
      #if os(iOS)
        .onAppear {
          refusesRestoredFocusUntil = .now.addingTimeInterval(1)
          isFocused.wrappedValue = false
        }
        .onChange(of: isFocused.wrappedValue) { _, focused in
          if focused, Date.now < refusesRestoredFocusUntil {
            refusedAt = .now
            isFocused.wrappedValue = false
          }
        }
        .simultaneousGesture(
          TapGesture().onEnded {
            refusesRestoredFocusUntil = .distantPast
            if Date.now.timeIntervalSince(refusedAt) < 0.3 { isFocused.wrappedValue = true }
          })
      #endif
  }
}

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
      guard !isHiddenTab, isActivePane, NSApp.currentEvent?.type != .keyDown else { return }
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

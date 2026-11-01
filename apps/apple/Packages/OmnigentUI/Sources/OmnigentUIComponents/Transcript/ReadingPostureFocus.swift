import SwiftUI

extension View {
  /// The composer's focus rules: `focusRequest` focuses the editor (a menu command or the
  /// palette), and on iPhone a run opens with the keyboard hidden until the user taps to edit.
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
  /// reappears; that restoration is refused for a moment after appearing.
  @State private var refusesRestoredFocusUntil = Date.distantPast

  func body(content: Content) -> some View {
    content
      .onChange(of: focusRequest) { _, _ in
        refusesRestoredFocusUntil = .distantPast
        isFocused.wrappedValue = true
      }
      #if os(iOS)
        .onAppear {
          refusesRestoredFocusUntil = .now.addingTimeInterval(1)
          isFocused.wrappedValue = false
        }
        .onChange(of: isFocused.wrappedValue) { _, focused in
          if focused, Date.now < refusesRestoredFocusUntil { isFocused.wrappedValue = false }
        }
      #endif
  }
}

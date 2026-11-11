public import SwiftUI

nonisolated extension EnvironmentValues {
  /// Whether the window is really the active one. Views under
  /// ``SwiftUICore/View/keepsActiveLook()`` always look active, so the few that must know (a
  /// looping mark that rests in a background window) read this.
  @Entry public var windowIsActive = true
}

extension View {
  /// Keeps the active look while another window is in front: nothing in the view greys out
  /// when its window loses focus. The window's real state stays in `windowIsActive`.
  /// - Returns: The view, always drawn as active.
  public func keepsActiveLook() -> some View {
    #if os(macOS)
      modifier(ActiveLook())
    #else
      self
    #endif
  }
}

#if os(macOS)
  private struct ActiveLook: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
      content
        .environment(\.windowIsActive, appearsActive)
        .environment(\.appearsActive, true)
        .environment(\.controlActiveState, .key)
    }
  }
#endif

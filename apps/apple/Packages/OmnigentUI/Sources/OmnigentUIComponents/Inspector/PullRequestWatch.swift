public import SwiftUI

extension View {
  /// Runs `watch` while the view is on screen: not in a hidden tab, and not while its scene is
  /// in the background, where the web's polls pause too. Its argument says whether the view
  /// shows again after being hidden, so it re-reads before waiting.
  /// - Parameter watch: Work that runs until its task is cancelled; `nil` runs nothing.
  /// - Returns: The view.
  public func whileVisible(_ watch: (@MainActor (_ resumed: Bool) async -> Void)?) -> some View {
    modifier(WhileVisible(watch: watch))
  }
}

private struct WhileVisible: ViewModifier {
  let watch: (@MainActor (_ resumed: Bool) async -> Void)?

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.isTabContentHidden) private var isTabContentHidden
  @State private var wasHidden = false

  func body(content: Content) -> some View {
    let visible = scenePhase != .background && !isTabContentHidden
    content.task(id: visible) {
      guard let watch else { return }
      guard visible else {
        wasHidden = true
        return
      }
      let resumed = wasHidden
      wasHidden = false
      await watch(resumed)
    }
  }
}

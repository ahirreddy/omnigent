public import SwiftUI

/// New Tab, the tab overview menu and the tabs' issue: after the tabs in a strip of their own, or
/// beside the titlebar's trailing items when the strip sits in the titlebar.
public struct TabStripControls: View {
  private let state: TabsState
  private let actions: TabActions

  @State private var showsOverview = false

  /// Creates the controls.
  /// - Parameters:
  ///   - state: The window's tabs.
  ///   - actions: What the tabs do.
  public init(state: TabsState, actions: TabActions) {
    self.state = state
    self.actions = actions
  }

  /// The controls.
  public var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Button(action: actions.newTab) {
        Image(systemName: "plus")
          .font(.system(size: 13, weight: .medium))
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
          .touchTarget(width: 26, height: 26)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .hoverHighlight()
      .help("New tab (Command-T)")
      .accessibilityLabel("New tab")
      .accessibilityIdentifier("tab-new")
      .contextMenu { NewTabMenu(actions: actions) }
      TabOverviewMenu(state: state, actions: actions) { showsOverview = true }
      if let issue = state.issue {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(Theme.warning)
          .help(issue)
          .accessibilityLabel(issue)
          .accessibilityIdentifier("tab-issue")
      }
    }
    .tabOverview(isPresented: $showsOverview, state: state, actions: actions)
  }
}

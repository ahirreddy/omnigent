#if os(macOS)
  import Foundation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The CLI composer with a real draft, the way a screen hosts it.
  struct CLIComposerHost: View {
    let state: ComposerViewState
    let actions: ComposerActions
    let layoutStyle: ComposerLayoutStyle
    let preferences: TranscriptPreferences
    @State private var draft: String

    init(
      state: ComposerViewState, actions: ComposerActions, layoutStyle: ComposerLayoutStyle,
      preferences: TranscriptPreferences, draft: String
    ) {
      self.state = state
      self.actions = actions
      self.layoutStyle = layoutStyle
      self.preferences = preferences
      _draft = State(initialValue: draft)
    }

    var body: some View {
      CLIComposer(draft: $draft, state: state, actions: actions)
        .environment(\.composerLayoutStyle, layoutStyle)
        .transcriptAppearance(preferences.appearance(style: .cli))
    }
  }

  /// Hosts the CLI composer off screen with its own preferences.
  @MainActor
  func cliComposerScreen(
    _ state: ComposerViewState, actions: ComposerActions, layoutStyle: ComposerLayoutStyle = .card,
    layout: LayoutWidth = .regular, draft: String = "", width: CGFloat = 800
  ) throws -> OffscreenWindow<AnyView> {
    let defaults = try #require(UserDefaults(suiteName: "cli-composer-\(UUID().uuidString)"))
    return transcriptScreen(
      CLIComposerHost(
        state: state, actions: actions, layoutStyle: layoutStyle,
        preferences: TranscriptPreferences(defaults: defaults), draft: draft),
      width: width, height: 300, layout: layout)
  }
#endif

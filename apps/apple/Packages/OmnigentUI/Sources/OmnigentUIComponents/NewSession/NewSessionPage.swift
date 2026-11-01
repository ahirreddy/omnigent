public import SwiftUI

/// The web's new-session page, in the detail column: Otto with tracking eyes, "What should we
/// build?", and the composer in start mode with the context tray (directory and worktree), the
/// Host and Permission chips and the model picker. Start creates the session and sends the first
/// message immediately.
public struct NewSessionPage: View {
  @Binding private var draft: String
  private let composer: ComposerViewState
  private let actions: ComposerActions
  private let heading: String
  private let importSessions: (@MainActor () -> Void)?

  @State private var gaze: CGSize = .zero
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the page.
  /// - Parameters:
  ///   - draft: The first message.
  ///   - composer: The composer (purpose `.start`), with its tray, hosts and modes.
  ///   - actions: Composer actions; `send` starts the session.
  ///   - heading: The heading; servers and projects can replace it.
  ///   - importSessions: "Import your recent sessions", shown when the list is empty.
  public init(
    draft: Binding<String>, composer: ComposerViewState, actions: ComposerActions,
    heading: String = "What should we build?",
    importSessions: (@MainActor () -> Void)? = nil
  ) {
    _draft = draft
    self.composer = composer
    self.actions = actions
    self.heading = heading
    self.importSessions = importSessions
  }

  /// The page.
  public var body: some View {
    VStack(spacing: 0) {
      if layoutWidth == .regular { Spacer(minLength: 40) }
      VStack(spacing: 14) {
        OttoView(gaze: gaze)
          .frame(width: 56, height: 56)
        Text(heading)
          .font(.largeTitle.weight(.semibold))
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
      }
      .padding(.bottom, 12)
      if layoutWidth == .compact { Spacer(minLength: 20) }
      ComposerView(draft: $draft, state: composer, actions: actions)
      if let importSessions {
        Button(
          "Import your recent sessions", systemImage: "square.and.arrow.down",
          action: importSessions
        )
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .accessibilityIdentifier("new-session-import")
      }
      if layoutWidth == .regular { Spacer(minLength: 80) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themeCanvas()
    .onContinuousHover(coordinateSpace: .local) { phase in
      if case .active(let location) = phase {
        gaze = CGSize(width: (location.x - 400) / 400, height: (location.y - 200) / 300)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-session-page")
    .navigationTitle("New session")
  }
}

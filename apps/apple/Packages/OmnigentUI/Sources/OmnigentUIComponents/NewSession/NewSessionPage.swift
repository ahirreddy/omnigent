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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: Theme.Spacing.extraLarge) {
          VStack(spacing: Theme.Spacing.large) {
            OttoView(gaze: gaze)
              .frame(width: Theme.Control.mascot, height: Theme.Control.mascot)
            Text(heading)
              .font(layoutWidth == .compact ? Theme.Typography.title : .largeTitle.weight(.medium))
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
          }
          .padding(.horizontal, Theme.Spacing.extraLarge)
          ComposerView(draft: $draft, state: composer, actions: actions)
          if let importSessions {
            Button(
              "Import your recent sessions", systemImage: "square.and.arrow.down",
              action: importSessions
            )
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("new-session-import")
          }
        }
        .padding(.vertical, Theme.Spacing.section)
        .frame(minHeight: geometry.size.height)
        .onContinuousHover(coordinateSpace: .local) { phase in
          guard !reduceMotion else { return }
          switch phase {
          case .active(let location):
            gaze = CGSize(
              width: (location.x / max(geometry.size.width, 1) - 0.5) * 2,
              height: (location.y / max(geometry.size.height, 1) - 0.5) * 2)
          case .ended: gaze = .zero
          }
        }
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .themeCanvas()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-session-page")
    .navigationTitle("New session")
  }
}

public import SwiftUI

/// The web's new-session page, in the detail column: Otto with tracking eyes, "What should we
/// work on?" (the empty conversation's heading too), and the composer in start mode with the
/// context tray (where it will run, the folder and worktree), the Host and approval-mode chips
/// and the agent, model and effort picker. On a phone the composer stays on the keyboard. An
/// unavailable destination shows in the context row before the first send. Start creates the
/// session and sends the first message immediately.
public struct NewSessionPage: View {
  @Binding private var draft: String
  private let composer: ComposerViewState
  private let actions: ComposerActions
  private let heading: String
  private let importSessions: (@MainActor () -> Void)?
  private let showsContextDetails: Bool

  @State private var gaze: CGSize = .zero
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.composerLayoutStyle) private var composerLayout
  @Environment(\.isActiveTabPane) private var isActivePane

  /// A phone: the composer stays on the keyboard.
  private var pinsComposer: Bool { layoutWidth == .compact && composerLayout == .touch }

  /// Creates the page.
  /// - Parameters:
  ///   - draft: The first message.
  ///   - composer: The composer (purpose `.start`), with its tray, hosts and modes.
  ///   - actions: Composer actions; `send` starts the session.
  ///   - heading: The heading; servers and projects can replace it.
  ///   - importSessions: "Import your recent sessions", shown when the list is empty.
  ///   - showsContextDetails: Open the execution-context details (playground captures).
  public init(
    draft: Binding<String>, composer: ComposerViewState, actions: ComposerActions,
    heading: String = "What should we work on?",
    importSessions: (@MainActor () -> Void)? = nil, showsContextDetails: Bool = false
  ) {
    _draft = draft
    self.composer = composer
    self.actions = actions
    self.heading = heading
    self.importSessions = importSessions
    self.showsContextDetails = showsContextDetails
  }

  /// The page.
  public var body: some View {
    Group {
      // A phone keeps the composer on the keyboard, as ChatGPT does; Otto and the heading
      // center in the space above it.
      if pinsComposer {
        GeometryReader { geometry in
          ScrollView { hero(in: geometry.size).frame(minHeight: geometry.size.height) }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          // About 10 pt from the keyboard with the composer's own padding.
          composerView.padding(.bottom, Theme.Spacing.extraSmall)
        }
      } else {
        GeometryReader { geometry in
          ScrollView {
            VStack(spacing: Theme.Spacing.extraLarge) {
              hero(in: geometry.size)
              composerView
              importButton
            }
            .padding(.vertical, Theme.Spacing.section)
            .frame(minHeight: geometry.size.height)
          }
          .scrollBounceBehavior(.basedOnSize)
        }
      }
    }
    .themeCanvas()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-session-page")
    .navigationTitle("New session")
  }

  private var composerView: some View {
    ComposerView(
      draft: $draft, state: composer, actions: actions, showsContextDetails: showsContextDetails)
  }

  @ViewBuilder private var importButton: some View {
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

  /// Otto with tracking eyes and the heading (and, on a phone, the import button).
  private func hero(in size: CGSize) -> some View {
    VStack(spacing: Theme.Spacing.large) {
      // Once per window: a split's other pane keeps the space but not the mascot.
      OttoView(gaze: gaze)
        .frame(width: Theme.Control.mascot, height: Theme.Control.mascot)
        .opacity(isActivePane ? 1 : 0)
      Text(heading)
        .font(layoutWidth == .compact ? Theme.Typography.title : .largeTitle.weight(.medium))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      if pinsComposer { importButton }
    }
    .padding(.horizontal, Theme.Spacing.extraLarge)
    .padding(.vertical, pinsComposer ? Theme.Spacing.large : 0)
    .frame(maxWidth: .infinity)
    .onContinuousHover(coordinateSpace: .local) { phase in
      guard !reduceMotion else { return }
      switch phase {
      case .active(let location):
        gaze = CGSize(
          width: (location.x / max(size.width, 1) - 0.5) * 2,
          height: (location.y / max(size.height, 1) - 0.5) * 2)
      case .ended: gaze = .zero
      }
    }
  }
}

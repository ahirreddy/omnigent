public import SwiftUI

/// The side chat's words, shared by a new side chat and a started one (web `SideChatPane`).
nonisolated public enum SideChatCopy {
  /// The empty state's heading.
  public static let title = "Side chat"
  /// The empty state's line.
  public static let detail = "Ask a question here without affecting the main conversation."
  /// The composer's placeholder.
  public static let placeholder = "Ask a side question\u{2026}"
  /// The agent is taking long to start a side chat it was asked for.
  public static let stillStarting =
    "Still waiting for the agent to start the side chat. It opens here when it does."
}

/// A side chat with nothing in it yet: what it is for, under the side chat icon.
struct SideChatIntro: View {
  var body: some View {
    VStack(spacing: Theme.Spacing.small) {
      Image(systemName: TabKind.sideChat.systemImage)
        .font(.title)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(SideChatCopy.title).font(Theme.Typography.title)
      Text(SideChatCopy.detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Theme.Spacing.section * 2)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("sidechat-empty")
  }
}

/// A side question that went to the session's own agent, which has not reported the side chat
/// it forks for it yet: the question as sent, and that it is starting, or still waited for.
struct SideChatAsked: View {
  let question: String
  var isLate = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      MessageRowView(
        row: Row(id: "sidechat-asked", role: .user, text: question),
        decoration: MessageDecoration())
      TurnStatusRow {
        TypingIndicator()
      } label: {
        Text(isLate ? SideChatCopy.stillStarting : "Starting the side chat\u{2026}")
      }
      .frame(minHeight: Theme.Control.target)
      .accessibilityIdentifier("sidechat-starting")
    }
    .padding(Theme.Spacing.large)
  }
}

/// The model and effort a new side chat starts on, chosen in its composer before the first
/// message (web `SideChatSettings` on a pending tab).
public struct PendingSideChatSettings {
  /// The menus, from the session it forks, with the choice made here.
  public var configuration: ComposerConfiguration
  /// Choose a model (`nil` keeps the session's).
  public var selectModel: @MainActor (String?) -> Void
  /// Choose an effort (`nil` keeps the session's).
  public var selectEffort: @MainActor (String?) -> Void

  /// Creates the settings.
  /// - Parameters:
  ///   - configuration: The menus.
  ///   - selectModel: Choose a model.
  ///   - selectEffort: Choose an effort.
  public init(
    configuration: ComposerConfiguration, selectModel: @escaping @MainActor (String?) -> Void,
    selectEffort: @escaping @MainActor (String?) -> Void
  ) {
    self.configuration = configuration
    self.selectModel = selectModel
    self.selectEffort = selectEffort
  }
}

/// A new side chat before its first message: no session exists yet, so it has only a draft. The
/// first send creates the side chat (web pending side-chat tab).
public struct PendingSideChatView: View {
  @Binding private var draft: String
  private let parent: CreatingSession
  private let isStarting: Bool
  private let failure: String?
  private let asked: String?
  private let isLate: Bool
  private let send: @MainActor () -> Void
  private let dismissFailure: @MainActor () -> Void
  private let openParent: @MainActor (String) -> Void
  private let settings: PendingSideChatSettings?

  /// Creates the view.
  /// - Parameters:
  ///   - draft: The first message.
  ///   - parent: The session the side chat forks.
  ///   - isStarting: The side chat is being created.
  ///   - failure: Why creating it failed; the draft is kept.
  ///   - asked: The first message, once the session's own agent was asked to fork the side
  ///     chat for it and until it reports the fork.
  ///   - isLate: The agent is taking long to report that fork.
  ///   - send: Creates the side chat with the draft as its first message.
  ///   - dismissFailure: Hides the failure.
  ///   - openParent: Shows the parent's chat.
  ///   - settings: The model and effort it starts on; `nil` where the agent forks it itself.
  public init(
    draft: Binding<String>, parent: CreatingSession, isStarting: Bool, failure: String?,
    asked: String? = nil, isLate: Bool = false,
    send: @escaping @MainActor () -> Void, dismissFailure: @escaping @MainActor () -> Void,
    openParent: @escaping @MainActor (String) -> Void, settings: PendingSideChatSettings? = nil
  ) {
    _draft = draft
    self.parent = parent
    self.isStarting = isStarting
    self.failure = failure
    self.asked = asked
    self.isLate = isLate
    self.send = send
    self.dismissFailure = dismissFailure
    self.openParent = openParent
    self.settings = settings
  }

  /// The page.
  public var body: some View {
    ScrollView {
      Group {
        if let asked { SideChatAsked(question: asked, isLate: isLate) } else { SideChatIntro() }
      }
      .frame(maxWidth: Theme.transcriptWidth)
      .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(asked == nil ? .center : .bottom)
    .safeAreaBar(edge: .bottom, spacing: 0) {
      TranscriptComposer(
        draft: ComposerDraft($draft), state: composerState,
        actions: ComposerActions(
          send: send, selectModel: settings?.selectModel, selectEffort: settings?.selectEffort,
          dismissDeliveryError: dismissFailure),
        focusRequest: 1, hasTextChanged: { _ in })
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      SessionOriginBar(relation: .sideChatOf, origin: parent, open: openParent)
    }
    .themeCanvas()
    .cliPalette()
    .navigationTitle(SideChatCopy.title)
    .accessibilityIdentifier("sidechat-pending")
  }

  private var composerState: ComposerViewState {
    let delivery: DeliveryState =
      if isStarting { .sending } else if let failure { .failed(message: failure) } else { .idle }
    var state = ComposerViewState(
      delivery: delivery, acceptsAttachments: false, placeholder: SideChatCopy.placeholder)
    state.configuration = settings?.configuration
    return state
  }
}

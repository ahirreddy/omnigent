public import SwiftUI

/// The side chat's words, shared by a new side chat and a started one (web `SideChatPane`).
nonisolated public enum SideChatCopy {
  /// The empty state's heading.
  public static let title = "Side chat"
  /// The empty state's line.
  public static let detail = "Ask a question here without affecting the main conversation."
  /// The composer's placeholder.
  public static let placeholder = "Ask a side question\u{2026}"
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

/// A new side chat before its first message: no session exists yet, so it has only a draft. The
/// first send creates the side chat (web pending side-chat tab).
public struct PendingSideChatView: View {
  @Binding private var draft: String
  private let parent: CreatingSession
  private let isStarting: Bool
  private let failure: String?
  private let send: @MainActor () -> Void
  private let dismissFailure: @MainActor () -> Void
  private let openParent: @MainActor (String) -> Void

  /// Creates the view.
  /// - Parameters:
  ///   - draft: The first message.
  ///   - parent: The session the side chat forks.
  ///   - isStarting: The side chat is being created.
  ///   - failure: Why creating it failed; the draft is kept.
  ///   - send: Creates the side chat with the draft as its first message.
  ///   - dismissFailure: Hides the failure.
  ///   - openParent: Shows the parent's chat.
  public init(
    draft: Binding<String>, parent: CreatingSession, isStarting: Bool, failure: String?,
    send: @escaping @MainActor () -> Void, dismissFailure: @escaping @MainActor () -> Void,
    openParent: @escaping @MainActor (String) -> Void
  ) {
    _draft = draft
    self.parent = parent
    self.isStarting = isStarting
    self.failure = failure
    self.send = send
    self.dismissFailure = dismissFailure
    self.openParent = openParent
  }

  /// The page.
  public var body: some View {
    ScrollView {
      SideChatIntro()
        .frame(maxWidth: Theme.transcriptWidth)
        .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(.center)
    .safeAreaBar(edge: .bottom, spacing: 0) {
      TranscriptComposer(
        draft: ComposerDraft($draft), state: composerState,
        actions: ComposerActions(send: send, dismissDeliveryError: dismissFailure),
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
    return ComposerViewState(
      delivery: delivery, acceptsAttachments: false, placeholder: SideChatCopy.placeholder)
  }
}

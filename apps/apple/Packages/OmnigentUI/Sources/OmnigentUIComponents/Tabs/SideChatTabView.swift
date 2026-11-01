public import SwiftUI

/// A side question opened from the transcript into its own tab.
nonisolated public struct SideChatTabState: Hashable, Sendable {
  /// Where the side chat stands.
  public enum Phase: Hashable, Sendable {
    /// The conversation is still loading.
    case loading
    /// The question and its answer.
    case loaded(question: String, answer: String?)
    /// The transcript no longer has the row.
    case unavailable
  }

  /// The question and answer, or why they are missing.
  public var phase: Phase
  /// The session the side chat belongs to.
  public var sessionTitle: String

  /// Creates the state.
  /// - Parameters:
  ///   - phase: The content.
  ///   - sessionTitle: The owning session's title.
  public init(phase: Phase, sessionTitle: String) {
    self.phase = phase
    self.sessionTitle = sessionTitle
  }
}

/// A side question and its answer as a page, with a way back to the conversation.
public struct SideChatTabView: View {
  private let state: SideChatTabState
  private let openConversation: @MainActor () -> Void

  /// Creates the view.
  /// - Parameters:
  ///   - state: The side chat.
  ///   - openConversation: Shows the owning conversation.
  public init(state: SideChatTabState, openConversation: @escaping @MainActor () -> Void) {
    self.state = state
    self.openConversation = openConversation
  }

  /// The page.
  public var body: some View {
    Group {
      switch state.phase {
      case .loading:
        ProgressView("Loading the side chat\u{2026}")
      case .unavailable:
        ContentUnavailableView {
          Label("Side Chat Unavailable", systemImage: TabKind.sideChat.systemImage)
        } description: {
          Text("This side question is no longer in the conversation's transcript.")
        } actions: {
          Button("Open Conversation", action: openConversation)
        }
      case .loaded(let question, let answer):
        content(question: question, answer: answer)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themeCanvas()
    .navigationTitle("Side Chat")
    .accessibilityIdentifier("sidechat-tab")
  }

  private func content(question: String, answer: String?) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        Button(action: openConversation) {
          Label("From \(state.sessionTitle)", systemImage: "arrow.turn.up.left")
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Open the conversation")
        .accessibilityIdentifier("sidechat-tab-origin")
        Text(verbatim: question)
          .font(Theme.Typography.title)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if let answer {
          MarkdownView(answer)
        } else {
          Text("No answer yet.").foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: Theme.transcriptWidth, alignment: .leading)
      .padding(Theme.Spacing.section)
      .frame(maxWidth: .infinity)
    }
  }
}

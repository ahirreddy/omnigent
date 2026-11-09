import OmnigentPlatform
import SwiftUI

/// The empty conversation: Otto, one heading shared with the new-session page, and a second line
/// that says what to do next. In a split window only the focused pane shows Otto.
struct EmptyTranscriptView: View {
  let state: ConversationViewState
  @Environment(\.isActiveTabPane) private var isActivePane

  var body: some View {
    // While the first read is in flight the empty state would flash "What should we work on?"
    // before the messages arrive: say the conversation is loading instead.
    if state.isHydrating {
      loading
    } else if Self.isEmpty(state) {
      // A side chat hides the history it copied, so it starts empty like a new one.
      if state.header.settings?.sideChatSourceId != nil, !state.hasMoreHistory {
        SideChatIntro()
      } else {
        content
      }
    }
  }

  /// Whether the conversation is known to be empty, not still loading its history.
  static func isEmpty(_ state: ConversationViewState) -> Bool {
    !state.isLoadingHistory && !state.isHydrating && state.turnStartedAt == nil
  }

  private var loading: some View {
    ProgressView("Loading conversation\u{2026}")
      .frame(maxWidth: .infinity)
      .padding(.vertical, Theme.Spacing.section * 2)
      .accessibilityIdentifier("transcript-loading")
  }

  private var content: some View {
    VStack(spacing: Theme.Spacing.small) {
      if !state.hasMoreHistory {
        OttoView()
          .frame(width: Theme.Control.mascot, height: Theme.Control.mascot)
          .opacity(isActivePane ? 1 : 0)
          .accessibilityHidden(true)
      }
      Text(Self.title(state)).font(Theme.Typography.title)
        .multilineTextAlignment(.center)
      Text(Self.detail(state))
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Theme.Spacing.section * 2)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("transcript-empty")
  }

  /// The one empty-state heading, which the new-session page shares.
  static let heading = "What should we work on?"

  static func title(_ state: ConversationViewState) -> String {
    state.hasMoreHistory ? "No messages on this page" : heading
  }

  /// The next step, in the user's terms.
  static func detail(_ state: ConversationViewState) -> String {
    if state.hasMoreHistory { return "Load earlier messages to continue." }
    if state.header.readOnly { return "This session has no messages yet." }
    return "Send a message to get started."
  }
}

/// How serious a ``StatusBanner`` is: its glyph and tint.
enum StatusBannerKind {
  /// Something failed (a turn, a send, the connection).
  case failure
  /// The app cannot tell what happened and needs the user to check.
  case uncertain
  /// For information, such as a session continuing elsewhere.
  case notice

  var systemImage: String {
    switch self {
    case .failure: "exclamationmark.triangle.fill"
    case .uncertain: "questionmark.circle.fill"
    case .notice: "arrow.turn.down.right"
    }
  }

  var tint: ThemeColor {
    switch self {
    case .failure: Theme.failure
    case .uncertain: Theme.warning
    case .notice: Theme.secondary
    }
  }
}

/// The one banner grammar for failures, connection problems, delivery questions and notices: a
/// glyph, a title, a line of detail, Copy in the overflow menu, and the actions at the trailing
/// edge, the primary one last.
struct StatusBanner<Actions: View>: View {
  let kind: StatusBannerKind
  /// The headline; `nil` shows the detail as the headline.
  let title: String?
  let detail: String
  /// What Copy copies; `nil` offers no overflow menu.
  var copyText: String?
  /// The banner's identifier; the overflow menu appends `-more`.
  let identifier: String
  @ViewBuilder var actions: Actions

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
        Image(systemName: kind.systemImage)
          .foregroundStyle(kind.tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          if let title {
            Text(title).font(.callout.weight(.semibold))
          }
          // No vertical fixedSize: in the composer's bottom inset it feeds the inset's height
          // back into the transcript's layout, which then never draws.
          Text(detail)
            .font(.callout)
            .foregroundStyle(title == nil ? .primary : .secondary)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let copyText { overflow(copyText) }
      }
      if Actions.self != EmptyView.self {
        HStack(spacing: Theme.Spacing.small) {
          Spacer(minLength: 0)
          actions
        }
        // Neutral buttons: the system tint is blue, and the accent is for the primary action.
        .tint(ThemeColor.primary)
      }
    }
    .padding(Theme.Spacing.medium)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(
      cornerRadius: Theme.Radius.medium, tint: kind == .notice ? nil : kind.tint,
      stroke: kind == .notice ? nil : kind.tint.opacity(0.3)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }

  private func overflow(_ text: String) -> some View {
    Menu {
      Button(kind == .failure ? "Copy Error" : "Copy", systemImage: "doc.on.doc") {
        Pasteboard.copy(text)
      }
    } label: {
      Image(systemName: "ellipsis")
        .accessibilityHidden(true)
        .frame(width: Theme.Control.target, height: Theme.Control.target)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .fixedSize()
    .help("More")
    .accessibilityLabel("More")
    .accessibilityIdentifier("\(identifier)-more")
  }
}

extension StatusBanner where Actions == EmptyView {
  /// A banner without actions.
  init(
    kind: StatusBannerKind, title: String?, detail: String, copyText: String? = nil,
    identifier: String
  ) {
    self.init(
      kind: kind, title: title, detail: detail, copyText: copyText, identifier: identifier
    ) { EmptyView() }
  }
}

struct SupersededBanner: View {
  let section: EventSection
  let target: String
  @Environment(\.conversationActions) private var actions

  var body: some View {
    if let open = actions.openSession {
      StatusBanner(
        kind: .notice, title: section.title, detail: section.summary,
        identifier: "session-superseded"
      ) {
        Button("Open") { open(target) }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("session-open-successor")
      }
    } else {
      StatusBanner(
        kind: .notice, title: section.title, detail: section.summary,
        identifier: "session-superseded")
    }
  }
}

/// The banners to end a transcript with, so a failure the turn, a row and the stream all report
/// shows once.
nonisolated struct TranscriptFailures: Equatable {
  /// The last turn's failure, unless a recent row already says it.
  var turnFailure: String?
  /// A session error, unless a recent row or the turn's failure already says it.
  var sessionError: String?

  init(_ state: ConversationViewState) {
    let shownInRows = Set(
      state.rows.suffix(20).compactMap { row in
        row.activity?.isFailure == true ? row.activity?.summary : nil
      })
    let failure = state.header.failureMessage
    turnFailure = failure.flatMap { shownInRows.contains($0) ? nil : $0 }
    sessionError = state.errorMessage.flatMap {
      $0 == failure || shownInRows.contains($0) ? nil : $0
    }
  }
}

/// The last turn failed, with Resume when the session can resume.
struct FailureBanner: View {
  let message: String
  let resume: (@MainActor () -> Void)?

  private static let title = "The last turn failed"

  var body: some View {
    if let resume {
      StatusBanner(
        kind: .failure, title: Self.title, detail: message, copyText: message,
        identifier: "turn-failure"
      ) {
        Button("Resume session", action: resume).buttonStyle(.bordered)
          .accessibilityIdentifier("turn-failure-resume")
      }
    } else {
      StatusBanner(
        kind: .failure, title: Self.title, detail: message, copyText: message,
        identifier: "turn-failure")
    }
  }
}

/// The session's startup in the thread, from the core's `startup` section: the sandbox's launch
/// stage or the MCP servers still starting as a spinner line, or a failed launch's banner.
struct StartupLine: View {
  let section: EventSection

  var body: some View {
    if section.details.first?.text == "failed" {
      let error = section.details.first { $0.id == "error" }?.text ?? ""
      StatusBanner(
        kind: .failure, title: section.summary, detail: error, copyText: error,
        identifier: "sandbox-failed")
    } else {
      TurnStatusRow {
        ProgressView().controlSize(.small)
      } label: {
        Text(section.summary)
      }
      .frame(minHeight: Theme.Control.target)
      .accessibilityAddTraits(.updatesFrequently)
      .accessibilityIdentifier("startup-line")
    }
  }
}

/// A session-level error with optional dismiss and retry.
struct ErrorBanner: View {
  let message: String
  /// A headline; `nil` lets the message stand alone.
  var title: String?
  var dismiss: (@MainActor () -> Void)?
  var retry: (@MainActor () -> Void)?
  /// The banner's identifier; its buttons append `-retry` and `-dismiss`.
  var identifier = "session-error"

  var body: some View {
    Group {
      if dismiss == nil, retry == nil {
        StatusBanner(
          kind: .failure, title: title, detail: message, copyText: message,
          identifier: identifier)
      } else {
        StatusBanner(
          kind: .failure, title: title, detail: message, copyText: message, identifier: identifier
        ) {
          if let dismiss {
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
              .accessibilityIdentifier("\(identifier)-dismiss")
          }
          if let retry {
            Button("Retry", action: retry).buttonStyle(.bordered)
              .accessibilityIdentifier("\(identifier)-retry")
          }
        }
      }
    }
    .accessibilityLabel("Error: \(message)")
  }
}

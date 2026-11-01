import SwiftUI

struct EmptyTranscriptView: View {
  let state: ConversationViewState

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "bubble.left.and.text.bubble.right")
        .font(.largeTitle)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(title).font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
    .accessibilityElement(children: .combine)
  }

  private var title: String {
    state.hasMoreHistory ? "No messages on this page" : "What should we work on?"
  }

  private var detail: String {
    if !state.lifecycleRows.isEmpty { return "Lifecycle details are in the inspector." }
    if state.hasMoreHistory { return "Load earlier messages to continue." }
    return "Send a message to get started."
  }
}

struct SupersededBanner: View {
  let section: EventSection
  let target: String
  @Environment(\.conversationActions) private var actions

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "arrow.turn.down.right")
        .foregroundStyle(Theme.accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(section.title).font(.callout.weight(.semibold))
        Text(section.summary).font(.callout).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if let open = actions.openSession {
        Button("Open") { open(target) }
          .accessibilityIdentifier("session-open-successor")
      }
    }
    .padding(12)
    .cardSurface(cornerRadius: Theme.Radius.medium, tint: Theme.accent)
  }
}

/// Links to child (subagent) sessions the stream reported.
struct ChildSessionsStrip: View {
  let sections: [EventSection]
  let currentSessionID: String
  @Environment(\.conversationActions) private var actions

  private var children: [EventSection] {
    sections.filter { $0.id.hasPrefix("child-") && $0.sessionId != nil }
  }

  var body: some View {
    if !children.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Subagent sessions")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        FlowLayout(spacing: 6) {
          ForEach(children) { child in
            ChildSessionLink(section: child, open: actions.openSession)
          }
        }
      }
      .accessibilityElement(children: .contain)
    }
  }
}

struct ChildSessionLink: View {
  let section: EventSection
  let open: ((String) -> Void)?

  var body: some View {
    Button {
      if let id = section.sessionId { open?(id) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "arrow.triangle.branch")
          .foregroundStyle(Theme.accent)
          .accessibilityHidden(true)
        Text(section.title).font(.callout).lineLimit(1)
        Text(section.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Image(systemName: "arrow.up.forward")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .cardSurface(cornerRadius: Theme.Radius.medium)
    }
    .buttonStyle(.plain)
    .disabled(open == nil)
    .accessibilityLabel("Open subagent session \(section.title), \(section.summary)")
    .accessibilityIdentifier("open-\(section.id)")
  }
}

struct FailureBanner: View {
  let message: String
  let resume: (@MainActor () -> Void)?

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 6) {
        Text("The last turn failed").font(.callout.weight(.semibold))
        Text(message).font(.callout).textSelection(.enabled)
        HStack(spacing: 10) {
          if let resume {
            Button("Resume session", action: resume).buttonStyle(.bordered)
              .accessibilityIdentifier("turn-failure-resume")
          }
          CopyButton(text: message, label: "Copy error")
        }
      }
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(cornerRadius: Theme.Radius.medium, tint: Theme.warning)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("turn-failure")
  }
}

/// A session-level error with optional dismiss and retry.
struct ErrorBanner: View {
  let message: String
  var dismiss: (@MainActor () -> Void)?
  var retry: (@MainActor () -> Void)?
  /// The banner's identifier; its buttons append `-retry` and `-dismiss`.
  var identifier = "session-error"

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.failure)
        .accessibilityHidden(true)
      Text(message)
        .font(.callout)
        .textSelection(.enabled)
      Spacer(minLength: 8)
      CopyButton(text: message, label: "Copy error")
      if let retry {
        Button("Retry", action: retry)
          .accessibilityIdentifier("\(identifier)-retry")
      }
      if let dismiss {
        Button("Dismiss", action: dismiss).buttonStyle(.borderless)
          .accessibilityIdentifier("\(identifier)-dismiss")
      }
    }
    .padding(12)
    .cardSurface(
      cornerRadius: Theme.Radius.medium, tint: Theme.failure, stroke: Theme.failure.opacity(0.3)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Error: \(message)")
    .accessibilityIdentifier(identifier)
  }
}

import SwiftUI

struct EmptyTranscriptView: View {
  let state: ConversationViewState

  var body: some View {
    VStack(spacing: Theme.Spacing.small) {
      OttoView()
        .frame(width: Theme.Control.mascot, height: Theme.Control.mascot)
        .accessibilityHidden(true)
      Text(title).font(Theme.Typography.title)
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
    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
      Image(systemName: "arrow.turn.down.right")
        .foregroundStyle(Theme.accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text(section.title).font(.callout.weight(.semibold))
        Text(section.summary).font(.callout).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if let open = actions.openSession {
        Button("Open") { open(target) }
          .accessibilityIdentifier("session-open-successor")
      }
    }
    .padding(Theme.Spacing.medium)
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
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Text("Subagent sessions")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        FlowLayout(spacing: Theme.Spacing.small) {
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
      HStack(spacing: Theme.Spacing.small) {
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
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
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
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Text("The last turn failed").font(.callout.weight(.semibold))
        Text(message).font(.callout).textSelection(.enabled)
        HStack(spacing: Theme.Spacing.medium) {
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
    .padding(Theme.Spacing.medium)
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
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Label {
        Text(message)
          .font(.callout)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.failure)
      }
      HStack(spacing: Theme.Spacing.medium) {
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Theme.Spacing.medium)
    .cardSurface(
      cornerRadius: Theme.Radius.medium, tint: Theme.failure, stroke: Theme.failure.opacity(0.3)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Error: \(message)")
    .accessibilityIdentifier(identifier)
  }
}

import Foundation

/// The session header's one status line: `Waiting for you · 2 requests`,
/// `Failed · <reason>`, `Running · <current activity>`, `Finished · 3 files changed` or `Stopped`.
///
/// It reads only what the conversation reports: the pending decision cards (the same ones the
/// decision dock counts), the header's status and failure, the plan's in-progress task or an
/// in-progress tool row, and the changed-files sections. A session with pending decisions is
/// never shown as running.
nonisolated public struct SessionStatusLine: Hashable, Sendable {
  /// Which state the line describes, in precedence order.
  public enum Kind: Hashable, Sendable {
    /// Pending decisions (or a reported pending state whose cards have not loaded).
    case waiting
    /// The last turn failed.
    case failed
    /// A turn is in progress.
    case running
    /// The last turn finished.
    case finished
    /// Nothing has run yet.
    case ready
  }

  /// The state.
  public var kind: Kind
  /// The line, for example `Waiting for you · 7 requests`.
  public var text: String

  /// The line for `state`.
  /// - Parameter state: The conversation.
  public init(_ state: ConversationViewState) {
    let header = state.header
    let transcript = state.transcriptStatus ?? TranscriptStatus(rows: state.rows)
    let pending = state.decisions.count { card in
      switch state.phase(of: card) {
      case .pending, .resolving, .failed: true
      case .answered: false
      }
    }
    if pending > 0 {
      kind = .waiting
      let who = header.readOnly ? "Waiting for a response" : "Waiting for you"
      text = "\(who) \u{00B7} \(Self.count(pending, "request"))"
    } else if header.status == .needsResponse {
      kind = .waiting
      text = header.readOnly ? "Waiting for a response" : "Waiting for you"
    } else if let failure = header.failureMessage {
      kind = .failed
      text = "Failed \u{00B7} \(failure)"
    } else if header.status == .running {
      kind = .running
      text = Self.activity(state, transcript).map { "Running \u{00B7} \($0)" } ?? "Running"
    } else if transcript.isEmpty {
      kind = .ready
      text = "Ready"
    } else if transcript.lastInterrupted {
      kind = .finished
      text = "Stopped"
    } else {
      kind = .finished
      text =
        Self.changedFiles(state).map { "Finished \u{00B7} \(Self.count($0, "file")) changed" }
        ?? "Finished"
    }
  }

  /// The plan's in-progress task, else the latest in-progress tool's title.
  private static func activity(
    _ state: ConversationViewState, _ transcript: TranscriptStatus
  ) -> String? {
    if let todos = state.section("todos"),
      let task = SectionReading.todos(todos).first(where: { $0.state == .inProgress }),
      !task.text.isEmpty
    {
      return task.text
    }
    return transcript.activityTitle
  }

  /// Files across the loaded changed-files sections (`<N> files in <environment>`), or `nil`
  /// when none reported a count.
  private static func changedFiles(_ state: ConversationViewState) -> Int? {
    let counts = state.sections.filter { $0.id.hasPrefix("files-") }.compactMap { section in
      section.summary.split(separator: " ", maxSplits: 2).first.flatMap { Int($0) }
        .flatMap { section.summary.hasPrefix("\($0) files in ") ? $0 : nil }
    }
    return counts.isEmpty ? nil : counts.reduce(0, +)
  }

  private static func count(_ value: Int, _ noun: String) -> String {
    value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
  }
}

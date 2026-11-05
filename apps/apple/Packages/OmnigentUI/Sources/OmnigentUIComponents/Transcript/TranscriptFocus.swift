public import Observation
public import SwiftUI

/// Messages to scroll to and highlight, by session: the web's `?message=<id>` links. A transcript
/// that shows the session's message clears it, so it is shown once.
@MainActor
@Observable
public final class TranscriptFocus {
  private var messageIDs: [String: String] = [:]
  /// The row a link just scrolled to, flashed for a moment as the web does.
  public private(set) var flashedRowID: String?

  /// Creates an empty focus.
  public init() {}

  /// Shows `messageID` (a user message's item id, or an answer's response id) when `sessionID`'s
  /// transcript is on screen.
  /// - Parameters:
  ///   - messageID: The message.
  ///   - sessionID: Its session.
  public func focus(_ messageID: String, in sessionID: String) {
    messageIDs[sessionID] = messageID
  }

  /// The message waiting in `sessionID`, if any.
  /// - Parameter sessionID: The session.
  /// - Returns: The message id.
  public func messageID(in sessionID: String) -> String? { messageIDs[sessionID] }

  /// Drops `sessionID`'s waiting message.
  /// - Parameter sessionID: The session.
  public func clear(_ sessionID: String) {
    if messageIDs[sessionID] != nil { messageIDs[sessionID] = nil }
  }

  /// Flashes `rowID` once; the flash ends on its own.
  func flash(_ rowID: String) {
    flashedRowID = rowID
    Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return  // Never cancelled; nothing to clear early.
      }
      if self?.flashedRowID == rowID { self?.flashedRowID = nil }
    }
  }

  /// The transcript row (segment) that shows `messageID`: the user message with that item id,
  /// else the last answer of that response, else its Worked fold.
  nonisolated static func entryID(forMessage messageID: String, in segments: [TurnSegment])
    -> String?
  {
    if let segment = segments.first(where: { $0.id == messageID }) { return segment.id }
    let answer = segments.last { segment in
      guard case .item(.message(let row)) = segment else { return false }
      return row.role == .assistant && row.responseId == messageID
    }
    if let answer { return answer.id }
    return segments.last { segment in
      guard case .worked(_, let responseID, _, _) = segment else { return false }
      return responseID == messageID
    }?.id
  }
}

extension EnvironmentValues {
  /// The window's message focus; `nil` where links can't point at messages.
  @Entry public var transcriptFocus: TranscriptFocus?
}

/// The web's message highlight: a warning-color tint behind the linked message that fades out.
struct MessageFlash: View {
  @State private var isVisible = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    RoundedRectangle(cornerRadius: Theme.Radius.medium)
      .fill(Theme.warning.opacity(isVisible ? (colorScheme == .dark ? 0.24 : 0.16) : 0))
      .padding(-Theme.Spacing.small)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .task {
        do {
          try await Task.sleep(for: .seconds(0.6))
        } catch {
          return  // The row scrolled away and the flash ended with it.
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9)) { isVisible = false }
      }
  }
}

/// Scrolls a transcript to its session's linked message and flashes it, loading older history
/// until the message is there. It waits for the transcript to frame its latest turn on open.
struct TranscriptMessageFocus: ViewModifier {
  let sessionID: String
  let revision: UInt64
  /// Older history is loading; the next page can be asked for once it lands.
  let isLoadingHistory: Bool
  /// The scroll id of the row that shows a message, if it is loaded.
  let locate: (String) -> String?
  let canLoadOlder: Bool
  let hasRows: Bool
  let loadOlder: () -> Void
  /// Scrolls to and flashes a row.
  let show: (String) -> Void
  @Environment(\.transcriptFocus) private var focus

  func body(content: Content) -> some View {
    content
      .task(id: focus?.messageID(in: sessionID)) {
        guard focus?.messageID(in: sessionID) != nil else { return }
        do {
          try await Task.sleep(for: .milliseconds(150))
        } catch {
          return  // Another link or session replaced it.
        }
        attempt()
      }
      .onChange(of: revision) {
        if focus?.messageID(in: sessionID) != nil { attempt() }
      }
      .onChange(of: isLoadingHistory) { _, isLoading in
        if !isLoading, focus?.messageID(in: sessionID) != nil { attempt() }
      }
  }

  private func attempt() {
    guard let focus, let messageID = focus.messageID(in: sessionID) else { return }
    if let target = locate(messageID) {
      focus.clear(sessionID)
      show(target)
      focus.flash(target)
    } else if canLoadOlder {
      // While a page is loading, the next one is asked for when it lands.
      if !isLoadingHistory { loadOlder() }
    } else if hasRows {
      // The whole history is loaded and the message isn't in it: stay at the latest.
      focus.clear(sessionID)
    }
  }
}

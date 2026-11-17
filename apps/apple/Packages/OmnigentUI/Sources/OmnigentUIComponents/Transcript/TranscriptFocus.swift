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
  @ObservationIgnored private var flashTimer: Task<Void, Never>?
  /// How long a row stays flashed.
  @ObservationIgnored var flashDuration: Duration = .seconds(2)

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
    flashTimer?.cancel()
    flashTimer = Task { [weak self, flashDuration] in
      do {
        try await Task.sleep(for: Theme.Timing.pause(flashDuration))
      } catch {
        return  // A newer flash took over, with a timer of its own.
      }
      self?.flashedRowID = nil
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
  /// A CLI row is a full-width band: square, flush with the row. A chat message gets a rounded
  /// tint a little larger than itself.
  var isBand = false
  @State private var isVisible = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    RoundedRectangle(cornerRadius: isBand ? 0 : Theme.Radius.medium)
      .fill(Theme.warning.opacity(isVisible ? (colorScheme == .dark ? 0.24 : 0.16) : 0))
      .padding(isBand ? 0 : -Theme.Spacing.small)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .task {
        do {
          try await Task.sleep(for: Theme.Timing.pause(.seconds(0.6)))
        } catch {
          return  // The row scrolled away and the flash ended with it.
        }
        withAnimation(reduceMotion ? nil : Theme.Motion.animation(.easeOut(duration: 0.9))) {
          isVisible = false
        }
      }
  }
}

/// Scrolls a transcript to its session's linked message and flashes it, loading older history
/// until the message is there. It sits on the row list, so `state` holds the rows the list
/// shows; the rows read reach the list a tick later. A link lands once it has waited out
/// `settle`, which lets the transcript frame its latest turn on open.
struct TranscriptMessageFocus: ViewModifier {
  /// The conversation with the rows the list shows.
  let state: ConversationViewState
  /// The host can load older history.
  let pages: Bool
  /// The scroll id of the shown row for a message, if there is one.
  let locate: (String) -> String?
  /// The rows read so far, and their revision.
  let readRows: () -> (rows: [Row], revision: UInt64)
  let loadOlder: () -> Void
  /// Scrolls to a row.
  let show: (String) -> Void
  /// How long a link waits before scrolling, so a newer link or session replaces it first.
  var settle: Duration = .milliseconds(150)
  @Environment(\.transcriptFocus) private var focus
  /// The link that waited out `settle`; only it lands.
  @State private var settled: String?
  /// The first row read when this link asked for older history, until that read ends.
  @State private var pageRequest: PageRequest?

  private struct PageRequest: Equatable {
    var topRowID: String?
  }

  private var sessionID: String { state.header.id }
  private var messageID: String? { focus?.messageID(in: sessionID) }

  func body(content: Content) -> some View {
    content
      .task(id: messageID) {
        // A new link waits out its own settle and asks for pages afresh.
        if settled != nil { settled = nil }
        if pageRequest != nil { pageRequest = nil }
        guard let linked = messageID else { return }
        do {
          try await Task.sleep(for: Theme.Timing.pause(settle))
        } catch {
          return  // Another link or session replaced it.
        }
        settled = linked
      }
      .onChange(of: settled) { attempt() }
      .onChange(of: state.revision) { attempt() }
      // The count too: a read that starts and ends between two renders never shows as loading.
      .onChange(of: HistoryRead(isLoading: state.isLoadingHistory, ended: state.historyReads)) {
        if !$1.isLoading { readEnded() }
      }
  }

  private func attempt() {
    guard let focus, let messageID, settled == messageID else { return }
    if let target = locate(messageID) {
      finish(focus)
      show(target)
      focus.flash(target)
      return
    }
    let read = readRows()
    let isRead = read.rows.contains { $0.id == messageID || $0.responseId == messageID }
    if isRead, read.revision != state.revision {
      return  // The list shows it with its next rows, which try again.
    }
    if pages, state.hasMoreHistory {
      // A page asked for or loading is waited for: its end tries again.
      guard pageRequest == nil, !state.isLoadingHistory else { return }
      pageRequest = PageRequest(topRowID: read.rows.first?.id)
      loadOlder()
    } else if !state.rows.isEmpty {
      // The whole history is loaded and the message isn't in it: stay at the latest.
      finish(focus)
    }
  }

  /// A read of older history ended. One this link asked for that added no rows failed, and the
  /// link stops there rather than ask again without end.
  private func readEnded() {
    guard let request = pageRequest else {
      attempt()
      return
    }
    pageRequest = nil
    if let focus, readRows().rows.first?.id == request.topRowID {
      finish(focus)
    } else {
      attempt()
    }
  }

  /// The link landed or was given up.
  private func finish(_ focus: TranscriptFocus) {
    pageRequest = nil
    focus.clear(sessionID)
  }
}

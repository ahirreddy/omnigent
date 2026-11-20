public import Foundation
import SwiftUI

/// One event from a session's stream, as it arrived.
nonisolated public struct ExecutionStreamEvent: Hashable, Sendable, Identifiable {
  /// Its place in the session's log, from 0.
  public var index: UInt64
  /// When it arrived.
  public var receivedAt: Date
  /// The event on one line.
  public var compact: String
  /// The event indented.
  public var pretty: String

  /// Its place in the log.
  public var id: UInt64 { index }

  /// Creates an event.
  /// - Parameters:
  ///   - index: Its place in the log.
  ///   - receivedAt: When it arrived.
  ///   - compact: One line.
  ///   - pretty: Indented.
  public init(index: UInt64, receivedAt: Date, compact: String, pretty: String) {
    self.index = index
    self.receivedAt = receivedAt
    self.compact = compact
    self.pretty = pretty
  }
}

/// What the execution logs show: the stored items, or the live stream's events.
enum ExecutionLogMode: Hashable, CaseIterable {
  case items
  case stream

  var title: String {
    switch self {
    case .items: "Items"
    case .stream: "SSE"
    }
  }
}

/// The live stream's events for one session (the web's SSE view of its execution logs panel):
/// numbered from the first kept, with the time each arrived, one line each until opened. New
/// events are read every second and the list follows the newest.
struct ExecutionStreamLogView: View {
  let sessionID: String
  let read: @MainActor (String, UInt64?) -> [ExecutionStreamEvent]
  @State private var events: [ExecutionStreamEvent] = []
  @State private var opened: Set<UInt64> = []

  /// The most events shown, as the core keeps.
  static let limit = 500

  var body: some View {
    Group {
      if events.isEmpty {
        ContentUnavailableView(
          "No SSE Events Yet", systemImage: "dot.radiowaves.left.and.right",
          description: Text("Events are captured while the agent runs."))
      } else {
        ScrollViewReader { proxy in
          List(events) { event in
            row(event).id(event.index)
          }
          .font(.callout.monospaced())
          .onChange(of: events.last?.index) { _, last in
            if let last { proxy.scrollTo(last, anchor: .bottom) }
          }
          .onAppear {
            if let last = events.last?.index { proxy.scrollTo(last, anchor: .bottom) }
          }
        }
        .accessibilityIdentifier("execution-logs-stream")
      }
    }
    .task(id: sessionID) { await follow() }
  }

  private func row(_ event: ExecutionStreamEvent) -> some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { opened.contains(event.index) },
        set: { isOpen in
          if isOpen { opened.insert(event.index) } else { opened.remove(event.index) }
        })
    ) {
      Text(event.pretty).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    } label: {
      HStack(spacing: 6) {
        Text("#\(event.index + 1)").foregroundStyle(.secondary)
        Text(Self.time(event.receivedAt)).foregroundStyle(.secondary)
        if !opened.contains(event.index) {
          Text(event.compact).lineLimit(1).truncationMode(.tail)
        }
      }
    }
    .accessibilityIdentifier("execution-log-event")
  }

  /// Reads the session's events, then the newer ones every second.
  private func follow() async {
    events = []
    opened = []
    while !Task.isCancelled {
      events = Self.merged(events, read(sessionID, events.last?.index))
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
    }
  }

  /// `shown` with the `newer` events after it, keeping the last ``limit``. A log that started
  /// over (its stream opened anew) replaces what was shown.
  static func merged(_ shown: [ExecutionStreamEvent], _ newer: [ExecutionStreamEvent])
    -> [ExecutionStreamEvent]
  {
    guard let first = newer.first else { return shown }
    let restarted = shown.last.map { first.index <= $0.index } ?? false
    return Array(((restarted ? [] : shown) + newer).suffix(limit))
  }

  /// "14:03:27.512", in the reader's time zone.
  static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()
}

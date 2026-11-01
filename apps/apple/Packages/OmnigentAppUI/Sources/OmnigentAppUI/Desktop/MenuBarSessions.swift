#if os(macOS)
  public import Foundation
  public import Observation
  import OmnigentCoreFFI
  public import OmnigentDesktop
  public import OmnigentStores
  public import SwiftUI

  /// The menu bar extra's sessions, across every open server window, from the shared attention
  /// model (`SessionListStore.attention(of:)`): sessions that need the user, failed turns, and
  /// unread sessions.
  @Observable
  public final class MenuBarSessions: MenuBarSessionSource {
    private struct Registration {
      let serverURL: URL
      let connection: ConnectionStore
    }

    private var windows: [UUID: Registration] = [:]

    /// Creates an empty source.
    public init() {}

    /// Starts listing `connection`'s sessions for the window `instance`.
    /// - Parameters:
    ///   - connection: The window's connection.
    ///   - serverURL: Its server.
    ///   - instance: The window.
    public func register(_ connection: ConnectionStore, serverURL: URL, instance: UUID) {
      windows[instance] = Registration(serverURL: serverURL, connection: connection)
    }

    /// Stops listing the window `instance`.
    /// - Parameter instance: The window.
    public func unregister(_ instance: UUID) {
      windows[instance] = nil
    }

    /// Sessions that need the user: awaiting input first, then failures, then unread, newest
    /// first within each. A server shown in two windows is listed once.
    public var sessionsNeedingAttention: [AttentionSession] {
      var seen = Set<String>()
      var rows: [AttentionSession] = []
      for registration in windows.values {
        let list = registration.connection.sessionList
        for summary in list.sessionsByID.values {
          let key = "\(registration.serverURL.absoluteString)#\(summary.id)"
          // An archived session is listed only for a pending decision, as the totals count it.
          guard !seen.contains(key), let reason = Self.reason(list.attention(of: summary.id)),
            !summary.isArchived || reason == .awaitingInput
          else {
            continue
          }
          seen.insert(key)
          rows.append(
            AttentionSession(
              id: summary.id, title: summary.title, serverURL: registration.serverURL,
              reason: reason,
              updatedAt: Date(timeIntervalSince1970: TimeInterval(summary.updatedAt))))
        }
      }
      return rows.sorted { lhs, rhs in
        let left = Self.rank(lhs.reason)
        let right = Self.rank(rhs.reason)
        return left == right ? lhs.updatedAt > rhs.updatedAt : left < right
      }
    }

    /// Sessions that need the user across servers (each server's
    /// `AttentionTotals.sessionsNeedingYou` once), the same number as the Dock badge.
    public var unreadCount: Int {
      var servers: [URL: Int] = [:]
      for registration in windows.values {
        servers[registration.serverURL] = Int(
          registration.connection.sessionList.attentionTotals.sessionsNeedingYou)
      }
      return servers.values.reduce(0, +)
    }

    private static func reason(_ attention: SessionAttention) -> AttentionSession.Reason? {
      switch attention.state {
      case .needsYou: .awaitingInput
      case .failed: .failed
      case .unread: .unread(count: 1)
      case .working, .idle: nil
      }
    }

    private static func rank(_ reason: AttentionSession.Reason) -> Int {
      switch reason {
      case .awaitingInput: 0
      case .failed: 1
      case .unread: 2
      }
    }
  }

  extension View {
    /// Lists this window's sessions in the menu bar extra while the window is open and bound.
    /// - Parameters:
    ///   - connection: The window's connection.
    ///   - serverURL: Its server, when bound.
    ///   - instance: The window.
    ///   - menuBar: The shared source.
    /// - Returns: The view.
    public func menuBarSessions(
      _ connection: ConnectionStore, serverURL: URL?, instance: UUID, in menuBar: MenuBarSessions
    ) -> some View {
      onChange(of: serverURL, initial: true) {
        if let serverURL {
          menuBar.register(connection, serverURL: serverURL, instance: instance)
        } else {
          menuBar.unregister(instance)
        }
      }
      .onDisappear { menuBar.unregister(instance) }
    }
  }
#endif

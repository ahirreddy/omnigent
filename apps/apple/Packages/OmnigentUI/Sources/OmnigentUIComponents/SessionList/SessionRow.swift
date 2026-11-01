import Foundation
import OmnigentPlatform
import SwiftUI

/// One sidebar session row, as the web's: the title on one line, an optional details line, and
/// on the right the state (Needs response > running > disconnected > error > unread), else a
/// draft pencil, else the relative time. Hovering on Mac reveals pin and more buttons.
struct SessionRow: View {
  let session: SessionSummary
  let info: SessionRowInfo
  let isUnread: Bool
  let attention: Int
  let details: Set<SessionRowDetail>
  let now: Date
  let menu: SessionRowMenu

  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .center, spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Text(session.title)
          .lineLimit(1)
          .fontWeight(isUnread ? .semibold : .regular)
        if let line = detailLine {
          Text(line)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if isHovered, menu.canHoverPin {
        HStack(spacing: 2) {
          Button(
            session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin"
          ) {
            menu.togglePin()
          }
          Menu {
            menu.items
          } label: {
            Label("More", systemImage: "ellipsis")
          }
          .menuIndicator(.hidden)
          .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      } else {
        trailing
      }
    }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .help(tooltip)
    .contextMenu { menu.items }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier("session-row-\(session.id)")
  }

  @ViewBuilder private var trailing: some View {
    HStack(spacing: 4) {
      if info.isShared {
        Image(systemName: "person.2")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .accessibilityLabel("Shared")
      }
      if attention > 0 || session.status == .needsResponse {
        Text("Needs response")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(Theme.brandAccent)
          .padding(.horizontal, 6)
          .padding(.vertical, 1.5)
          .background(Theme.brandAccent.opacity(0.15), in: Capsule())
      } else if session.status == .running {
        ProgressView().controlSize(.mini)
          .accessibilityLabel("Running")
      } else if info.isDisconnected {
        Circle().strokeBorder(.secondary, lineWidth: 1.2).frame(width: 8, height: 8)
          .accessibilityLabel("Disconnected")
      } else if session.failureMessage != nil {
        Image(systemName: "exclamationmark.circle")
          .foregroundStyle(Theme.failure)
          .accessibilityLabel("Error")
      } else if isUnread {
        Circle().fill(Theme.brandAccent).frame(width: 6, height: 6)
          .accessibilityLabel("Unread")
      } else if info.hasDraft {
        Image(systemName: "pencil")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Draft")
      } else if details.contains(.updated) {
        Text(RelativeTime.short(session.updatedDate, now: now))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
  }

  private var detailLine: String? {
    let parts = [
      details.contains(.environment) ? info.environment : nil,
      details.contains(.repo) ? info.repo : nil,
      details.contains(.branch) ? info.branch : nil,
    ].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
  }

  private var tooltip: String {
    var lines = [session.title, "Updated \(RelativeTime.short(session.updatedDate, now: now)) ago"]
    if let harness = info.harness { lines.append(HarnessAppearance(harness: harness).label) }
    if let environment = info.environment { lines.append(environment) }
    return lines.joined(separator: "\n")
  }

  private var accessibilityLabel: String {
    var parts = [session.title]
    if attention > 0 || session.status == .needsResponse { parts.append("Needs response") }
    if session.status == .running { parts.append("Running") }
    if session.failureMessage != nil { parts.append("Error") }
    if isUnread { parts.append("Unread") }
    if session.isPinned { parts.append("Pinned") }
    if info.isShared { parts.append("Shared") }
    parts.append("updated \(RelativeTime.short(session.updatedDate, now: now)) ago")
    return parts.joined(separator: ", ")
  }
}

/// The web's short relative time: `now`, `5m`, `3h`, `2d`, `1w`, `2mo`, `1y`.
nonisolated enum RelativeTime {
  static func short(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    let minutes = Int(seconds / 60)
    let hours = minutes / 60
    let days = hours / 24
    switch true {
    case minutes < 1: return "now"
    case hours < 1: return "\(minutes)m"
    case days < 1: return "\(hours)h"
    case days < 7: return "\(days)d"
    case days < 30: return "\(days / 7)w"
    case days < 365: return "\(max(1, days / 30))mo"
    default: return "\(days / 365)y"
    }
  }
}

/// The row menu in the web's order, shared by the context menu and the hover menu.
struct SessionRowMenu {
  let session: SessionSummary
  let isUnread: Bool
  let isRunning: Bool
  let isShared: Bool
  let pinLimitReached: Bool
  let projects: [SessionProject]
  let actions: SessionListActions
  let rename: () -> Void
  let confirmDelete: () -> Void
  let confirmLeave: () -> Void

  var canHoverPin: Bool {
    #if os(macOS)
      actions.setPinned != nil && session.canPin
    #else
      false
    #endif
  }

  func togglePin() {
    guard let setPinned = actions.setPinned, session.canPin else { return }
    if !session.isPinned, pinLimitReached { return }
    setPinned(session, !session.isPinned)
  }

  @ViewBuilder var items: some View {
    if actions.setPinned != nil, session.canPin {
      Button(
        session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin"
      ) {
        togglePin()
      }
      .disabled(!session.isPinned && pinLimitReached)
      .help(!session.isPinned && pinLimitReached ? "Unpin a session first" : "")
    }
    if let share = actions.share {
      Button("Share", systemImage: "person.badge.plus") { share(session) }
    }
    if let fork = actions.fork {
      Button("Fork", systemImage: "arrow.triangle.branch") { fork(session) }
    }
    if actions.rename != nil, session.canRename {
      Button("Rename\u{2026}", systemImage: "pencil", action: rename)
    }
    if let setUnread = actions.setUnread {
      Button(
        isUnread ? "Mark as read" : "Mark as unread",
        systemImage: isUnread ? "envelope.open" : "envelope.badge"
      ) {
        setUnread(session, !isUnread)
      }
    }
    if let move = actions.moveToProject, !projects.isEmpty {
      Menu("Move session", systemImage: "folder") {
        ForEach(projects) { project in
          Button(project.name) { move(session, project) }
        }
        Divider()
        Button("Remove from project") { move(session, nil) }
      }
    }
    if let stop = actions.stop {
      Button("Stop session", systemImage: "stop.circle") { stop(session) }
        .disabled(!isRunning)
        .help(isRunning ? "" : "The session is not running")
    }
    if let setArchived = actions.setArchived, session.canArchive {
      Button(
        session.isArchived ? "Unarchive" : "Archive",
        systemImage: session.isArchived ? "tray.and.arrow.up" : "archivebox"
      ) {
        setArchived(session, !session.isArchived)
      }
    }
    if actions.delete != nil, !isShared {
      Button("Delete\u{2026}", systemImage: "trash", role: .destructive, action: confirmDelete)
    }
    if actions.leave != nil, isShared {
      Button(
        "Leave session\u{2026}", systemImage: "rectangle.portrait.and.arrow.right",
        role: .destructive, action: confirmLeave)
    }
    Divider()
    if let open = actions.openInNewWindow {
      Button("Open in New Window", systemImage: "macwindow.badge.plus") { open(session) }
    }
    if let webURL = actions.webURL?(session) {
      Button("Copy Link", systemImage: "link") { Pasteboard.copy(webURL.absoluteString) }
    }
    Button("Copy Session ID", systemImage: "number") { Pasteboard.copy(session.id) }
  }
}

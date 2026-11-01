import Foundation
import SwiftUI

struct FilterRow: View {
  let filter: SessionFilter
  let isActive: Bool
  let count: Int?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Label(filter.title, systemImage: filter.systemImage)
          .foregroundStyle(isActive ? Theme.accent : ThemeColor.primary)
          .fontWeight(isActive ? .semibold : .regular)
        Spacer()
        if let count, count > 0 {
          Text("\(count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(filter == .needsResponse ? .white : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
              filter == .needsResponse ? Theme.attention : ThemeColor.secondary.opacity(0.15),
              in: Capsule())
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
    .accessibilityValue(count.map { "\($0) sessions" } ?? "")
    .accessibilityIdentifier("session-filter-\(filter.rawValue)")
  }
}

/// One session row.
struct SessionRow: View {
  let session: SessionSummary
  let isUnread: Bool
  let attention: Int
  let now: Date

  @Environment(\.layoutWidth) private var layoutWidth

  private var status: StatusPresentation {
    StatusPresentation.session(
      status: session.status, isReadOnly: session.isReadOnly, failure: session.failureMessage,
      pending: attention)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      leadingIndicator
        .frame(width: 10)
        .padding(.top, 5)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(session.title)
            .font(.body.weight(isUnread ? .semibold : .regular))
            .lineLimit(1)
          if session.isPinned {
            Image(systemName: "pin.fill")
              .font(.caption2)
              .foregroundStyle(.orange)
              .accessibilityLabel("Pinned")
          }
          Spacer(minLength: 4)
          Text(Theme.relativeDate(session.updatedDate, now: now))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        if !session.preview.isEmpty {
          Text(session.preview)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(layoutWidth == .compact ? 2 : 1)
        }
        HStack(spacing: 6) {
          if !session.agentName.isEmpty {
            Text(session.agentName).lineLimit(1)
          }
          if !session.workspace.isEmpty {
            Text(URL(filePath: session.workspace).lastPathComponent)
              .lineLimit(1)
              .help(session.workspace)
          }
          Spacer(minLength: 0)
          badges
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier("session-row-\(session.id)")
  }

  @ViewBuilder private var leadingIndicator: some View {
    if session.status == .running {
      LiveIndicator()
    } else if isUnread {
      Circle().fill(Theme.unread).frame(width: 8, height: 8)
    } else {
      Color.clear.frame(width: 8, height: 8)
    }
  }

  @ViewBuilder private var badges: some View {
    if attention > 0 || session.status == .needsResponse {
      HStack(spacing: 3) {
        Image(systemName: "hand.raised.fill").accessibilityHidden(true)
        if attention > 1 { Text("\(attention)").monospacedDigit() }
      }
      .font(.caption2.weight(.bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 5)
      .padding(.vertical, 1.5)
      .background(Theme.attention, in: Capsule())
    } else if session.failureMessage != nil {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.failure)
        .accessibilityLabel("Failed")
    }
    if session.isReadOnly {
      Image(systemName: "eye").foregroundStyle(.secondary).accessibilityLabel("Read only")
    }
    if session.isArchived {
      Image(systemName: "archivebox").foregroundStyle(.secondary).accessibilityLabel("Archived")
    }
  }

  private var accessibilityLabel: String {
    var parts = [session.title]
    if isUnread { parts.append("Unread") }
    if session.isPinned { parts.append("Pinned") }
    parts.append(status.label)
    if attention > 0 { parts.append("\(attention) pending requests") }
    if session.isArchived { parts.append("Archived") }
    if !session.preview.isEmpty { parts.append(session.preview) }
    parts.append(Theme.relativeDate(session.updatedDate, now: now))
    return parts.joined(separator: ", ")
  }
}

/// Splits the core-ordered list into Pinned and date sections, keeping the order inside each.
nonisolated enum SessionGrouping {
  struct Group: Identifiable, Hashable {
    let title: String
    let sessions: [SessionSummary]
    var id: String { title }
  }

  static func groups(_ sessions: [SessionSummary], now: Date, calendar: Calendar = .current)
    -> [Group]
  {
    let titles = ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Older"]
    var buckets: [String: [SessionSummary]] = [:]
    let startOfToday = calendar.startOfDay(for: now)
    for session in sessions {
      let title: String
      if session.isPinned {
        title = "Pinned"
      } else {
        let day = calendar.startOfDay(for: session.updatedDate)
        let days = calendar.dateComponents([.day], from: day, to: startOfToday).day ?? 0
        switch days {
        case ..<1: title = "Today"
        case 1: title = "Yesterday"
        case 2..<7: title = "Previous 7 Days"
        case 7..<30: title = "Previous 30 Days"
        default: title = "Older"
        }
      }
      buckets[title, default: []].append(session)
    }
    return titles.compactMap { title in
      buckets[title].map { Group(title: title, sessions: $0) }
    }
  }
}

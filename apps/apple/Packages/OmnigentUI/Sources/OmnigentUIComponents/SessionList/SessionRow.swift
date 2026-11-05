import Foundation
import OmnigentPlatform
import SwiftUI

/// One sidebar session row, as the web's: the title on one line, an optional details line, and
/// on the right the session's attention (Needs you > Failed > Working > Unread, with a
/// disconnected ring before Unread), else a draft pencil, else the relative time. Hovering on Mac
/// reveals pin, archive and more buttons; the same actions are in the context menu and are VoiceOver
/// actions, so nothing needs hover.
struct SessionRow: View {
  let session: SessionSummary
  let info: SessionRowInfo
  let isUnread: Bool
  /// Pending decisions the user can answer, shown in the Needs you capsule when more than one.
  let attention: Int
  let details: Set<SessionRowDetail>
  let now: Date
  let menu: SessionRowMenu
  /// Selecting sessions: the row shows a check mark instead of its hover buttons.
  var isSelecting = false
  /// Checked while selecting sessions.
  var isChecked = false
  /// The title being edited in place, after a double-click.
  var inlineRename: InlineRename?
  /// Starts editing the title in place; `nil` when it cannot be renamed here.
  var beginInlineRename: (() -> Void)?

  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .center, spacing: Theme.Spacing.small) {
      if isSelecting {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 1) {
        if let inlineRename {
          InlineTitleField(rename: inlineRename)
        } else {
          Text(session.title)
            .lineLimit(1)
            .fontWeight(isUnread ? .semibold : .regular)
        }
        if let line = detailLine {
          Text(line)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if isHovered, menu.showsHoverActions, !isSelecting, inlineRename == nil {
        HStack(spacing: Theme.Spacing.tiny) {
          if menu.offersPin {
            Button(
              session.isPinned ? "Unpin" : "Pin",
              systemImage: session.isPinned ? "pin.slash" : "pin"
            ) {
              menu.togglePin()
            }
            .help(session.isPinned ? "Unpin" : "Pin")
          }
          if let setArchived = menu.actions.setArchived, session.canArchive {
            Button(
              session.isArchived ? "Unarchive" : "Archive",
              systemImage: session.isArchived ? "tray.and.arrow.up" : "archivebox"
            ) {
              setArchived(session, !session.isArchived)
            }
            .help(session.isArchived ? "Unarchive" : "Archive")
          }
          Menu {
            menu.items
          } label: {
            Label("More", systemImage: "ellipsis")
          }
          .menuIndicator(.hidden)
          .fixedSize()
          .help("More actions")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      } else {
        trailing
      }
    }
    // Height comes from the list's `defaultMinListRowHeight`, the same for every sidebar row.
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .simultaneousGesture(
      TapGesture(count: 2).onEnded { beginInlineRename?() },
      including: beginInlineRename == nil ? .subviews : .all
    )
    .help(tooltip)
    .contextMenu { menu.items }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isSelecting && isChecked ? .isSelected : [])
    .accessibilityActions { menu.accessibilityItems }
    .accessibilityIdentifier("session-row-\(session.id)")
  }

  @ViewBuilder private var trailing: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      if info.isShared {
        Image(systemName: "person.2")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Shared")
      }
      switch session.attention {
      case .needsYou:
        NeedsYouCapsule(requests: attention)
      case .failed:
        Image(systemName: "exclamationmark.circle")
          .foregroundStyle(Theme.failure)
          .help(session.failureMessage.map { "Failed: \($0)" } ?? "Failed")
          .accessibilityLabel("Failed")
      case .working:
        ProgressView().controlSize(.mini)
          .help("Running")
          .accessibilityLabel("Running")
      case .unread, .idle:
        quietTrailing
      }
    }
  }

  @ViewBuilder private var quietTrailing: some View {
    if info.isDisconnected {
      Image(systemName: "bolt.horizontal.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Disconnected")
        .accessibilityLabel("Disconnected")
    } else if session.attention == .unread {
      Circle().fill(Theme.unread).frame(width: 6, height: 6)
        .help("Unread")
        .accessibilityLabel("Unread")
    } else if info.hasDraft {
      Image(systemName: "pencil")
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Draft")
        .accessibilityLabel("Draft")
    } else if details.contains(.updated) {
      Text(RelativeTime.short(session.updatedDate, now: now))
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
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
    SessionRowTooltip.text(session, info: info, now: now)
  }

  private var accessibilityLabel: String {
    var parts = [session.title]
    switch session.attention {
    case .needsYou:
      parts.append(attention > 1 ? "Needs you, \(attention) requests" : "Needs you")
    case .failed, .working, .unread: parts.append(session.attention.label)
    case .idle: break
    }
    if info.isDisconnected { parts.append("Disconnected") }
    if session.isPinned { parts.append("Pinned") }
    if info.isShared { parts.append("Shared") }
    parts.append("updated \(RelativeTime.short(session.updatedDate, now: now)) ago")
    return parts.joined(separator: ", ")
  }
}

/// A title edited in place: Return or leaving the field saves it, Escape cancels.
struct InlineRename {
  /// The text being edited.
  let text: Binding<String>
  /// Saves the trimmed title (nothing for an empty or unchanged one).
  let commit: () -> Void
  /// Abandons the edit.
  let cancel: () -> Void
}

private struct InlineTitleField: View {
  let rename: InlineRename
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField("Title", text: rename.text)
      .textFieldStyle(.plain)
      .focused($isFocused)
      .onSubmit(rename.commit)
      #if os(macOS)
        .onExitCommand(perform: rename.cancel)
      #endif
      .onAppear { isFocused = true }
      .onChange(of: isFocused) { _, focused in
        if !focused { rename.commit() }
      }
      .accessibilityIdentifier("session-row-rename-field")
  }
}

/// The pink "Needs you" capsule, with the request count when there is more than one.
struct NeedsYouCapsule: View {
  let requests: Int

  var body: some View {
    HStack(spacing: Theme.Spacing.tiny) {
      Text("Needs you")
      if requests > 1 {
        Text("\(requests)").monospacedDigit()
      }
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(Theme.attention)
    .padding(.horizontal, Theme.Spacing.small)
    .padding(.vertical, 1.5)
    // An opaque base, so a selected row's tint never lowers the text's contrast.
    .background(ThemeColor.attentionFill, in: Capsule())
    .background(ThemeColor.surface, in: Capsule())
    .help(requests > 1 ? "\(requests) requests need your response" : "Needs your response")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(requests > 1 ? "Needs you, \(requests) requests" : "Needs you")
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

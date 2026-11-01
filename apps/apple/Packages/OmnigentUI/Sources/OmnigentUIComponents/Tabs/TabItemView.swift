import OmnigentPlatform
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Strip sizes.
enum TabMetrics {
  #if os(macOS)
    static let height: CGFloat = 30
    static let stripHeight: CGFloat = 38
  #else
    static let height: CGFloat = 34
    static let stripHeight: CGFloat = 44
  #endif
  static let pinnedWidth: CGFloat = 38
  /// A background tab's narrowest: its icon and about eight characters. Below this the strip
  /// scrolls.
  static let minWidth: CGFloat = 112
  static let maxWidth: CGFloat = 224
  /// The selected tab's width once the others shrink below it.
  static let selectedWidth: CGFloat = 200
  static let spacing: CGFloat = 2
}

/// One tab: icon, title, status and a close button on hover (always on the selected tab).
/// Pinned tabs show the icon only.
struct TabItemView: View {
  let tab: TabItemState
  let isSelected: Bool
  let width: CGFloat
  let actions: TabActions
  let canCloseToRight: Bool

  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: Theme.Spacing.small - 2) {
      TabIcon(tab: tab, isSelected: isSelected)
      if !tab.isPinned {
        Text(tab.displayTitle)
          .font(.callout.weight(isSelected ? .medium : .regular))
          .foregroundStyle(isSelected ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        // A background tab keeps its title readable with one trailing mark: Close while
        // hovered, else its status, else the audio glyph.
        if isSelected {
          if tab.isPlayingAudio { audioMark }
          TabStatusMark(status: tab.status)
          closeButton
        } else if isHovered {
          closeButton
        } else if tab.status != .none {
          TabStatusMark(status: tab.status)
        } else if tab.isPlayingAudio {
          audioMark
        }
      }
    }
    .padding(.horizontal, tab.isPinned ? 0 : Theme.Spacing.small + 2)
    .frame(width: width, height: TabMetrics.height)
    .background { background }
    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    .onHover { isHovered = $0 }
    .animation(reduceMotion ? nil : Theme.Motion.feedback, value: isHovered)
    .onTapGesture { actions.select(tab.id) }
    .accessibilityAddTraits(.isButton)
    .contextMenu { TabContextMenu(tab: tab, actions: actions, canCloseToRight: canCloseToRight) }
    .help(help)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(tab.displayTitle)
    .accessibilityValue(accessibilityValue)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityAction { actions.select(tab.id) }
    .accessibilityIdentifier("tab-\(tab.kind.rawValue)-\(tab.id)")
  }

  private var audioMark: some View {
    Image(systemName: "speaker.wave.2.fill")
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Playing audio")
  }

  private var closeButton: some View {
    Button {
      actions.close(tab.id)
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .frame(width: 16, height: 16)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .hoverHighlight(cornerRadius: 8)
    .help("Close tab (Command-W)")
    .accessibilityLabel("Close \(tab.displayTitle)")
    .accessibilityIdentifier("tab-close-\(tab.id)")
  }

  @ViewBuilder private var background: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
    if isSelected {
      shape.fill(ThemeColor.surface)
        .overlay { shape.strokeBorder(ThemeColor.border, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
    } else {
      shape.fill(ThemeColor.hover.opacity(isHovered ? 1 : 0))
    }
  }

  private var help: String {
    var parts = [tab.displayTitle]
    if let subtitle = tab.subtitle { parts.append(subtitle) }
    if let status = tab.statusDetail ?? tab.status.label { parts.append(status) }
    return parts.joined(separator: " \u{00B7} ")
  }

  private var accessibilityValue: String {
    var parts = [tab.kind.label]
    if let status = tab.status.label { parts.append(status) }
    if tab.isPinned { parts.append("Pinned") }
    if tab.isReadOnly { parts.append("Read only") }
    return parts.joined(separator: ", ")
  }
}

/// The kind's icon, with a status dot when the tab is pinned (it has no room for the mark).
struct TabIcon: View {
  let tab: TabItemState
  let isSelected: Bool

  var body: some View {
    symbol
      .frame(width: Theme.Control.icon, height: Theme.Control.icon)
      .overlay(alignment: .topTrailing) {
        if tab.isPinned, let color = dotColor {
          Circle().fill(color).frame(width: 6, height: 6).offset(x: 3, y: -2)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if let profile = tab.profileColor {
          Circle().fill(profile).frame(width: 6, height: 6)
            .overlay { Circle().strokeBorder(ThemeColor.surface, lineWidth: 1) }
            .offset(x: 3, y: 2)
        }
      }
      .accessibilityHidden(true)
  }

  @ViewBuilder private var symbol: some View {
    if let favicon = tab.favicon.flatMap(Self.image) {
      favicon.resizable().interpolation(.high).scaledToFit().accessibilityHidden(true)
    } else {
      Image(systemName: tab.kind.systemImage)
        .accessibilityHidden(true)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
  }

  private static func image(_ data: Data) -> Image? {
    #if os(macOS)
      NSImage(data: data).map(Image.init(nsImage:))
    #else
      UIImage(data: data).map(Image.init(uiImage:))
    #endif
  }

  private var dotColor: ThemeColor? {
    switch tab.status {
    case .needsYou, .unread: Theme.attention
    case .failed: Theme.failure
    case .running, .loading, .terminalActivity: Theme.running
    case .none, .exited: nil
    }
  }
}

/// Running, needs-you, loading and terminal activity marks.
struct TabStatusMark: View {
  let status: TabStatus

  var body: some View {
    switch status {
    case .none:
      EmptyView()
    case .needsYou:
      Circle().fill(Theme.attention).frame(width: 7, height: 7)
        .accessibilityLabel("Needs you")
    case .unread:
      Circle().fill(Theme.unread.opacity(0.6)).frame(width: 6, height: 6)
        .accessibilityLabel("Unread")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption2)
        .foregroundStyle(Theme.failure)
        .accessibilityLabel("Failed")
    case .running, .loading:
      ProgressView().controlSize(.mini)
        .accessibilityLabel(status.label ?? "")
    case .terminalActivity:
      LiveIndicator()
    case .exited:
      Image(systemName: "stop.circle")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Exited")
    }
  }
}

/// Pin, Duplicate, Move to New Window, Copy Link and the Close commands.
struct TabContextMenu: View {
  let tab: TabItemState
  let actions: TabActions
  let canCloseToRight: Bool

  var body: some View {
    Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin")
    {
      actions.setPinned(tab.id, !tab.isPinned)
    }
    if tab.canDuplicate {
      Button("Duplicate Tab", systemImage: "plus.square.on.square") { actions.duplicate(tab.id) }
    }
    if let moveToNewWindow = actions.moveToNewWindow {
      Button("Move Tab to New Window", systemImage: "macwindow.badge.plus") {
        moveToNewWindow(tab.id)
      }
    }
    if let link = tab.link {
      Button("Copy Link", systemImage: "link") { Pasteboard.copy(link.absoluteString) }
    }
    Divider()
    Button("Close Tab", systemImage: "xmark") { actions.close(tab.id) }
    Button("Close Other Tabs") { actions.closeOthers(tab.id) }
    Button("Close Tabs to the Right") { actions.closeToRight(tab.id) }
      .disabled(!canCloseToRight)
  }
}

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
  /// A background tab's narrowest: its icon, a status mark and about fourteen characters. Below
  /// this the strip scrolls.
  static let minWidth: CGFloat = 140
  /// A split strip section's narrowest, so the pane's tab keeps a readable title.
  static let sectionMinWidth: CGFloat = 180
  /// The close button's glyph frame: the Mac's 20 pt minimum. Touch extends its hit area to
  /// ``touchTarget`` without changing the layout.
  static let closeSize: CGFloat = 20
  /// The smallest touch target (HIG).
  static let touchTarget: CGFloat = 44
  static let maxWidth: CGFloat = 224
  /// The selected tab's width once the others shrink below it.
  static let selectedWidth: CGFloat = 200
  static let spacing: CGFloat = 2
}

/// One tab: icon, title, status and a close button on hover (always on the selected tab).
/// Pinned tabs show the icon only. A tab that cannot close (a session's primary chat) has no
/// close button. In a split window the other pane's tab shows a lighter selection.
struct TabItemView: View {
  let tab: TabItemState
  let isSelected: Bool
  let width: CGFloat
  let actions: TabActions
  let canCloseToRight: Bool
  /// The tab is shown in the split window's other pane, the one without focus.
  var isVisibleInOtherPane = false
  /// The window is split, for the context menu's pane items.
  var isSplit = false

  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.tabStatusDetails) private var statusDetails

  var body: some View {
    HStack(spacing: Theme.Spacing.small - 2) {
      TabIcon(tab: tab, isSelected: isSelected)
      if !tab.isPinned {
        Text(tab.displayTitle)
          .font(.callout.weight(isSelected || isVisibleInOtherPane ? .medium : .regular))
          .foregroundStyle(isSelected ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        // The title truncates first; the marks keep their own width after it. A background tab
        // shows one trailing mark: Close while hovered, else its status, else the audio glyph.
        HStack(spacing: Theme.Spacing.extraSmall) {
          if isSelected {
            if tab.isPlayingAudio { audioMark }
            TabStatusMark(status: tab.status)
            if tab.isClosable { closeButton }
          } else if isHovered, tab.isClosable {
            closeButton
          } else if tab.status != .none {
            TabStatusMark(status: tab.status)
          } else if tab.isPlayingAudio {
            audioMark
          }
        }
        .fixedSize()
        .layoutPriority(1)
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
    .contextMenu {
      TabContextMenu(
        tab: tab, actions: actions, canCloseToRight: canCloseToRight, isSplit: isSplit)
    }
    .help(help)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(tab.displayTitle)
    .accessibilityValue(accessibilityValue)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityAction { actions.select(tab.id) }
    .accessibilityIdentifier("tab-\(tab.kind.rawValue)-\(tab.id)")
    #if os(iOS)
      // iPad: drag a tab onto either half of the content to show it in that pane.
      .draggable(TabDropPayload.text(for: tab.id))
    #endif
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
        .font(.system(size: 10, weight: .bold))
        .frame(width: TabMetrics.closeSize, height: TabMetrics.closeSize)
        .contentShape(Circle())
        .touchTarget(width: TabMetrics.closeSize, height: TabMetrics.closeSize)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .hoverHighlight(cornerRadius: TabMetrics.closeSize / 2)
    .help("Close tab (Command-W)")
    .accessibilityLabel("Close \(tab.displayTitle)")
    .accessibilityIdentifier("tab-close-\(tab.id)")
  }

  @ViewBuilder private var background: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
    if isSelected {
      shape.fill(ThemeColor.surface)
        .overlay { shape.fill(ThemeColor.hover.opacity(isHovered ? 1 : 0)) }
        .overlay { shape.strokeBorder(ThemeColor.border, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
    } else if isVisibleInOtherPane {
      shape.fill(ThemeColor.surface.opacity(0.5))
        .overlay { shape.fill(ThemeColor.hover.opacity(isHovered ? 1 : 0)) }
        .overlay { shape.strokeBorder(ThemeColor.border.opacity(0.6), lineWidth: 0.5) }
    } else {
      shape.fill(ThemeColor.hover.opacity(isHovered ? 1 : 0))
    }
  }

  private var help: String {
    Self.help(tab, liveStatus: isSelected ? statusDetails?.detail(of: tab.id) : nil)
  }

  /// The tooltip: title, subtitle and status. The selected tab carries its session's live status
  /// line, as the titlebar has none of its own.
  /// - Parameters:
  ///   - tab: The tab.
  ///   - liveStatus: The session's status line, when the tab is selected.
  /// - Returns: The text.
  static func help(_ tab: TabItemState, liveStatus: String?) -> String {
    var parts = [tab.displayTitle]
    if let subtitle = tab.subtitle { parts.append(subtitle) }
    if let status = tab.statusDetail ?? liveStatus ?? tab.status.label { parts.append(status) }
    return parts.joined(separator: " \u{00B7} ")
  }

  private var accessibilityValue: String {
    Self.accessibilityValue(tab, isVisibleInOtherPane: isVisibleInOtherPane)
  }

  /// What VoiceOver reads after the title.
  /// - Parameters:
  ///   - tab: The tab.
  ///   - isVisibleInOtherPane: The split window's other pane shows it.
  /// - Returns: The text.
  static func accessibilityValue(_ tab: TabItemState, isVisibleInOtherPane: Bool) -> String {
    var parts = [tab.kind.label]
    if let pane = tab.pane { parts.append("\(pane.label) pane") }
    if isVisibleInOtherPane { parts.append("Shown") }
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
    case .needsYou: Theme.attention
    case .unread: Theme.unread
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
      // Calm, not the pink "needs you": activity the user has not seen, cleared on focus.
      Circle().fill(Theme.unread).frame(width: 7, height: 7)
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

/// Pin, Duplicate, Move to New Window, the split view, Copy Link and the Close commands. A tab
/// that cannot close keeps the items, disabled, as menus do on the Mac.
struct TabContextMenu: View {
  let tab: TabItemState
  let actions: TabActions
  let canCloseToRight: Bool
  var isSplit = false

  var body: some View {
    Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin")
    {
      actions.setPinned(tab.id, !tab.isPinned)
    }
    if tab.canDuplicate {
      Button("Duplicate Tab", systemImage: "plus.square.on.square") { actions.duplicate(tab.id) }
    }
    if tab.canRenameSession, let rename = actions.renameSession {
      Button("Rename Session\u{2026}", systemImage: "pencil") { rename(tab.id) }
        .accessibilityIdentifier("tab-menu-rename-session")
    }
    if let moveToNewWindow = actions.moveToNewWindow {
      Button("Move Tab to New Window", systemImage: "macwindow.badge.plus") {
        moveToNewWindow(tab.id)
      }
      .disabled(!tab.isClosable)
    }
    if let showInPane = actions.showInPane {
      if isSplit {
        let target = (tab.pane ?? .leading).other
        Button("Move to \(target.label) Pane", systemImage: "rectangle.split.2x1") {
          showInPane(tab.id, target)
        }
        .accessibilityIdentifier("tab-menu-other-pane")
      } else {
        Button("Open in Split View", systemImage: "rectangle.split.2x1") {
          showInPane(tab.id, .trailing)
        }
        .accessibilityIdentifier("tab-menu-split")
      }
    }
    if let link = tab.link {
      ConfirmedCopyButton(
        title: "Copy Link", systemImage: "link", text: link.absoluteString,
        confirmation: "Link copied")
    }
    Divider()
    Button("Close Tab", systemImage: "xmark") { actions.close(tab.id) }
      .disabled(!tab.isClosable)
    Button("Close Other Tabs") { actions.closeOthers(tab.id) }
    Button("Close Tabs to the Right") { actions.closeToRight(tab.id) }
      .disabled(!canCloseToRight)
  }
}

extension View {
  /// On touch, grows the hit area of a `width` by `height` view to 44 pt without moving
  /// anything; the Mac keeps the view's own frame.
  /// - Parameters:
  ///   - width: The view's width.
  ///   - height: The view's height.
  /// - Returns: The view with the larger hit area.
  func touchTarget(width: CGFloat, height: CGFloat) -> some View {
    modifier(TouchTarget(width: width, height: height))
  }
}

private struct TouchTarget: ViewModifier {
  let width: CGFloat
  let height: CGFloat

  func body(content: Content) -> some View {
    #if os(iOS)
      let horizontal = max(0, (TabMetrics.touchTarget - width) / 2)
      let vertical = max(0, (TabMetrics.touchTarget - height) / 2)
      content
        .padding(.horizontal, horizontal)
        .padding(.vertical, vertical)
        .contentShape(Rectangle())
        .padding(.horizontal, -horizontal)
        .padding(.vertical, -vertical)
    #else
      content
    #endif
  }
}

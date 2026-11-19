import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One card on a project's board, as the web's: the harness mark, the title and the session's
/// state, two lines of its last reply (or the working indicator), and a line of details. On a Mac
/// hovering shows its actions menu and the quick view button; the same actions are in its
/// context menu and are VoiceOver actions.
struct ProjectBoardCardView: View {
  let card: ProjectBoardCard
  let menu: SessionRowMenu
  let details: Set<SessionRowDetail>
  let harnessIcon: HarnessIconStyle
  /// Open in quick view beside the lanes.
  let isSelected: Bool
  /// Just joined the board.
  let isArrival: Bool
  /// The lane's title says it already, so the Needs you capsule stays off.
  let hidesNeedsYou: Bool
  /// The time ages count from; `nil` follows the clock.
  let now: Date?
  /// Opens the session in quick view; `nil` offers no quick view.
  let quickView: (@MainActor () -> Void)?

  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      titleLine
      replyLine
      if !metaParts.isEmpty {
        ProjectBoardCardMeta(parts: metaParts)
          .padding(.trailing, quickView == nil ? 0 : Theme.Control.icon + Theme.Spacing.small)
      }
    }
    .padding(Theme.Spacing.medium)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background { ProjectBoardSurface.card(cornerRadius: Theme.Radius.medium) }
    .cardSurface(cornerRadius: Theme.Radius.medium, stroke: stroke)
    .overlay {
      if isArrival || isSelected {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
          .strokeBorder(.tint, lineWidth: isArrival ? 2 : 1.5)
          .allowsHitTesting(false)
      }
    }
    .overlay(alignment: .bottomTrailing) { quickViewButton }
    .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 6 : 2, y: 1)
    .animation(reduceMotion ? nil : Theme.Motion.feedback, value: isHovered)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: isArrival)
    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    .onHover { isHovered = $0 }
    .contextMenu { menu.items }
    .help(card.session.title)
  }

  /// The border: the theme's, darker while hovered.
  private var stroke: ThemeColor? {
    isHovered ? ThemeColor.secondary.opacity(0.35) : nil
  }

  private var titleLine: some View {
    HStack(alignment: .center, spacing: Theme.Spacing.small) {
      if harnessIcon != .hidden {
        HarnessIcon(
          harness: card.info.harness,
          style: harnessIcon.resolved(isActive: SessionRow.isActive(card.session, info: card.info)))
      }
      Text(card.session.title)
        .fontWeight(card.isUnread ? .semibold : .medium)
        .lineLimit(1)
      Spacer(minLength: Theme.Spacing.extraSmall)
      if isHovered, !menu.actions.isEmpty {
        menuButton
      } else {
        badge
      }
    }
  }

  /// The card's actions, revealed by hover where the badge sits.
  private var menuButton: some View {
    Menu {
      menu.items
    } label: {
      Label("Actions for \(card.session.title)", systemImage: "ellipsis")
    }
    .menuIndicator(.hidden)
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .fixedSize()
    .help("Session actions")
    .accessibilityIdentifier("project-board-menu-\(card.id)")
  }

  /// What needs the user, as the sidebar row's marks: Needs you, a failure, unread.
  @ViewBuilder private var badge: some View {
    switch card.session.attention {
    case .needsYou:
      if !hidesNeedsYou { NeedsYouCapsule(requests: card.requests) }
    case .failed:
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(Theme.failure)
        .help(card.session.failureMessage.map { "Failed: \($0)" } ?? "Failed")
        .accessibilityLabel("Failed")
    case .working:
      EmptyView()
    case .unread, .idle:
      if card.isUnread {
        Circle().fill(Theme.unread).frame(width: 7, height: 7)
          .help("Unread")
          .accessibilityLabel("Unread")
      }
    }
  }

  /// Always two lines tall, so every card keeps one shape.
  private var replyLine: some View {
    Text(card.session.attention == .working ? " " : (card.preview ?? " "))
      .font(.callout)
      .foregroundStyle(.secondary)
      .lineLimit(2, reservesSpace: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .leading) {
        if card.session.attention == .working {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Working")
            .accessibilityIdentifier("project-board-working-\(card.id)")
        }
      }
  }

  /// Updated, nested agents, environment, repository and branch, as the sidebar's Show choice
  /// asks.
  private var metaParts: [ProjectBoardCardMeta.Part] {
    var parts: [ProjectBoardCardMeta.Part] = []
    if details.contains(.updated) {
      let age = RelativeTime.short(card.session.updatedDate, now: now ?? Date())
      parts.append(.init(id: "updated", systemImage: nil, text: age))
    }
    if card.nestedCount > 0 {
      parts.append(
        .init(id: "nested", systemImage: "square.stack", text: "\(card.nestedCount) nested"))
    }
    if details.contains(.environment), let environment = card.info.environment {
      parts.append(.init(id: "environment", systemImage: "laptopcomputer", text: environment))
    }
    if details.contains(.repo), let repo = card.info.repo {
      parts.append(.init(id: "repo", systemImage: "folder", text: repo))
    }
    if details.contains(.branch), let branch = card.info.branch {
      parts.append(.init(id: "branch", systemImage: "arrow.triangle.branch", text: branch))
    }
    return parts
  }

  @ViewBuilder private var quickViewButton: some View {
    if let quickView, isHovered || isSelected {
      Button("Quick view \(card.session.title)", systemImage: "sidebar.right", action: quickView)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(Theme.Spacing.small)
        .help("Quick view")
        .accessibilityIdentifier("project-board-peek-\(card.id)")
    }
  }
}

/// A card on a lane: focusable for the arrow keys, a click opens its session, a drag carries it
/// to another lane, and its reply preview is read as its turns end.
struct ProjectBoardCardCell: View {
  let card: ProjectBoardCard
  let state: ProjectBoardViewState
  let actions: ProjectBoardActions
  let menu: SessionRowMenu
  let quickView: (@MainActor () -> Void)?
  let isFocusable: Bool
  @Binding var dragging: String?
  var focusedCard: FocusState<String?>.Binding

  var body: some View {
    cardBody(quickView: quickView)
      .focusable(isFocusable)
      .focused(focusedCard, equals: card.id)
      .focusEffectDisabled()
      .overlay {
        if focusedCard.wrappedValue == card.id {
          RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .strokeBorder(Theme.focus, lineWidth: 2)
            .padding(-2)
            .allowsHitTesting(false)
        }
      }
      .onTapGesture { actions.open(card.id) }
      .onDrag {
        dragging = card.id
        return Self.provider(ProjectBoardDrag.payload(card.id))
      } preview: {
        cardBody(quickView: nil).frame(width: 260)
      }
      .opacity(dragging == card.id ? 0.4 : 1)
      .task(id: PreviewKey(card)) { await actions.loadPreview?(card) }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { actions.open(card.id) }
      .accessibilityActions { menu.accessibilityItems }
      .accessibilityIdentifier("project-board-card-\(card.id)")
  }

  private func cardBody(quickView: (@MainActor () -> Void)?) -> ProjectBoardCardView {
    ProjectBoardCardView(
      card: card, menu: menu, details: state.details, harnessIcon: state.harnessIcon,
      isSelected: state.quickViewID == card.id && quickView != nil,
      isArrival: state.arrivals.contains(card.id), hidesNeedsYou: card.lane == .needsAttention,
      now: state.now, quickView: quickView)
  }

  /// A drag's item: the payload as plain text.
  static func provider(_ payload: String) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .ownProcess
    ) { load in
      load(Data(payload.utf8), nil)
      return nil
    }
    return provider
  }

  private var accessibilityLabel: String {
    var parts = [card.session.title, card.lane.title]
    if card.nestedCount > 0 { parts.append("\(card.nestedCount) nested") }
    if let preview = card.preview, card.session.attention != .working { parts.append(preview) }
    return parts.joined(separator: ", ")
  }

  /// What a card's reply preview is read for: its head as it is now, once a turn ends.
  private struct PreviewKey: Hashable {
    let id: String
    let updatedAt: Int64
    let isWorking: Bool

    init(_ card: ProjectBoardCard) {
      id = card.id
      updatedAt = card.session.updatedAt
      isWorking = card.session.attention == .working
    }
  }
}

/// A card's details line: each part with its symbol, a dot between them.
struct ProjectBoardCardMeta: View {
  struct Part: Identifiable {
    let id: String
    let systemImage: String?
    let text: String
  }

  let parts: [Part]

  /// One run of text that wraps between parts, as the web's row does, and keeps each part
  /// whole instead of shrinking every part to its ends.
  var body: some View {
    parts.enumerated().reduce(Text(verbatim: "")) { line, entry in
      let (index, part) = entry
      let separator = index > 0 ? " \u{00B7} " : ""
      // No-break spaces inside a part, so a line breaks only between parts.
      let text = part.text.replacingOccurrences(of: " ", with: "\u{00A0}")
      guard let systemImage = part.systemImage else {
        return Text("\(line)\(separator)\(text)")
      }
      return Text("\(line)\(separator)\(Image(systemName: systemImage))\u{00A0}\(text)")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .lineLimit(2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension SessionListActions {
  /// Whether any of a row menu's actions is offered.
  var isEmpty: Bool {
    fork == nil && rename == nil && setUnread == nil && moveToProject == nil && stop == nil
      && setArchived == nil && delete == nil && leave == nil
  }
}

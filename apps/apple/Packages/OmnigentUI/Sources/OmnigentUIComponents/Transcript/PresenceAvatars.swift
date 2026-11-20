import SwiftUI

extension ConversationToolbar {
  /// The others viewing the session, from its presence section.
  static func otherViewers(_ state: ConversationViewState) -> [SectionReading.Viewer] {
    guard let presence = state.section("presence") else { return [] }
    return PresenceAvatars.others(SectionReading.viewers(presence), selfName: state.viewerName)
  }
}

extension TitlebarTrailingItems {
  /// The presence avatars' width, in button widths: one for an avatar, two for more.
  static func presence(_ state: ConversationViewState, isRegular: Bool) -> Int {
    guard isRegular else { return 0 }
    return min(ConversationToolbar.otherViewers(state).count, 2)
  }
}

/// Who else is viewing the session, in the toolbar (the web's `PresenceAvatars`): up to three
/// avatars, idle ones dimmed, then "+N"; each names the viewer on hover. The viewer's own
/// presence is left out, and nothing shows while no one else is here.
struct PresenceAvatars: View {
  let viewers: [SectionReading.Viewer]

  /// The most avatars shown before "+N".
  static let limit = 3

  /// The viewers to show: everyone but `selfName`.
  static func others(_ viewers: [SectionReading.Viewer], selfName: String?) -> [SectionReading
    .Viewer]
  {
    viewers.filter { $0.name != selfName }
  }

  var body: some View {
    if !viewers.isEmpty {
      HStack(spacing: Theme.Spacing.extraSmall) {
        ForEach(viewers.prefix(Self.limit)) { viewer in
          AuthorAvatar(
            name: viewer.name, initials: viewer.initials, size: 22, isIdle: viewer.isIdle
          )
          .help(viewer.isIdle ? "\(viewer.name) (idle)" : viewer.name)
        }
        if viewers.count > Self.limit {
          let overflow = viewers.dropFirst(Self.limit)
          Text("+\(overflow.count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .help(overflow.map(\.name).joined(separator: ", "))
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Also viewing: \(viewers.map(\.name).joined(separator: ", "))"
      )
      .accessibilityIdentifier("header-presence")
    }
  }
}

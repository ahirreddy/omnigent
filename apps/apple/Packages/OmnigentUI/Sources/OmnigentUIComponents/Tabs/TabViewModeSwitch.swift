import SwiftUI

/// The Chat / Terminal switch on a session's chat tab, in place of the tab's icon: two small
/// buttons, the shown view's lit. Choosing a side shows that view of the session's chat. The
/// buttons take their own clicks, so one neither selects, drags nor closes the tab.
struct TabViewModeSwitch: View {
  /// One side's size: the tab's icon, with room to hit it.
  static let side = CGSize(width: 22, height: 20)

  let mode: SessionViewMode
  let choose: (SessionViewMode) -> Void

  var body: some View {
    HStack(spacing: 1) {
      ForEach(SessionViewMode.allCases, id: \.self) { side in
        let isChosen = side == mode
        Button {
          choose(side)
        } label: {
          Image(systemName: side.systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isChosen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: Self.side.width, height: Self.side.height)
            .background(
              ThemeColor.hover.opacity(isChosen ? 1 : 0),
              in: RoundedRectangle(cornerRadius: Theme.Radius.small - 2, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the session's \(side.title.lowercased()) (Option-Command-\\)")
        .accessibilityLabel(side.title)
        .accessibilityValue(isChosen ? "Shown" : "")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("tab-view-mode-\(side.rawValue)")
      }
    }
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Chat or Terminal")
    .accessibilityIdentifier("session-view-mode")
  }
}

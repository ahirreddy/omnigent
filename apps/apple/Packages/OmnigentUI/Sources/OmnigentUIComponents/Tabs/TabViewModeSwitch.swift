import SwiftUI

/// The Chat / Terminal switch on a session's chat tab, in place of the tab's icon: a small
/// segmented control whose shown side sits on an accent pill. Choosing a side shows that view of
/// the session's chat. The sides take their own clicks, so one neither selects, drags nor closes
/// the tab.
struct TabViewModeSwitch: View {
  /// One side's size: the tab's icon, with room to hit it.
  static let side = CGSize(width: 22, height: 20)

  let mode: SessionViewMode
  let choose: (SessionViewMode) -> Void

  @Namespace private var pill
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let radius = Theme.Radius.small - 2

  var body: some View {
    HStack(spacing: 0) {
      ForEach(SessionViewMode.allCases, id: \.self) { side in
        let isChosen = side == mode
        Button {
          choose(side)
        } label: {
          Image(systemName: side.systemImage)
            .font(.system(size: 11, weight: isChosen ? .semibold : .regular))
            .foregroundStyle(isChosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            .frame(width: Self.side.width, height: Self.side.height)
            .background {
              if isChosen {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                  .fill(Theme.accent.opacity(0.18))
                  .overlay {
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                      .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
                  }
                  .matchedGeometryEffect(id: "pill", in: pill)
              }
            }
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
    .padding(1)
    .background(
      ThemeColor.hover, in: RoundedRectangle(cornerRadius: Self.radius + 1, style: .continuous)
    )
    .animation(reduceMotion ? nil : Theme.Motion.feedback, value: mode)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Chat or Terminal")
    .accessibilityIdentifier("session-view-mode")
  }
}

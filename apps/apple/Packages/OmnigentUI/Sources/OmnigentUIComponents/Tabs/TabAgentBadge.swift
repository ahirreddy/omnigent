import SwiftUI

/// The agent mark on a tab an agent drives: tinted while it acts, a person while the user holds
/// the page.
struct TabAgentBadge: View {
  let control: TabAgentControl

  var body: some View {
    Image(systemName: control == .user ? "person.fill" : "cursorarrow.rays")
      .font(.system(size: 7, weight: .bold))
      .foregroundStyle(control == .active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      .frame(width: 11, height: 11)
      .background {
        Circle().fill(control == .active ? AnyShapeStyle(.tint) : AnyShapeStyle(ThemeColor.surface))
      }
      .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
      .offset(x: -4, y: -3)
      .help(control.label)
      .accessibilityHidden(true)
  }
}

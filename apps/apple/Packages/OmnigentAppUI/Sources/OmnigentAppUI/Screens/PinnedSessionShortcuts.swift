import OmnigentUIComponents
import SwiftUI

/// Control-Command-1 to 9 and 0 open the Nth pinned session, as the web's Command-digit does
/// (Command-digit selects tabs here). Hidden buttons, so a hardware keyboard on iPad has them too.
struct PinnedSessionShortcuts: View {
  let open: @MainActor (Int) -> Void

  var body: some View {
    Group {
      ForEach(0..<10, id: \.self) { index in
        Button("Open Pinned Session \(index + 1)") { open(index) }
          .keyboardShortcut(AppShortcuts.pinnedSession(index))
      }
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }
}

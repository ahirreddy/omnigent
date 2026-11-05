import SwiftUI

/// A menu item that stays visible when it does not apply, disabled with the reason under its
/// title (and as its tooltip on the Mac), as the web keeps Fork and Share with a reason.
struct ReasonedMenuButton: View {
  let title: String
  let systemImage: String
  let unavailableReason: String?
  let action: @MainActor () -> Void

  init(
    _ title: String, systemImage: String, unavailableReason: String?,
    action: @escaping @MainActor () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.unavailableReason = unavailableReason
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
      if let unavailableReason { Text(unavailableReason) }
    }
    .disabled(unavailableReason != nil)
    .help(unavailableReason ?? "")
  }
}

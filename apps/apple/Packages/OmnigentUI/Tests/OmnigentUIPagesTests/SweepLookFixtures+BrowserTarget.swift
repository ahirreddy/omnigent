import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for the agent browser's choice: This Mac, the agent's machine or Auto.
@MainActor
extension SweepLookFixtures {
  /// The chip (Mac) or title-menu entry (iOS) for each choice, then the menu's items for a
  /// shared session: This Mac off with the owner-only reason, and the logins note.
  static var browserTarget: some View {
    let shared = BrowserTargetState(
      choice: .remote, localUnavailableReason: BrowserTargetState.ownerOnly)
    return VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        ForEach(BrowserTargetChoice.menuOrder, id: \.self) { choice in
          browserEntry(BrowserTargetState(choice: choice))
        }
      }
      .padding(8)
      .glassEffect(.regular, in: .capsule)
      Form {
        Section("Browser") {
          BrowserTargetMenuItems(state: shared) { _ in }
        }
      }
      .formStyle(.grouped)
    }
    .padding(16)
  }

  @ViewBuilder
  private static func browserEntry(_ state: BrowserTargetState) -> some View {
    #if os(macOS)
      BrowserTargetChip(state: state) { _ in }
    #else
      BrowserTargetSubmenu(state: state) { _ in }
    #endif
  }
}

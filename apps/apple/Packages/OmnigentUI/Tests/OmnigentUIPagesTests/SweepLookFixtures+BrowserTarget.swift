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
      browserEntries
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
      Form {
        Section("Browser") {
          BrowserTargetMenuItems(state: shared) { _ in }
        }
      }
      .formStyle(.grouped)
    }
    .padding(16)
  }

  /// A toolbar row of chips on a Mac; title-menu rows, one under another, on iOS.
  @ViewBuilder
  private static var browserEntries: some View {
    let states = BrowserTargetChoice.menuOrder.map { BrowserTargetState(choice: $0) }
    #if os(macOS)
      HStack(spacing: 12) {
        ForEach(states, id: \.choice) { BrowserTargetChip(state: $0) { _ in } }
      }
    #else
      VStack(alignment: .leading, spacing: 12) {
        ForEach(states, id: \.choice) { BrowserTargetSubmenu(state: $0) { _ in } }
      }
    #endif
  }
}

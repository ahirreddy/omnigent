import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for an approval link's sheet and a stale sandbox profile.
@MainActor
extension SweepLookFixtures {
  /// An `/approve/…` link's sheet: the request pending, or no longer.
  static func approvalLink(pending: Bool) -> some View {
    ApprovalLinkView(
      state: pending ? .pending(PreviewData.approval, .pending) : .resolved,
      respond: { _ in }, openSession: {}, done: {})
  }

  /// The new-session page on a branded server: its heading, and "Powered by Omnigent".
  static var brandedNewSession: some View {
    NewSessionPage(
      draft: .constant(""), composer: PreviewData.startComposer,
      actions: ComposerActions(send: {}), heading: "What should Acme build today?"
    )
    .environment(\.appBranding, AppBranding(appName: "Acme Agents", poweredBy: true))
  }

  /// Settings › Account for an admin, with the Admin view switch.
  static var adminView: some View {
    var actions = ServerSettingsActions()
    actions.setAdminView = { _ in }
    return Form {
      AccountSettingsPane(
        account: ServerAccountState(
          userID: "ada@example.com", isAdmin: true, canChangePassword: false,
          offersAdminView: true),
        actions: actions)
    }
    .formStyle(.grouped)
  }

  /// The sandbox profile chip once the chosen profile changed on the server.
  static var staleProfile: some View {
    let chosen = SandboxProfileOption(id: "p1", name: "Linux x86 32 GB", revision: "r1")
    return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      SandboxProfilePicker(
        state: SandboxProfilesState(profiles: [chosen], selected: chosen, isStale: true),
        actions: SandboxProfilesActions(select: { _ in }))
      Text("This profile changed or is unavailable. Choose a profile again before launching.")
        .font(.callout).foregroundStyle(.secondary)
    }
    .padding(Theme.Spacing.large)
  }
}

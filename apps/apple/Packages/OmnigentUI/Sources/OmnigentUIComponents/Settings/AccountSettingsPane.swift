import SwiftUI

/// Account: who the caller is signed in as, Change password (password accounts only) and Sign
/// out, as the web's Account section. Shown for password and SSO sign-ins alike.
struct AccountSettingsPane: View {
  let account: ServerAccountState?
  let actions: ServerSettingsActions
  @State private var confirmingSignOut = false

  var body: some View {
    if let account {
      Section {
        LabeledContent {
          if let signOut = actions.signOut {
            Button("Sign Out\u{2026}") { confirmingSignOut = true }
              .confirmationDialog(
                "Sign out of this server?", isPresented: $confirmingSignOut
              ) {
                Button("Sign Out", action: signOut)
              } message: {
                Text("Windows on this server return to the sign-in screen.")
              }
          }
        } label: {
          Label {
            VStack(alignment: .leading) {
              Text(account.userID).textSelection(.enabled)
              if account.isAdmin {
                Text("Administrator").font(.caption).foregroundStyle(.secondary)
              }
            }
          } icon: {
            Image(systemName: "person.crop.circle").accessibilityHidden(true)
          }
        }
        .accessibilityIdentifier("settings.account.identity")
      } header: {
        Text("Signed in as")
      }
    }
    if account?.canChangePassword ?? true {
      ChangePasswordPane(actions: actions)
    }
  }
}

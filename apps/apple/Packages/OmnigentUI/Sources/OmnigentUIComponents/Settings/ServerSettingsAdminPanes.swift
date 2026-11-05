import OmnigentPlatform
import SwiftUI

/// Members: every account, with password reset and removal on password-account servers.
struct MembersPane: View {
  let members: [ServerMember]
  let actions: ServerSettingsActions
  @State private var removing: ServerMember?
  @State private var newPassword: (member: String, password: String)?

  var body: some View {
    Section {
      if members.isEmpty { Text("No members.").foregroundStyle(.secondary) }
      ForEach(members) { member in
        LabeledContent {
          HStack {
            if member.isAdmin { Text("Admin").foregroundStyle(.secondary) }
            if member.canResetPassword || member.canRemove { menu(member) }
          }
        } label: {
          HStack(spacing: Theme.Spacing.small) {
            AuthorAvatar(name: member.id)
            VStack(alignment: .leading) {
              Text(member.id)
              if !member.detail.isEmpty {
                Text(member.detail).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    } footer: {
      Text("Roles are set by the server's admin list.")
    }
    .confirmationDialog(
      "Remove \(removing?.id ?? "")?", isPresented: removingBinding, presenting: removing
    ) { member in
      Button("Remove", role: .destructive) { actions.removeMember?(member) }
    } message: { _ in
      Text("They are signed out and can no longer sign in.")
    }
    .alert(
      "New password for \(newPassword?.member ?? "")", isPresented: passwordBinding,
      presenting: newPassword
    ) { _ in
      Button("Copy") { Pasteboard.copy(newPassword?.password ?? "") }
      Button("Done", role: .cancel) {}
    } message: { reset in
      Text(
        "\(reset.password)\n\nShown once. Send it to them privately; their sessions were signed out."
      )
    }
  }

  private func menu(_ member: ServerMember) -> some View {
    Menu {
      if member.canResetPassword, let reset = actions.resetPassword {
        Button("Reset Password\u{2026}") {
          Task {
            if let password = await reset(member) { newPassword = (member.id, password) }
          }
        }
      }
      if member.canRemove, actions.removeMember != nil {
        Button("Remove\u{2026}", role: .destructive) { removing = member }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Member actions")
  }

  private var removingBinding: Binding<Bool> {
    Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
  }

  private var passwordBinding: Binding<Bool> {
    Binding(get: { newPassword != nil }, set: { if !$0 { newPassword = nil } })
  }
}

/// Policies: server-wide defaults applied to new sessions.
struct PoliciesPane: View {
  let policies: [ServerSettingRow]
  let actions: ServerSettingsActions
  /// The policy whose removal is being confirmed.
  @State private var deleting: ServerSettingRow?

  var body: some View {
    Section {
      if policies.isEmpty { Text("No default policies.").foregroundStyle(.secondary) }
      ForEach(policies) { policy in
        HStack {
          Toggle(
            isOn: Binding(
              get: { policy.isEnabled }, set: { actions.setPolicyEnabled?(policy, $0) })
          ) {
            Text(policy.name)
            Text(policy.isReadOnly ? "From the server's config file" : policy.detail)
          }
          .disabled(policy.isReadOnly || actions.setPolicyEnabled == nil)
          if !policy.isReadOnly, actions.deletePolicy != nil {
            Button(role: .destructive) {
              deleting = policy
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(policy.name)")
          }
        }
      }
    } footer: {
      Text("Default policies apply to every new session on this server.")
    }
    .confirmationDialog(
      "Remove \(deleting?.name ?? "policy")?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { policy in
      Button("Remove", role: .destructive) { actions.deletePolicy?(policy) }
    } message: { _ in
      Text(
        "This removes the global policy from all sessions. Existing session-level policies with the same handler are unaffected."
      )
    }
  }
}

/// Sharing: who can share sessions, public links and which new sessions start public.
struct SharingPane: View {
  let sharing: SharingViewState?
  let actions: ServerSettingsActions

  var body: some View {
    if let sharing {
      Section {
        picker(
          "Who can share", sharing.mode, sharing.modeChoices, editable: sharing.modeEditable,
          change: SharingChange.mode)
      } footer: {
        Text("Applies to sessions people share with others on this server.")
      }
      Section {
        Toggle(
          "Allow public links",
          isOn: Binding(
            get: { sharing.publicSharing }, set: { actions.changeSharing?(.publicSharing($0)) })
        )
        .disabled(!sharing.publicSharingEditable || actions.changeSharing == nil)
        if let level = sharing.publicLevel, !sharing.publicLevelChoices.isEmpty {
          picker(
            "Public links grant", level, sharing.publicLevelChoices,
            editable: sharing.publicLevelEditable, change: SharingChange.publicLevel)
        }
        if let defaultPublic = sharing.defaultPublic, !sharing.defaultPublicChoices.isEmpty {
          picker(
            "New sessions start public", defaultPublic, sharing.defaultPublicChoices,
            editable: sharing.defaultPublicEditable, change: SharingChange.defaultPublic)
        }
      } header: {
        Text("Public access")
      } footer: {
        Text("Settings this deployment manages itself can't be changed here.")
      }
    }
  }

  private func picker(
    _ title: String, _ value: String, _ choices: [SettingChoice], editable: Bool,
    change: @escaping (String) -> SharingChange
  ) -> some View {
    Picker(
      title, selection: Binding(get: { value }, set: { actions.changeSharing?(change($0)) })
    ) {
      ForEach(choices) { Text($0.title).tag($0.id) }
    }
    .disabled(!editable || actions.changeSharing == nil)
  }
}

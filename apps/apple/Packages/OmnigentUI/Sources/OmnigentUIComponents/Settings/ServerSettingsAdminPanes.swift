import OmnigentPlatform
import SwiftUI

/// Members: every account, with password reset and removal on password-account servers.
struct MembersPane: View {
  let members: [ServerMember]
  let actions: ServerSettingsActions
  var errorMessage: String?
  @State private var removing: ServerMember?
  @State private var newPassword: (member: String, password: String)?
  @State private var isInviting = false

  var body: some View {
    Section {
      if let invite = actions.invite {
        Button("Invite Member\u{2026}", systemImage: "person.badge.plus") { isInviting = true }
          .accessibilityIdentifier("settings.invite-member")
          .sheet(isPresented: $isInviting) {
            InviteMemberSheet(invite: invite, errorMessage: errorMessage)
          }
      }
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
  var templates: [PolicyTemplate] = []
  let actions: ServerSettingsActions
  var errorMessage: String?
  @State private var isAdding = false
  /// The policy whose removal is being confirmed.
  @State private var deleting: ServerSettingRow?

  var body: some View {
    Section {
      if let add = actions.addPolicy {
        Button("Add Policy\u{2026}", systemImage: "plus") { isAdding = true }
          .accessibilityIdentifier("settings.add-policy")
          .sheet(isPresented: $isAdding) {
            AddPolicySheet(templates: templates, add: add, errorMessage: errorMessage)
          }
      }
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

/// Sharing, with the web's labels and explanations: who can share sessions (each tier
/// described), public access, its maximum permission and whether new sessions start shared.
/// A control another setting overrides is disabled with the reason.
struct SharingPane: View {
  let sharing: SharingViewState?
  let actions: ServerSettingsActions

  var body: some View {
    if let sharing {
      let sharingOff = sharing.mode == "off"
      Section("Session sharing") {
        picker(
          ("Who can share", Self.tierDescription(sharing.mode)), sharing.mode,
          sharing.modeChoices, editable: sharing.modeEditable, change: SharingChange.mode)
      }
      Section("Public sharing") {
        Toggle(
          isOn: Binding(
            get: { sharing.publicSharing && !sharingOff },
            set: { actions.changeSharing?(.publicSharing($0)) })
        ) {
          Text("Public access")
          Text(
            sharingOff
              ? "Turn sharing on to use public access."
              : "Allow sharing a session with anyone who has the link and can sign in. When off, "
                + "new public grants are rejected; existing ones stay accessible and can be "
                + "revoked." + managedNote(sharing.publicSharingEditable))
        }
        .disabled(sharingOff || !sharing.publicSharingEditable || actions.changeSharing == nil)
        if let level = sharing.publicLevel, !sharing.publicLevelChoices.isEmpty {
          picker(
            (
              "Maximum public permission",
              "The maximum access a public link can grant. Lowering this to Read also limits "
                + "existing public Edit grants. Raising it does not upgrade Read grants."
                + managedNote(sharing.publicLevelEditable)
            ), level, sharing.publicLevelChoices, editable: sharing.publicLevelEditable,
            change: SharingChange.publicLevel)
        }
        if let defaultPublic = sharing.defaultPublic, !sharing.defaultPublicChoices.isEmpty {
          let blocked =
            sharingOff
            ? "Turn sharing on to change the default visibility."
            : sharing.publicSharing
              ? nil : "Turn on public access to change the default visibility."
          picker(
            (
              "Share new sessions by default",
              blocked
                ?? "New sessions start with public read access for anyone with the link who "
                + "can sign in. Owners can revoke it in Share. Existing sessions are unchanged."
                + managedNote(sharing.defaultPublicEditable)
            ), defaultPublic, sharing.defaultPublicChoices,
            editable: sharing.defaultPublicEditable && blocked == nil,
            change: SharingChange.defaultPublic)
        }
      }
    }
  }

  /// The web's explanation of each sharing tier.
  static func tierDescription(_ mode: String) -> String? {
    switch mode {
    case "on":
      "Anyone with manage access can share a session at any level (read, edit, or manage) and "
        + "toggle public / workspace read."
    case "read_only":
      "New shares are capped at read (view) access. Edit and manage grants are rejected."
    case "restricted_read_only":
      "Read-only, and sessions whose working directory is a home directory or the filesystem "
        + "root cannot be shared at all, not even read."
    case "off":
      "Sharing is disabled. No new grants can be created and the Share control is hidden."
    default: nil
    }
  }

  private func managedNote(_ editable: Bool) -> String {
    editable ? "" : " Managed by this deployment and can't be changed here."
  }

  private func picker(
    _ label: (title: String, detail: String?), _ value: String, _ choices: [SettingChoice],
    editable: Bool, change: @escaping (String) -> SharingChange
  ) -> some View {
    Picker(selection: Binding(get: { value }, set: { actions.changeSharing?(change($0)) })) {
      ForEach(choices) { Text($0.title).tag($0.id) }
    } label: {
      Text(label.title)
      if let detail = label.detail { Text(detail) }
    }
    .disabled(!editable || actions.changeSharing == nil)
  }
}

import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The Share sheet over a ``ShareStore``: general access (restricted, or anyone with the link
/// can view, or edit where the server allows), and people with Read or Edit access. The owner's
/// own grant is not listed.
@MainActor
enum ShareAdapter {
  static let restricted = "Restricted"
  static let anyoneWithLink = "Anyone with the link can view"
  static let anyoneCanEdit = "Anyone with the link can edit"

  /// Why Share shows disabled: the web's wording for a server whose admin turned sharing off;
  /// `nil` where Share works or is hidden (single-user servers, pages not read yet).
  static func unavailableReason(_ pages: ServerPages?) -> String? {
    pages?.sharingDisabled == true
      ? automationShareDisabledReason(sharingDisabled: true, shareable: true, canClone: false)
      : nil
  }

  /// Why an automation's Share shows disabled: sharing off, else a legacy automation the server
  /// can't keep grants for (which it may offer to clone and share); `nil` where Share works.
  static func unavailableReason(_ pages: ServerPages?, automation: Automation) -> String? {
    automationShareDisabledReason(
      sharingDisabled: pages?.sharingDisabled == true, shareable: automation.shareable,
      canClone: pages?.automationClone == true)
  }

  /// Whether Share appears at all: on a server that shares, or one that turned sharing off.
  static func offered(_ pages: ServerPages?) -> Bool {
    pages.map { $0.sharing || $0.sharingDisabled } ?? false
  }

  /// The sheet's state.
  /// - Parameters:
  ///   - store: The session's sharing.
  ///   - link: The session's link.
  /// - Returns: The state.
  static func state(_ store: ShareStore, link: URL?) -> ShareViewState {
    let grants = (store.grants.value ?? []).filter {
      !$0.isOwner && $0.userId != publicGrantee()
    }
    let loadError: String? =
      if case .failed(let error) = store.grants { error.message } else { nil }
    let policy = store.policy
    var blockedReason: String?
    if policy?.sharingRestricted == true, let workspace = store.workspace,
      workspaceSharingBlocked(workspace: workspace)
    {
      blockedReason =
        "This session's working directory (a home or root directory) cannot be shared on this "
        + "Omnigent server."
    }
    // As the web: a public link is offered where the server allows one, and an existing one
    // can still be turned off.
    let offersPublic = (policy?.publicSharing ?? true) && blockedReason == nil
    var options = offersPublic || store.isPublic ? [restricted, anyoneWithLink] : [restricted]
    // Public Edit only up to the server's cap, never under read-only sharing; one already
    // granted stays listed.
    let offersPublicEdit =
      offersPublic && policy?.publicEdit == true && policy?.sharingReadOnly != true
    if offersPublicEdit || store.publicLevel == 2 { options.append(anyoneCanEdit) }
    var state = ShareViewState(
      generalAccessOptions: options, generalAccess: generalAccess(store.publicLevel),
      grants: grants.map { grant in
        ShareGrant(
          id: grant.userId, principal: grant.userId, role: grant.level >= 2 ? .edit : .read)
      },
      link: link, isSaving: store.isSaving || store.grants == .loading,
      errorMessage: store.error?.message ?? loadError)
    if policy?.sharingReadOnly == true {
      state.roles = [.read]
      state.isReadOnlySharing = true
    }
    state.blockedReason = blockedReason
    state.managedBy = store.managedBy.map { $0.name.isEmpty ? "Automation" : $0.name }
    state.workspaceFiles = store.workspaceFiles?.enabled ?? false
    return state
  }

  /// The general access choice for what the link grants.
  static func generalAccess(_ publicLevel: UInt8?) -> String {
    switch publicLevel {
    case nil: restricted
    case 1: anyoneWithLink
    default: anyoneCanEdit
    }
  }

  /// The wire level for a role.
  static func level(_ role: ShareGrant.Role) -> UInt8 { role == .edit ? 2 : 1 }

  /// The sheet's actions.
  /// - Parameters:
  ///   - store: The session's sharing.
  ///   - openAutomation: Opens an automation's page on its share sheet.
  /// - Returns: The actions.
  static func actions(
    _ store: ShareStore, openAutomation: (@MainActor (String) -> Void)? = nil
  ) -> ShareActions {
    var actions = ShareActions(
      setGeneralAccess: { access in
        let level: UInt8? =
          switch access {
          case anyoneWithLink: 1
          case anyoneCanEdit: 2
          default: nil
          }
        Task { await store.setPublicLevel(level) }
      },
      addGrant: { person, role in
        Task { await store.grant(person, level: level(role)) }
      },
      setRole: { grant, role in
        Task { await store.grant(grant.principal, level: level(role)) }
      },
      removeGrant: { grant in
        Task { await store.revoke(grant.principal) }
      })
    if let openAutomation, let id = store.managedBy?.id {
      actions.openManagingAutomation = { openAutomation(id) }
    }
    // As the web: the files toggle shows only for a session with a working directory.
    if store.workspaceFiles?.workspace != nil {
      actions.setWorkspaceFiles = { enabled in Task { await store.setWorkspaceFiles(enabled) } }
    }
    return actions
  }
}

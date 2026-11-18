import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The Share sheet over a ``ShareStore``: general access (restricted, or anyone with the link
/// can view), and people with Read or Edit access. The owner's own grant is not listed.
@MainActor
enum ShareAdapter {
  static let restricted = "Restricted"
  static let anyoneWithLink = "Anyone with the link can view"

  /// Why Share shows disabled: the web's wording for a server whose admin turned sharing off;
  /// `nil` where Share works or is hidden (single-user servers, pages not read yet).
  static func unavailableReason(_ pages: ServerPages?) -> String? {
    pages?.sharingDisabled == true ? "Sharing has been disabled for this Omnigent server." : nil
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
    var state = ShareViewState(
      generalAccessOptions: offersPublic || store.isPublic
        ? [restricted, anyoneWithLink] : [restricted],
      generalAccess: store.isPublic ? anyoneWithLink : restricted,
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
    return state
  }

  /// The wire level for a role.
  static func level(_ role: ShareGrant.Role) -> UInt8 { role == .edit ? 2 : 1 }

  /// The sheet's actions.
  /// - Parameter store: The session's sharing.
  /// - Returns: The actions.
  static func actions(_ store: ShareStore) -> ShareActions {
    ShareActions(
      setGeneralAccess: { access in
        Task { await store.setPublic(access == anyoneWithLink) }
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
  }
}

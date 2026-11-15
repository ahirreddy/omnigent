import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The provisional "New nested agent" rows of open Add nested agent composers, as the web's
/// `withNestedSessionDrafts` lays them over the sidebar: each the last member of its source's
/// family (a standalone source gets a family of its own), until the server's row replaces it.
enum SidebarNestedDraftRows {
  /// `state` with `drafts`' rows; a draft the list already shows for real, or whose source the
  /// sidebar doesn't show, adds nothing.
  static func applied(
    to state: SidebarViewState, drafts: [NestedSessionDraft], list: SessionListStore
  ) -> SidebarViewState {
    guard !drafts.isEmpty else { return state }
    var state = state
    let listed = Array(list.sessionsByID.values)
    for draft in drafts where !listed.contains(where: draft.isReplaced) {
      add(draft, to: &state)
    }
    return state
  }

  private static func add(_ draft: NestedSessionDraft, to state: inout SidebarViewState) {
    guard let index = state.list.sessions.firstIndex(where: { $0.id == draft.source.id }) else {
      return
    }
    var source = state.list.sessions[index]
    let family =
      source.family
      ?? SessionFamilyInfo(
        id: source.id, representativeID: source.id, representativeTitle: source.title,
        isPinned: source.isPinned)
    source.family = family
    state.list.sessions[index] = source
    let row = OmnigentUIComponents.SessionSummary(
      id: draft.id, title: NestedSessionDraft.title, updatedAt: source.updatedAt,
      workspace: source.workspace, canRename: false, canPin: false, canArchive: false,
      isNestedMember: true, family: family)
    state.list.sessions.insert(row, at: index + 1)
    state.rowInfo[draft.id] = SessionRowInfo(createdAt: draft.createdAt)
    if let folder = state.projects.firstIndex(where: { $0.sessionIds.contains(source.id) }) {
      state.projects[folder].sessionIds.append(draft.id)
    }
    if draft.createdSessionID == nil { state.nestedDrafts[draft.id] = source.id }
  }
}

/// Drops the provisional rows the list now shows for real, as rows arrive.
struct NestedDraftRetirement: ViewModifier {
  let connection: ConnectionStore

  func body(content: Content) -> some View {
    content.onChange(of: trigger, initial: true) {
      let list = connection.sessionList
      connection.creationStore?.retireNestedDrafts { list.session($0) }
    }
  }

  /// What would retire a draft: each one's created session having its family, and its source's
  /// archived state.
  private var trigger: [Bool] {
    let list = connection.sessionList
    return (connection.creationStore?.nestedDrafts ?? []).flatMap { draft in
      [
        draft.createdSessionID.map { list.session($0)?.family != nil } ?? false,
        list.session(draft.source.id)?.isArchived == true,
      ]
    }
  }
}

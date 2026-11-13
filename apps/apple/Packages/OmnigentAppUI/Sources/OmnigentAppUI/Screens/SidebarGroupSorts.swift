import Foundation
import OSLog
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// How Pinned and each project sort their sessions, kept across launches for each server and
/// user beside the sidebar's display options. Pinned's custom order is the server's pin order.
enum SidebarGroupSortDefaults {
  /// Where an account's sorts are kept.
  static func key(account: String) -> String { "omnigent:sidebar-group-sorts:\(account)" }

  /// The saved sorts of `account`, or none.
  static func load(account: String, _ defaults: UserDefaults = .standard) -> SessionGroupSorts {
    guard let data = defaults.data(forKey: key(account: account)) else {
      return SessionGroupSorts()
    }
    do {
      return try JSONDecoder().decode(SessionGroupSorts.self, from: data)
    } catch {
      // Sorts saved by another build that no longer decode fall back to each group's default.
      defaults.removeObject(forKey: key(account: account))
      return SessionGroupSorts()
    }
  }

  /// Saves `sorts` for `account`; with nothing chosen the key is removed.
  static func save(
    _ sorts: SessionGroupSorts, account: String, _ defaults: UserDefaults = .standard,
    encode: (SessionGroupSorts) throws -> Data = { try JSONEncoder().encode($0) }
  ) {
    guard sorts != SessionGroupSorts() else {
      defaults.removeObject(forKey: key(account: account))
      return
    }
    do {
      defaults.set(try encode(sorts), forKey: key(account: account))
    } catch {
      // The last saved sorts stay; the choice lasts until the window closes.
      Logger(subsystem: "ai.omnigent.app", category: "sidebar").error(
        "Could not encode the sidebar group sorts: \(String(describing: error), privacy: .public)"
      )
    }
  }
}

/// Each account's group sorts: read from the defaults once, and saved with every change.
@Observable
final class SidebarGroupSortStore {
  /// Counts the changes, so a view that read the sorts draws again.
  private var revision = 0
  @ObservationIgnored private var loaded: [String: SessionGroupSorts] = [:]
  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The sorts of `account`; each group's default until a server is connected.
  func sorts(for account: String?) -> SessionGroupSorts {
    _ = revision
    guard let account else { return SessionGroupSorts() }
    if let sorts = loaded[account] { return sorts }
    let sorts = SidebarGroupSortDefaults.load(account: account, defaults)
    loaded[account] = sorts
    return sorts
  }

  /// Changes the sorts of `account` and saves them; nothing until a server is connected.
  func update(_ account: String?, _ change: (inout SessionGroupSorts) -> Void) {
    guard let account else { return }
    var sorts = sorts(for: account)
    change(&sorts)
    guard sorts != loaded[account] else { return }
    loaded[account] = sorts
    SidebarGroupSortDefaults.save(sorts, account: account, defaults)
    revision += 1
  }
}

extension ConnectedServerView {
  /// The account whose group sorts the sidebar shows; `nil` until a server is connected.
  var groupSortAccount: String? { connection.connectedServer?.accountId }

  func withGroupSortActions(_ actions: SidebarActions) -> SidebarActions {
    var actions = actions
    actions.setGroupSort = { group, sort in setGroupSort(group, sort) }
    actions.reorderGroup = { group, ids in reorderGroup(group, ids) }
    return actions
  }

  /// Chooses how a group sorts its sessions.
  func setGroupSort(_ group: SessionGroup, _ sort: SessionGroupSort) {
    let shown = SidebarNavigationOrder.groupIDs(group, in: sidebarState)
    sidebarModel.groupSorts.update(groupSortAccount) { $0.choose(sort, for: group, shown: shown) }
  }

  /// Saves a group's sessions in a new order, which it then shows as Custom. A project's order
  /// stays on this device; Pinned's is the server's pin order, and a refusal shows in the list's
  /// alert, which offers it again.
  func reorderGroup(_ group: SessionGroup, _ ids: [String]) {
    sidebarModel.groupSorts.update(groupSortAccount) { $0.reorder(group, shown: ids) }
    guard group == .pinned else { return }
    let list = connection.sessionList
    Task {
      if await !list.setPinOrder(ids) {
        list.offerRetry("Could Not Reorder the Pinned Sessions") { reorderGroup(group, ids) }
      }
    }
  }

  /// Forgets the sorts of deleted projects and the places of sessions that left a project.
  var groupSortPruning: GroupSortPruning {
    let list = connection.sessionList
    return GroupSortPruning(store: sidebarModel.groupSorts, account: groupSortAccount) {
      (sidebarState, !list.searchText.isEmpty)
    }
  }
}

/// Keeps the saved group sorts to what the sidebar still shows, in a body of its own: a change
/// to the list then runs this and not the window.
struct GroupSortPruning: ViewModifier {
  let store: SidebarGroupSortStore
  let account: String?
  /// The sidebar's state, and whether a search hides sessions.
  let shown: () -> (state: SidebarViewState, isSearching: Bool)

  func body(content: Content) -> some View {
    content.onChange(of: pruned, initial: true) { _, pruned in
      store.update(account) { $0 = pruned }
    }
  }

  private var pruned: SessionGroupSorts {
    let shown = shown()
    var sorts = store.sorts(for: account)
    sorts.prune(to: shown.state, isSearching: shown.isSearching)
    return sorts
  }
}

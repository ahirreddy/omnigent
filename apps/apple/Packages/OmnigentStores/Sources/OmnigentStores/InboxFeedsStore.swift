import Foundation
public import Observation
public import OmnigentCoreFFI

/// The Inbox's server-side feeds beside the sessions: items agents post for their owner, and
/// automation failures that made no session. Changes show at once and are undone when the server
/// refuses them; a refusal stays in ``itemWriteError`` until the next change.
@Observable
public final class InboxFeedsStore {
  /// Open agent-posted items loaded so far, newest first.
  public private(set) var items: [AgentInboxItemRecord] = []
  /// The first page has been read.
  public private(set) var itemsLoaded = false
  /// More items are on the server.
  public var hasMoreItems: Bool { itemsCursor != nil }
  /// A page of items is being read.
  public private(set) var isLoadingItems = false
  /// Why the last read of items failed.
  public private(set) var itemsError: CoreError?
  /// Every unread item the caller has, as the server last counted it.
  public private(set) var unreadCount: UInt64 = 0
  /// The server stopped counting at its cap.
  public private(set) var unreadCountCapped = false
  /// The last change the server refused.
  public private(set) var itemWriteError: CoreError?

  /// Automation failures loaded so far, one per automation.
  public private(set) var failures: [AutomationFailureRecord] = []
  /// More automations remain to check.
  public var hasMoreFailures: Bool { failuresCursor != nil }
  /// A page of failures is being read.
  public private(set) var isLoadingFailures = false
  /// Why the last read of failures failed.
  public private(set) var failuresError: CoreError?
  /// Failed runs marked read on this device.
  public private(set) var readRunIDs: Set<String> = []

  /// The runs a device remembers as read, the oldest dropped first.
  static let readRunLimit = 1000

  private let core: ClientCore
  private let defaults: UserDefaults
  private var itemsCursor: String?
  private var failuresCursor: String?
  private var readRunsKey: String?
  private var readRunOrder: [String] = []
  /// Reads started so far; only the latest one lands, so a reset drops one in flight.
  private var itemReads = 0
  private var failureReads = 0

  init(core: ClientCore, defaults: UserDefaults = .standard) {
    self.core = core
    self.defaults = defaults
  }

  /// The failures to show: each automation once, without runs marked read.
  public var unreadFailures: [AutomationFailureRecord] {
    var seen = Set<String>()
    return failures.filter { !readRunIDs.contains($0.runId) && seen.insert($0.taskId).inserted }
  }

  /// Forgets another server's or account's feeds.
  func reset() {
    itemReads += 1
    failureReads += 1
    items = []
    itemsLoaded = false
    itemsCursor = nil
    itemsError = nil
    isLoadingItems = false
    unreadCount = 0
    unreadCountCapped = false
    itemWriteError = nil
    failures = []
    failuresCursor = nil
    failuresError = nil
    isLoadingFailures = false
  }

  // MARK: Agent-posted items

  /// Reads the first page of items again, replacing what was loaded.
  public func refreshItems() async {
    await readItems(after: nil)
  }

  /// Reads the page after the loaded items.
  public func loadMoreItems() async {
    guard let cursor = itemsCursor, !isLoadingItems else { return }
    await readItems(after: cursor)
  }

  private func readItems(after cursor: String?) async {
    itemReads += 1
    let read = itemReads
    isLoadingItems = true
    do {
      let page = try await core.agentInboxItems(after: cursor)
      guard read == itemReads else { return }
      let open = page.items.filter(\.isOpen)
      if cursor == nil {
        items = open
      } else {
        let known = Set(items.map(\.id))
        items += open.filter { !known.contains($0.id) }
      }
      itemsCursor = page.nextCursor
      unreadCount = page.unreadCount
      unreadCountCapped = page.unreadCountCapped
      itemsLoaded = true
      itemsError = nil
    } catch {
      guard read == itemReads else { return }
      itemsError = coreError(error)
    }
    isLoadingItems = false
  }

  /// Marks an unread item read, as expanding it does on the web.
  public func markRead(_ itemID: String) async {
    guard let index = items.firstIndex(where: { $0.id == itemID }), items[index].isUnread
    else { return }
    let before = items[index]
    items[index].isUnread = false
    if unreadCount > 0, !unreadCountCapped { unreadCount -= 1 }
    await write(restoring: before) { try await $0.markAgentInboxItem(itemId: itemID, read: true) }
  }

  /// Records the action at `index` as taken, which takes the item out of the Inbox.
  /// - Returns: Whether the server took it.
  @discardableResult
  public func takeAction(_ itemID: String, index: UInt32) async -> Bool {
    await resolve(itemID) { try await $0.takeAgentInboxAction(itemId: itemID, index: index) }
  }

  /// Dismisses an item for `reason`, which takes it out of the Inbox.
  /// - Returns: Whether the server took it.
  @discardableResult
  public func dismiss(_ itemID: String, reason: InboxDismissReason) async -> Bool {
    await resolve(itemID) { try await $0.dismissAgentInboxItem(itemId: itemID, reason: reason) }
  }

  private func resolve(
    _ itemID: String, _ operation: (ClientCore) async throws -> AgentInboxUpdateRecord
  ) async -> Bool {
    guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
    let before = items[index]
    items.remove(at: index)
    if before.isUnread, unreadCount > 0, !unreadCountCapped { unreadCount -= 1 }
    return await write(restoring: before, at: index, operation)
  }

  /// Sends a change shown already; the server's reply replaces the item and the count, and a
  /// refusal puts `before` back.
  @discardableResult
  private func write(
    restoring before: AgentInboxItemRecord, at removedIndex: Int? = nil,
    _ operation: (ClientCore) async throws -> AgentInboxUpdateRecord
  ) async -> Bool {
    itemWriteError = nil
    let reads = itemReads
    do {
      let update = try await operation(core)
      guard reads == itemReads || removedIndex != nil else { return true }
      unreadCount = update.unreadCount
      unreadCountCapped = update.unreadCountCapped
      if let index = items.firstIndex(where: { $0.id == update.item.id }) {
        if update.item.isOpen { items[index] = update.item } else { items.remove(at: index) }
      }
      return true
    } catch {
      itemWriteError = coreError(error)
      if let removedIndex {
        if !items.contains(where: { $0.id == before.id }) {
          items.insert(before, at: min(removedIndex, items.count))
        }
        if before.isUnread, !unreadCountCapped { unreadCount += 1 }
      } else if let index = items.firstIndex(where: { $0.id == before.id }) {
        if before.isUnread, !items[index].isUnread, !unreadCountCapped { unreadCount += 1 }
        items[index] = before
      }
      return false
    }
  }

  /// Clears a refused change's message.
  public func dismissItemWriteError() {
    itemWriteError = nil
  }

  // MARK: Automation failures

  /// Reads the first page of failures again, replacing what was loaded.
  public func refreshFailures() async {
    await readFailures(after: nil)
  }

  /// Checks the next page of automations ("Check more automations").
  public func loadMoreFailures() async {
    guard let cursor = failuresCursor, !isLoadingFailures else { return }
    await readFailures(after: cursor)
  }

  private func readFailures(after cursor: String?) async {
    failureReads += 1
    let read = failureReads
    isLoadingFailures = true
    do {
      let page = try await core.automationFailures(after: cursor)
      guard read == failureReads else { return }
      if cursor == nil {
        failures = page.failures
      } else {
        let known = Set(failures.map(\.taskId))
        failures += page.failures.filter { !known.contains($0.taskId) }
      }
      failuresCursor = page.nextCursor
      failuresError = nil
    } catch {
      guard read == failureReads else { return }
      failuresError = coreError(error)
    }
    isLoadingFailures = false
  }

  /// Keeps failed runs marked read under `key`: one server and account on this device.
  /// - Parameter key: Where the marks live.
  public func bindReadFailures(key: String) {
    guard readRunsKey != key else { return }
    readRunsKey = key
    readRunOrder = defaults.stringArray(forKey: key) ?? []
    readRunIDs = Set(readRunOrder)
  }

  /// Marks a failed run read on this device; a later failed run shows again.
  /// - Parameter runID: The run.
  public func markFailureRead(_ runID: String) {
    guard readRunIDs.insert(runID).inserted else { return }
    readRunOrder.append(runID)
    if readRunOrder.count > Self.readRunLimit {
      let dropped = readRunOrder.prefix(readRunOrder.count - Self.readRunLimit)
      readRunIDs.subtract(dropped)
      readRunOrder.removeFirst(dropped.count)
    }
    if let readRunsKey { defaults.set(readRunOrder, forKey: readRunsKey) }
  }
}

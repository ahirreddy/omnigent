import SwiftUI

/// Menu actions that a ``FocusedActionsRelay`` can publish as a focused value.
@MainActor
public protocol FocusedActions {
  /// What the menus show from these actions: which ones exist, and any counts or titles.
  associatedtype MenuSignature: Hashable

  /// What the menus show; the relay publishes a new value only when this changes.
  var menuSignature: MenuSignature { get }

  /// A copy whose closures call the same closures of the actions `latest` returns.
  /// - Parameter latest: The newest actions.
  /// - Returns: The forwarding copy.
  func forwarding(to latest: @escaping @MainActor () -> Self?) -> Self
}

/// Publishes a struct of closures as a focused value that keeps its identity across updates.
///
/// A view that builds its menu actions in `body` makes new closures on every update. Published
/// with `focusedSceneValue`, each new value rebuilds the menus, and on iOS that rebuild updates
/// the publishing view again: a busy loop at 100% CPU. The relay publishes one value for as long
/// as the ``FocusedActions/menuSignature`` is the same, and its closures call the latest actions.
/// Keep it in `@State`.
@MainActor
public final class FocusedActionsRelay<Actions: FocusedActions> {
  private var latest: Actions?
  private var published: Actions?
  private var signature: Actions.MenuSignature?
  /// How many times a new value was published, for tests.
  private(set) var publications = 0

  /// Creates a relay.
  public init() {}

  /// The value to publish for `actions`: the last one while the menus would look the same.
  /// - Parameter actions: The current actions, or `nil` for none.
  /// - Returns: The value for `focusedSceneValue`.
  public func publish(_ actions: Actions?) -> Actions? {
    latest = actions
    guard let actions else {
      published = nil
      signature = nil
      return nil
    }
    let current = actions.menuSignature
    if published == nil || signature != current {
      published = actions.forwarding { [weak self] in self?.latest }
      signature = current
      publications += 1
    }
    return published
  }
}

extension FocusedActions {
  /// `action`'s forwarding copy: `nil` stays `nil`, otherwise it calls `latest`'s action at
  /// `path`.
  static func forward(
    _ action: (@MainActor () -> Void)?, _ path: KeyPath<Self, (@MainActor () -> Void)?>,
    to latest: @escaping @MainActor () -> Self?
  ) -> (@MainActor () -> Void)? {
    guard action != nil else { return nil }
    return { latest()?[keyPath: path]?() }
  }
}

extension SessionCommandActions: FocusedActions {
  /// Which commands are enabled, and whether Approve owns Command-Return.
  public var menuSignature: [Bool] {
    [
      send != nil, interrupt != nil, jumpToLatest != nil, focusComposer != nil,
      toggleInspector != nil, previousSession != nil, nextSession != nil,
      toggleViewMode != nil, openChanges != nil, approveOwnsCommandReturn,
    ]
  }

  /// A copy whose commands call `latest`'s.
  /// - Parameter latest: The newest commands.
  /// - Returns: The forwarding copy.
  public func forwarding(to latest: @escaping @MainActor () -> Self?) -> Self {
    var copy = Self(
      send: Self.forward(send, \.send, to: latest),
      interrupt: Self.forward(interrupt, \.interrupt, to: latest),
      jumpToLatest: Self.forward(jumpToLatest, \.jumpToLatest, to: latest),
      focusComposer: Self.forward(focusComposer, \.focusComposer, to: latest),
      toggleInspector: Self.forward(toggleInspector, \.toggleInspector, to: latest),
      previousSession: Self.forward(previousSession, \.previousSession, to: latest),
      nextSession: Self.forward(nextSession, \.nextSession, to: latest),
      toggleViewMode: Self.forward(toggleViewMode, \.toggleViewMode, to: latest),
      openChanges: Self.forward(openChanges, \.openChanges, to: latest))
    copy.approveOwnsCommandReturn = approveOwnsCommandReturn
    return copy
  }
}

extension PaletteCommandActions: FocusedActions {
  /// Both actions always exist.
  public var menuSignature: Bool { true }

  /// A copy whose actions call `latest`'s.
  /// - Parameter latest: The newest actions.
  /// - Returns: The forwarding copy.
  public func forwarding(to latest: @escaping @MainActor () -> Self?) -> Self {
    Self(
      openPalette: { latest()?.openPalette() }, openShortcuts: { latest()?.openShortcuts() })
  }
}

extension TabCommandActions: FocusedActions {
  /// The tab menus' state: which items are enabled, the tab count and the split state.
  nonisolated public struct MenuSignature: Hashable {
    let enabled: [Bool]
    let count: Int
    let supportsSplit: Bool
    let isSplit: Bool
  }

  /// Which tab commands are enabled, the tab count and the split state.
  public var menuSignature: MenuSignature {
    MenuSignature(
      enabled: [
        closeTab != nil, reopenClosedTab != nil, selectNextTab != nil,
        selectPreviousTab != nil, togglePinned != nil, duplicateTab != nil,
        moveTabToNewWindow != nil, showAllTabs != nil, openBrowser != nil,
        toggleTerminal != nil, toggleSplit != nil, focusPane != nil, moveTabToOtherPane != nil,
      ], count: count, supportsSplit: supportsSplit, isSplit: isSplit)
  }

  /// A copy whose commands call `latest`'s.
  /// - Parameter latest: The newest commands.
  /// - Returns: The forwarding copy.
  public func forwarding(to latest: @escaping @MainActor () -> Self?) -> Self {
    var copy = Self(
      newTab: { latest()?.newTab() },
      closeTab: Self.forward(closeTab, \.closeTab, to: latest),
      reopenClosedTab: Self.forward(reopenClosedTab, \.reopenClosedTab, to: latest),
      selectTab: { latest()?.selectTab($0) },
      selectNextTab: Self.forward(selectNextTab, \.selectNextTab, to: latest),
      selectPreviousTab: Self.forward(selectPreviousTab, \.selectPreviousTab, to: latest),
      togglePinned: Self.forward(togglePinned, \.togglePinned, to: latest),
      duplicateTab: Self.forward(duplicateTab, \.duplicateTab, to: latest),
      moveTabToNewWindow: Self.forward(moveTabToNewWindow, \.moveTabToNewWindow, to: latest),
      showAllTabs: Self.forward(showAllTabs, \.showAllTabs, to: latest),
      openBrowser: Self.forward(openBrowser, \.openBrowser, to: latest),
      toggleTerminal: Self.forward(toggleTerminal, \.toggleTerminal, to: latest),
      count: count)
    copy.supportsSplit = supportsSplit
    copy.isSplit = isSplit
    copy.toggleSplit = Self.forward(toggleSplit, \.toggleSplit, to: latest)
    if focusPane != nil {
      copy.focusPane = { latest()?.focusPane?($0) }
    }
    copy.moveTabToOtherPane = Self.forward(moveTabToOtherPane, \.moveTabToOtherPane, to: latest)
    return copy
  }
}

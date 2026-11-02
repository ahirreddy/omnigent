import Foundation

/// The scenario's split view, mirroring the app's tab store: each pane shows one of its tabs,
/// a pane left empty closes the split, and a split of one tab gets a new-tab page.
extension TabsPlaygroundModel {
  /// The tab a pane shows; the selected tab when not split.
  func tab(in pane: TabPane) -> TabItemState? {
    let id = split?.activeID(pane) ?? selectedID
    return tabs.first { $0.id == id }
  }

  func addSplit(to actions: inout TabActions) {
    actions.showInPane = { self.show($0, in: $1) }
    actions.focusPane = { self.focus($0) }
    actions.setSplitFraction = { fraction in self.split?.fraction = TabSplitState.clamp(fraction) }
    actions.closeSplit = { self.closeSplit() }
  }

  func addSplit(to commands: inout TabCommandActions) {
    commands.supportsSplit = true
    commands.isSplit = split != nil
    commands.toggleSplit = { self.toggleSplit() }
    if split != nil { commands.focusPane = { self.focus($0) } }
    if let selectedID {
      let target = tabs.first { $0.id == selectedID }?.pane?.other ?? .trailing
      commands.moveTabToOtherPane = { self.show(selectedID, in: target) }
    }
  }

  /// Shows a tab in a pane and focuses it, splitting the window when it is not.
  func show(_ id: String, in target: TabPane) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    if split == nil {
      let previous = selectedID == id ? nil : selectedID
      for position in tabs.indices {
        tabs[position].pane = position == index ? target : target.other
      }
      var other = previous ?? tabs.first { $0.id != id }?.id
      if other == nil {
        var blank = TabItemState(
          id: UUID().uuidString, kind: .newTab, title: "New Tab", canDuplicate: false)
        blank.pane = target.other
        tabs.append(blank)
        other = blank.id
      }
      split = TabSplitState(
        leadingID: target == .leading ? id : other, trailingID: target == .trailing ? id : other,
        focused: target)
      selectedID = id
      sortByPane()
      return
    }
    guard let source = tabs[index].pane, source != target else {
      select(id)
      return
    }
    let rest = tabs.filter { $0.pane == source && $0.id != id }
    guard let replacement = rest.first(where: { $0.id == split?.activeID(source) }) ?? rest.first
    else {
      closeSplit()
      selectedID = id
      return
    }
    tabs[index].pane = target
    split = TabSplitState(
      leadingID: target == .leading ? id : replacement.id,
      trailingID: target == .trailing ? id : replacement.id, focused: target,
      fraction: split?.fraction ?? 0.5)
    selectedID = id
    sortByPane()
  }

  func focus(_ pane: TabPane) {
    guard let current = split, current.focused != pane else { return }
    split?.focused = pane
    selectedID = current.activeID(pane)
  }

  func toggleSplit() {
    if split != nil {
      closeSplit()
    } else if let selectedID {
      let partner = tabs.first { $0.id != selectedID && $0.kind == .browser }
      if let partner {
        show(partner.id, in: .trailing)
        focus(.leading)
      } else {
        show(selectedID, in: .leading)
        focus(.trailing)
      }
    }
  }

  func closeSplit() {
    split = nil
    for index in tabs.indices { tabs[index].pane = nil }
  }

  /// A tab left: its pane shows a neighbour, or the split closes when the pane is empty.
  func leave(_ id: String, pane: TabPane?, at index: Int) {
    guard let split, let pane else {
      if selectedID == id {
        selectedID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
      }
      return
    }
    let rest = tabs.filter { $0.pane == pane }
    guard let next = rest.first(where: { $0.id == split.activeID(pane) }) ?? rest.last else {
      selectedID = split.activeID(pane.other)
      closeSplit()
      return
    }
    if pane == .leading {
      self.split?.leadingID = next.id
    } else {
      self.split?.trailingID = next.id
    }
    if split.focused == pane { selectedID = next.id }
  }

  /// Keeps the focused pane's tab in step with the selection.
  func syncSplit() {
    guard let split, let selectedID else { return }
    if split.focused == .leading {
      self.split?.leadingID = selectedID
    } else {
      self.split?.trailingID = selectedID
    }
  }

  private func sortByPane() {
    tabs = tabs.filter { $0.pane != .trailing } + tabs.filter { $0.pane == .trailing }
  }
}

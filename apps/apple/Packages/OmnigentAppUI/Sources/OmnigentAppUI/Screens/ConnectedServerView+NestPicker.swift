import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Nests picker's server search, opened from a row's Move session › Nests.
extension ConnectedServerView {
  /// Opens the picker for `session`.
  func openNestPicker(for session: OmnigentUIComponents.SessionSummary) {
    let list = connection.sessionList
    sidebarModel.nestPicker = NestPickerFlow(
      session: session,
      search: { query, after throws(CoreError) in
        try await list.searchTitles(query, after: after)
      },
      isOwned: { list.isOwned($0) })
  }

  /// The picker: the loaded nests and the server's matches; choosing one moves the session.
  func nestPickerSheet(_ flow: NestPickerFlow) -> some View {
    let state = sidebarState
    let rowInfo = state.rowInfo
    let query = Binding(get: { flow.query }, set: { flow.query = $0 })
    return NestPickerSheet(
      session: flow.session, local: state.list.sessions,
      isShared: { rowInfo[$0]?.isShared == true }, results: flow.results, query: query,
      actions: nestPickerActions(flow))
  }

  /// Joining or leaving a nest closes the picker and moves the session.
  private func nestPickerActions(_ flow: NestPickerFlow) -> NestPickerActions {
    let model = sidebarModel
    let sessionID = flow.session.id
    let close: @MainActor () -> Void = {
      flow.close()
      model.nestPicker = nil
    }
    let move: @MainActor (String?) -> Void = { destination in
      close()
      moveToNest(sessionID, destination: destination)
    }
    var leave: (@MainActor () -> Void)?
    if flow.session.family != nil { leave = { move(nil) } }
    return NestPickerActions(
      join: { move($0.id) }, leave: leave, more: { flow.more() }, dismiss: close)
  }
}

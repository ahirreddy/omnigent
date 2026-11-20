import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// Opening a session that has a plan or tasks shows its Tasks tab once they are known (web
/// `TasksTabOnOpen`). Only the opening does: a tab picked afterwards stays. An iPhone keeps the
/// chat in front, as the web leaves a phone's drawer closed.
struct TasksTabOnOpen: ViewModifier {
  let sessionID: String
  /// The session's snapshot and journal are read, so whether it has tasks is known.
  let known: Bool
  let hasTasks: @MainActor () -> Bool
  let show: @MainActor () -> Void

  @State private var opened: String?
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  func body(content: Content) -> some View {
    content.onChange(of: known ? sessionID : nil, initial: true) { _, ready in
      guard let ready, opened != ready else { return }
      opened = ready
      if showsPanel, hasTasks() { show() }
    }
  }

  private var showsPanel: Bool {
    #if os(iOS)
      sizeClass != .compact
    #else
      true
    #endif
  }
}

extension TasksAdapter {
  /// Whether the session's tasks are known: its snapshot is read, and its journal too where the
  /// server keeps one.
  static func tasksKnown(_ tasks: SessionTasksStore?, conversation: ConversationStore) -> Bool {
    guard conversation.header != nil else { return false }
    guard let journal = tasks?.journal else { return true }
    return journal != .idle && journal != .loading
  }

  /// The chat's one-line preview of the session's tasks, while it has some (web
  /// `hasTaskPreview`).
  static func preview(
    tasks: SessionTasksStore?, conversation: ConversationStore,
    summary: OmnigentCoreFFI.SessionSummary?
  ) -> ChatTasksPreviewState? {
    guard tasks?.journal != .loading,
      let view = view(tasks: tasks, conversation: conversation, summary: summary),
      !view.rows.isEmpty
    else { return nil }
    return ChatTasksPreviewState(
      finished: Int(view.finished), total: view.rows.count, text: view.preview,
      planName: view.planName)
  }

  /// Whether the Tasks tab lists anything: a plan, journal tasks or the agent's own list.
  static func hasTasks(_ tasks: SessionTasksStore?, conversation: ConversationStore) -> Bool {
    guard case .shown(let ids) = listedTasks(tasks: tasks, conversation: conversation) else {
      return false
    }
    return !ids.isEmpty
  }
}

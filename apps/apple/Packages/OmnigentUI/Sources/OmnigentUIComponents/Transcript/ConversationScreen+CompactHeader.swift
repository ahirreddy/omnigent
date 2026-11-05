import SwiftUI

// The compact (iPhone) header, as the web's mobile header: the title keeps its menu, which leads
// with Chat and Terminal and lists the right panel's tabs with their counts.

extension ConversationScreen {
  /// A sub-agent's parent session.
  var parentSessionID: String? {
    state.header.settings?.parentId.flatMap { $0.isEmpty || $0 == state.header.id ? nil : $0 }
  }

  /// The header's project tag: the viewer's own top-level session.
  var showsProjectTag: Bool {
    state.summary != nil
      && HeaderProjectTag.applies(
        extras.menuContext, isSubagent: parentSessionID != nil,
        canMove: extras.sessionActions.moveToProject != nil)
  }
}

extension SessionViewMode {
  /// The mode's label.
  var title: String {
    switch self {
    case .chat: "Chat"
    case .terminal: "Terminal"
    }
  }

  /// The mode's SF Symbol.
  var systemImage: String {
    switch self {
    case .chat: "bubble.left.and.text.bubble.right"
    case .terminal: "apple.terminal"
    }
  }
}

/// Chat and Terminal at the top of the compact title menu, the current one checked.
struct CompactViewModeItems: View {
  @Binding var mode: SessionViewMode

  var body: some View {
    Picker("View", selection: $mode) {
      ForEach(SessionViewMode.allCases, id: \.self) { mode in
        Label(mode.title, systemImage: mode.systemImage).tag(mode)
      }
    }
    .pickerStyle(.inline)
    .accessibilityIdentifier("header-view-mode")
  }
}

/// The right panel's tabs in the compact title menu, each with its count, opening the panel on it.
struct CompactPanelItems: View {
  let labels: InspectorTabLabels
  let show: (InspectorTab) -> Void

  var body: some View {
    Section("Right Panel") {
      ForEach(labels.tabs) { tab in
        Button(labels.label(for: tab), systemImage: tab.systemImage) { show(tab) }
          .accessibilityIdentifier("header-panel-\(tab.rawValue)")
      }
    }
  }
}

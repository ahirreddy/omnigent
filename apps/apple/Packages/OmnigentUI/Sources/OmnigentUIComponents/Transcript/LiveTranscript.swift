import SwiftUI

/// The transcript with its rows read in its own body, so row changes re-render only this view.
struct LiveTranscript: View {
  let state: ConversationViewState
  let liveRows: LiveTranscriptRows?
  let actions: ConversationActions
  let scrollToLatestRequest: Int

  var body: some View {
    var current = state
    if let liveRows {
      let live = liveRows.read()
      current.rows = live.rows
      current.revision = live.revision
    }
    return TranscriptView(
      state: current, actions: actions, scrollToLatestRequest: scrollToLatestRequest)
  }
}

extension TitlebarTrailingItems {
  /// The conversation screen's trailing toolbar items, in button widths: viewers (two), Agent
  /// info, the session menu, Share (titled, two) and the right-panel toggle.
  static func count(
    _ state: ConversationViewState, hasShare: Bool, tabsInTitlebar: Bool, isRegular: Bool
  ) -> Int {
    var items = 1
    if state.section("presence") != nil, isRegular { items += 2 }
    if let info = state.agentInfo, !(info.tools.isEmpty && info.policies.isEmpty) { items += 1 }
    if tabsInTitlebar { items += 1 }
    if hasShare, isRegular { items += 2 }
    return items
  }
}

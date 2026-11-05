import SwiftUI

/// The transcript with its rows read in its own body, so row changes re-render only this view.
/// The rows arrive paced (``TranscriptRowsPacer``), and a kept tab out of view keeps the rows it
/// last showed, so streaming into it costs nothing until it shows again.
struct LiveTranscript: View {
  let state: ConversationViewState
  let liveRows: LiveTranscriptRows?
  let actions: ConversationActions
  let scrollToLatestRequest: Int

  @Environment(\.isTabContentHidden) private var isHidden
  @State private var pacer = TranscriptRowsPacer()

  var body: some View {
    var current = state
    if let liveRows {
      let live = pacer.rows(from: liveRows, isShown: !isHidden)
      current.rows = live.rows
      current.revision = live.revision
    }
    return TranscriptView(
      state: current, actions: actions, scrollToLatestRequest: scrollToLatestRequest)
  }
}

extension TitlebarTrailingItems {
  /// The conversation screen's trailing toolbar items, in button widths: viewers (two), Agent
  /// info, the session menu, Share (titled, two), the right-panel toggle and the project tag.
  static func count(
    _ state: ConversationViewState, hasShare: Bool, tabsInTitlebar: Bool, isRegular: Bool,
    projectTag: Bool = false
  ) -> Int {
    var items = projectTag ? 2 : 1
    if state.section("presence") != nil, isRegular { items += 2 }
    if let info = state.agentInfo, !(info.tools.isEmpty && info.policies.isEmpty) { items += 1 }
    if tabsInTitlebar { items += 1 }
    if hasShare, isRegular { items += 2 }
    return items
  }
}

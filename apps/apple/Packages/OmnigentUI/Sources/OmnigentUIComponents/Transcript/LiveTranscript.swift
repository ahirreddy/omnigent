import SwiftUI

/// The transcript over live rows. Its row list reads them in its own body
/// (``TranscriptRowsContent``), so row changes re-render only the list. The rows arrive paced
/// (``TranscriptRowsPacer``), and a kept tab out of view keeps the rows it last showed, so
/// streaming into it costs nothing until it shows again.
struct LiveTranscript: View {
  let state: ConversationViewState
  let liveRows: LiveTranscriptRows?
  let actions: ConversationActions
  let scrollToLatestRequest: Int

  var body: some View {
    TranscriptView(
      state: state, liveRows: liveRows, actions: actions,
      scrollToLatestRequest: scrollToLatestRequest)
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

  /// The Chat / Terminal switch leading the trailing items (82 points and the gap beside it),
  /// in button widths.
  static let viewSwitch = 3
}

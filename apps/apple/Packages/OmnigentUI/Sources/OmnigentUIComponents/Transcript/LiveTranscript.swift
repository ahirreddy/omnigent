import SwiftUI

/// The transcript over live rows. Its row list reads them in its own body
/// (``TranscriptRowsContent``), so row changes re-render only the list. The rows arrive paced
/// (``TranscriptRowsPacer``), and a kept tab out of view keeps the rows it last showed, so
/// streaming into it costs nothing until it shows again. It shows in a list of reused cells
/// (``TableTranscriptView``); `omnigent:transcript-list stack` shows the lazy stack instead.
struct LiveTranscript: View {
  let state: ConversationViewState
  let liveRows: LiveTranscriptRows?
  let actions: ConversationActions
  let scrollToLatestRequest: Int

  var body: some View {
    if TranscriptListKind.current == .table {
      TableTranscriptView(
        state: state, liveRows: liveRows, actions: actions,
        scrollToLatestRequest: scrollToLatestRequest)
    } else {
      stack
    }
  }

  private var stack: some View {
    TranscriptView(
      state: state, liveRows: liveRows, actions: actions,
      scrollToLatestRequest: scrollToLatestRequest)
  }
}

extension TitlebarTrailingItems {
  /// The conversation screen's trailing toolbar items, in button widths: Agent info, the
  /// session menu, Share and the right-panel toggle, and a width for the gaps and margins of
  /// the glass group that holds them.
  static func count(
    _ state: ConversationViewState, hasShare: Bool, tabsInTitlebar: Bool, isRegular: Bool
  ) -> Int {
    var items = 2
    if let info = state.agentInfo, !(info.tools.isEmpty && info.policies.isEmpty) { items += 1 }
    if tabsInTitlebar { items += 1 }
    if hasShare, isRegular { items += 1 }
    #if os(macOS)
      if state.sandbox != nil { items += 1 }
    #endif
    return items + presence(state, isRegular: isRegular)
  }

  /// The Chat / Terminal switch leading the trailing items (82 points and the gap beside it),
  /// in button widths.
  static let viewSwitch = 3
}

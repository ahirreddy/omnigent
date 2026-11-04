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

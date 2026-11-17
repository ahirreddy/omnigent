#if os(iOS)
  import Observation
  import SwiftUI
  import UIKit

  /// A text row's links: workspace paths its message cites link once their folders'
  /// listings show them, and links open as in the row's SwiftUI markdown.
  extension TranscriptCollectionTextView {
    // MARK: Links

    /// Opens a link as the row's SwiftUI markdown would: a workspace file in the app when the
    /// session has links, anything else through the transcript's own action.
    func openLink(_ url: URL) {
      guard let values = style.environment.values else { return }
      let action =
        values.workspaceFileLinks?.openURLAction(fallback: values.openURL) ?? values.openURL
      action(url)
    }

    /// The URLs of the paths `message` cites, in order; empty while none is known to exist,
    /// so the text is the one built ahead. Reading the listings here shows the row again once
    /// one changes.
    func linkedPaths(of message: TranscriptTableTextMessage) -> [URL?] {
      let cited = message.split.cited
      guard let links = style.environment.values?.workspaceFileLinks, !cited.isEmpty else {
        return []
      }
      linkWatch += 1
      let watch = linkWatch
      let linked = withObservationTracking {
        cited.map { links.target(for: $0.text, explicit: $0.explicit)?.url }
      } onChange: { [weak self] in
        MainRunLoop.perform {
          MainActor.assumeIsolated { self?.linksChanged(watch) }
        }
      }
      return linked.contains { $0 != nil } ? linked : []
    }

    func linksChanged(_ watch: Int) {
      guard watch == linkWatch else { return }
      showAgain()
    }

    func restartLinkCheck() {
      stopLinkCheck()
      startLinkCheck()
    }

    func stopLinkCheck() {
      linkCheck?.cancel()
      linkCheck = nil
    }

    /// Lists the folders of the paths the shown message cites, as a SwiftUI row's task does
    /// while it is on screen.
    func startLinkCheck() {
      guard linkCheck == nil, window != nil, let message, !message.split.cited.isEmpty,
        let links = style.environment.values?.workspaceFileLinks
      else { return }
      let cited = message.split.cited
      linkCheck = Task { await links.check(cited) }
    }
  }
#endif

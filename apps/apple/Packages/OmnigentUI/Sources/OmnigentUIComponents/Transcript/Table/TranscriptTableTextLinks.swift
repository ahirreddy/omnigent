#if os(macOS)
  import AppKit
  import Observation
  import SwiftUI

  /// A text cell's workspace links, as ``WorkspacePathLinking`` gives a SwiftUI row them: the
  /// paths a message cites link once their folders' listings show them, and in-app file links
  /// open in the app.
  extension TranscriptTableTextCell {
    /// The URLs of the paths `message` cites, in order, as ``MessageTextMarkdownView`` links
    /// them; empty while none is known to exist, so the text is the one built ahead. Reading
    /// the listings here shows the row again once one changes.
    func linkedPaths(of message: TranscriptTableTextMessage, links: WorkspaceFileLinks?)
      -> [URL?]
    {
      let cited = message.split.cited
      guard let links, !cited.isEmpty else { return [] }
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

    /// A listing the shown row read changed: the row shows again with what it found.
    private func linksChanged(_ watch: Int) {
      guard watch == linkWatch else { return }
      showAgain()
    }

    /// Lists the cited paths' folders for the row just shown, while the cell is in a window.
    func restartLinkCheck() {
      stopLinkCheck()
      startLinkCheck()
    }

    func stopLinkCheck() {
      linkCheck?.cancel()
      linkCheck = nil
    }

    /// Lists the folders of the paths the shown message cites, as a SwiftUI row's task does
    /// while it is on screen; a listing already made or under way isn't asked again.
    private func startLinkCheck() {
      guard linkCheck == nil, unsafe window != nil, let message, !message.split.cited.isEmpty,
        let links = style.environment.values?.workspaceFileLinks
      else { return }
      let cited = message.split.cited
      linkCheck = Task { await links.check(cited) }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if unsafe window == nil { stopLinkCheck() } else { startLinkCheck() }
    }

    /// Opens a link as the row's SwiftUI markdown would: a workspace file in the app when the
    /// session has links, anything else through the transcript's own action.
    static func openURL(in values: EnvironmentValues) -> @MainActor (URL) -> Void {
      let action =
        values.workspaceFileLinks?.openURLAction(fallback: values.openURL) ?? values.openURL
      return { url in action(url) }
    }
  }
#endif

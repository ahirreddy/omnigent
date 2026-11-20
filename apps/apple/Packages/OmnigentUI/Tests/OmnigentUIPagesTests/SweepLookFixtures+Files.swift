import Foundation
import SwiftUI

@testable import OmnigentUIComponents
@testable import OmnigentWorkspaceUI

/// Generic data for the sweep's file preview and side chat screens.
@MainActor
extension SweepLookFixtures {
  /// A Markdown file with its table of contents open.
  static var markdownContents: some View {
    UserDefaults.standard.set(true, forKey: "workspace.markdownContents")
    let file = """
      # Release checklist

      Run these before tagging a build.

      ## Tests
      The fast tier and the flows for the areas touched.

      ### Rechecks
      Run a flaky flow again before calling it.

      ## Notes
      Write one line per change.
      """
    return MarkdownPreviewPane(text: file) { AnyView(MarkdownView($0)) }
  }

  /// A new side chat's composer with the session's model and effort menus.
  static var sideChatSettings: some View {
    let configuration = ComposerConfiguration(
      harness: "claude-sdk",
      modelOptions: [
        ModelOption(id: "opus", displayName: "Opus", supportedReasoningEfforts: ["low", "high"]),
        ModelOption(id: "sonnet", displayName: "Sonnet", supportedReasoningEfforts: ["low"]),
      ],
      selectedModelId: "sonnet", selectedEffort: "low")
    return PendingSideChatView(
      draft: .constant("Why does the retry wait?"),
      parent: CreatingSession(id: "conv_a", title: "Fix the upload retry"), isStarting: false,
      failure: nil, send: {}, dismissFailure: {}, openParent: { _ in },
      settings: PendingSideChatSettings(
        configuration: configuration, selectModel: { _ in }, selectEffort: { _ in }))
  }
}

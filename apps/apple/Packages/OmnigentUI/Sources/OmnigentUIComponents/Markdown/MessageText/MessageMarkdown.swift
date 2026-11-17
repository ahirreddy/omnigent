import Foundation
import SwiftUI

/// Which view draws a chat message's markdown.
nonisolated enum MessageTextRenderer: String, Hashable, Sendable {
  /// A SwiftUI `Text` per paragraph, heading, table cell and code block: the stack's, and
  /// iPhone and iPad's.
  case swiftUI = "swiftui"
  /// One TextKit 2 text view per run of text blocks, its layout kept: the Mac table's.
  case textKit = "textkit"

  /// `omnigent:message-text`: a user default, or a launch argument such as
  /// `-omnigent:message-text swiftui`.
  static let key = "omnigent:message-text"

  /// The renderer this launch's defaults choose.
  static let launchValue = Self(defaults: .standard)

  /// The renderer `defaults` choose. Without a choice (or with an unknown one) it follows the
  /// list: TextKit in the Mac's table, SwiftUI in the stack and on iPhone and iPad.
  init(defaults: UserDefaults) {
    if let chosen = defaults.string(forKey: Self.key).flatMap(Self.init(rawValue:)) {
      self = chosen
      return
    }
    #if os(macOS)
      self = TranscriptListKind.read(from: defaults) == .table ? .textKit : .swiftUI
    #else
      self = .swiftUI
    #endif
  }
}

extension EnvironmentValues {
  /// Which view draws a message's markdown: the launch's choice unless a host sets one.
  @Entry var messageTextRenderer = MessageTextRenderer.launchValue
}

/// A transcript message's markdown, drawn by ``MarkdownView`` or, on the Mac with the TextKit
/// renderer chosen, by ``MessageTextMarkdownView``, streaming or settled.
struct MessageMarkdown: View {
  let text: String
  var isStreaming = false
  /// Fill the row (an answer) or hug the text (a user's bubble).
  var fillsWidth = true
  @Environment(\.messageTextRenderer) private var renderer
  @Environment(\.markdownOutputRendering) private var rendering

  var body: some View {
    #if os(macOS)
      if renderer == .textKit, rendering == .rich {
        MessageTextMarkdownView(text: text, isStreaming: isStreaming, fillsWidth: fillsWidth)
          .readingProseStyle()
          .tint(Theme.link)
          .countsRenders("markdown")
      } else {
        MarkdownView(text, isStreaming: isStreaming)
      }
    #else
      MarkdownView(text, isStreaming: isStreaming)
    #endif
  }
}

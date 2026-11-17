import Foundation
import SwiftUI

/// Which view draws a chat message's markdown.
nonisolated enum MessageTextRenderer: String, Hashable, Sendable {
  /// A SwiftUI `Text` per paragraph, heading, table cell and code block: the default.
  case swiftUI = "swiftui"
  /// One TextKit 2 text view per run of text blocks, its layout kept (a macOS prototype).
  case textKit = "textkit"

  /// `omnigent:message-text`: a user default, or a launch argument such as
  /// `-omnigent:message-text textkit`.
  static let key = "omnigent:message-text"

  /// The renderer this launch's defaults choose.
  static let launchValue = Self(defaults: .standard)

  /// The renderer `defaults` choose; anything else is the default.
  init(defaults: UserDefaults) {
    self = defaults.string(forKey: Self.key).flatMap(Self.init(rawValue:)) ?? .swiftUI
  }
}

extension EnvironmentValues {
  /// Which view draws a message's markdown: the launch's choice unless a host sets one.
  @Entry var messageTextRenderer = MessageTextRenderer.launchValue
}

/// A transcript message's markdown, drawn by ``MarkdownView`` or, on the Mac with the TextKit
/// renderer chosen, by ``MessageTextMarkdownView`` once the message has settled.
struct MessageMarkdown: View {
  let text: String
  var isStreaming = false
  /// Fill the row (an answer) or hug the text (a user's bubble).
  var fillsWidth = true
  @Environment(\.messageTextRenderer) private var renderer
  @Environment(\.markdownOutputRendering) private var rendering

  var body: some View {
    #if os(macOS)
      if renderer == .textKit, rendering == .rich, !isStreaming {
        MessageTextMarkdownView(text: text, fillsWidth: fillsWidth)
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

import SwiftUI

/// A sent prompt's leading command or skill, tinted as the web's bubble tints it: the
/// composer's rule (``ComposerTokens/command(in:commands:)``) over the session's commands. Not
/// for a message from another session, or one with attachments, which aren't commands.
nonisolated enum PromptCommand {
  /// The link destination that marks the command in a prompt's Markdown; the parser keeps its
  /// text, draws no link and sets ``PromptCommandAttribute``.
  static let destination = "omnigent-command:"

  /// `text`'s leading known command, in characters, where it starts the first line.
  static func range(in text: String, commands: [SlashCommand]) -> Range<Int>? {
    guard !commands.isEmpty, let range = ComposerTokens.command(in: text, commands: commands)
    else { return nil }
    // Spaces before it would make the Markdown an indented block, so only line breaks may.
    return text.prefix(range.lowerBound).allSatisfy(\.isNewline) ? range : nil
  }

  /// `markdown` with its leading command marked for the Markdown renderers; as it is without
  /// one. Each marking is a text of its own, so cached parses and layouts stay apart.
  static func marked(_ markdown: String, commands: [SlashCommand]) -> String {
    guard let range = range(in: markdown, commands: commands) else { return markdown }
    let start = markdown.index(markdown.startIndex, offsetBy: range.lowerBound)
    let end = markdown.index(start, offsetBy: range.count)
    return "\(markdown[..<start])[\(markdown[start..<end])](\(destination))\(markdown[end...])"
  }

  /// `text` with each marked run in `color`.
  static func tinted(_ text: AttributedString, color: Color) -> AttributedString {
    guard text.runs[PromptCommandAttribute.self].contains(where: { $0.0 == true }) else {
      return text
    }
    var tinted = text
    for (marked, range) in text.runs[PromptCommandAttribute.self] where marked == true {
      tinted[range].foregroundColor = color
    }
    return tinted
  }
}

/// Marks a sent prompt's leading command in parsed Markdown (``PromptCommand``).
nonisolated enum PromptCommandAttribute: AttributedStringKey {
  typealias Value = Bool
  static let name = "omnigent.promptCommand"
}

extension EnvironmentValues {
  /// The session's commands and skills, for tinting a sent prompt's leading command.
  @Entry var promptCommands: [SlashCommand] = []
}

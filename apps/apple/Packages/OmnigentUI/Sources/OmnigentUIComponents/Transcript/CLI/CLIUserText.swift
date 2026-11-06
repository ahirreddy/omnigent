import SwiftUI

extension UserPrompt {
  /// A run of a prompt: plain text, or a Markdown block quote without its `>` markers.
  struct Run: Hashable, Sendable {
    let text: String
    let isQuote: Bool
  }

  /// `text` split into plain and block-quote runs, as a reply that quotes the transcript sends
  /// it. Lines inside fenced code are never quotes.
  static func runs(_ text: String) -> [Run] {
    guard text.contains(">") else { return [Run(text: text, isQuote: false)] }
    var runs: [Run] = []
    var lines: [Substring] = []
    var isQuoting = false
    var isInFence = false
    func close() {
      let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
      if !joined.isEmpty { runs.append(Run(text: joined, isQuote: isQuoting)) }
      lines = []
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let indented = line.drop { $0 == " " }
      if indented.hasPrefix("```") || indented.hasPrefix("~~~") { isInFence.toggle() }
      let isQuote = !isInFence && indented.hasPrefix(">")
      if isQuote != isQuoting {
        close()
        isQuoting = isQuote
      }
      lines.append(isQuote ? unquoted(indented) : line)
    }
    close()
    return runs
  }

  private static func unquoted(_ line: Substring) -> Substring {
    let rest = line.dropFirst()
    return rest.first == " " ? rest.dropFirst() : rest
  }
}

/// A user prompt in CLI style: the text as typed, with quoted transcript text (a reply's quote
/// blocks) set off by a bar in the quote color.
struct CLIUserText: View {
  let text: String
  @Environment(\.cliPalette) private var palette

  var body: some View {
    let runs = UserPrompt.runs(text)
    if runs.count == 1, let only = runs.first, !only.isQuote {
      CLISourceText(text: only.text, tintsMarkdown: false, color: \.userText)
    } else {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
          if run.isQuote {
            CLISourceText(text: run.text, tintsMarkdown: false, color: \.quote)
              .padding(.leading, Theme.Spacing.small)
              .overlay(alignment: .leading) {
                Rectangle().fill(palette.quote.color.opacity(0.6)).frame(width: 2)
              }
              .accessibilityLabel("Quote: \(run.text)")
          } else {
            CLISourceText(text: run.text, tintsMarkdown: false, color: \.userText)
          }
        }
      }
    }
  }
}

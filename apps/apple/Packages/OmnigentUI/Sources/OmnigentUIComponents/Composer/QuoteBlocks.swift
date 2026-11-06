import SwiftUI

/// The draft's quotes, as the web's reply draft shows them: each a block with an accent bar and
/// a Remove quote button, after a field for the text typed before it (shown once there is such
/// text, or between quotes).
struct QuoteBlocks: View {
  let quotes: [ComposerQuote]
  let actions: ComposerQuoteActions
  var isEnabled = true

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      ForEach(Array(quotes.enumerated()), id: \.offset) { index, quote in
        if !quote.before.isEmpty || index > 0, let editLead = actions.editLead {
          TextField(
            "Text before quote \(index + 1)",
            text: Binding(get: { quote.before }, set: { editLead(index, $0) }), axis: .vertical
          )
          .textFieldStyle(.plain)
          .lineLimit(1...6)
          .disabled(!isEnabled)
          .accessibilityIdentifier("composer-quote-lead-\(index)")
        }
        block(quote, index: index)
      }
    }
  }

  private func block(_ quote: ComposerQuote, index: Int) -> some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      Text(quote.text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Theme.Spacing.small)
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.6)).frame(width: 2)
        }
        .help(quote.text)
      if let remove = actions.remove {
        Button("Remove quote", systemImage: "xmark") { remove(index) }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .disabled(!isEnabled)
          .help("Remove quote")
          .accessibilityIdentifier("composer-quote-remove-\(index)")
      }
    }
    .padding(.horizontal, Theme.Spacing.small)
    .padding(.vertical, Theme.Spacing.extraSmall)
    .background(ThemeColor.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Quote: \(quote.text)")
    .accessibilityIdentifier("composer-quote-\(index)")
  }
}

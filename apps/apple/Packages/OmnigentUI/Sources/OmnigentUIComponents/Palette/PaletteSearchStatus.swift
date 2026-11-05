import Foundation
import SwiftUI

/// What the palette's server search is asked: the query, how many matches, and which attempt
/// (Retry searches the same query again).
nonisolated struct PaletteSearchRequest: Hashable {
  let query: String
  let limit: Int
  let attempt: Int
}

/// The server search's state below the results, as the web's palette: "Searching…", the
/// failure with Retry, or Show more when the server has more matches.
struct PaletteSearchStatus: View {
  let isSearching: Bool
  let found: PaletteSearchResults
  let retry: () -> Void
  let showMore: () -> Void

  var body: some View {
    Group {
      if isSearching {
        HStack(spacing: Theme.Spacing.small) {
          ProgressView().controlSize(.small)
          Text("Searching\u{2026}")
        }
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("palette-searching")
      } else if let failure = found.failure {
        HStack(spacing: Theme.Spacing.small) {
          Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
          VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            Text("Couldn\u{2019}t load sessions.")
            Text(failure).font(.caption).lineLimit(2)
          }
          Spacer()
          Button("Retry", action: retry)
            .accessibilityIdentifier("palette-search-retry")
        }
        .foregroundStyle(.secondary)
      } else if found.hasMore {
        Button("Show more", action: showMore)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("palette-show-more")
      }
    }
    .font(.callout)
    .padding(.vertical, Theme.Spacing.small)
    .listRowBackground(Color.clear)
  }
}

extension PaletteSearch {
  /// `title` with the query's match in bold: the first case- and diacritic-insensitive
  /// occurrence, as the web's palette marks it.
  /// - Parameters:
  ///   - title: The result's title.
  ///   - query: The typed text.
  /// - Returns: The title, emphasized where it matches.
  nonisolated static func highlighted(_ title: String, query: String) -> AttributedString {
    var text = AttributedString(title)
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty,
      let range = title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]),
      let attributed = Range(range, in: text)
    else { return text }
    text[attributed].inlinePresentationIntent = .stronglyEmphasized
    return text
  }
}

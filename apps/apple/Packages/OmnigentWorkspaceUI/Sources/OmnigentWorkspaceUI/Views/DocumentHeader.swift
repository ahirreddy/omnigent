import SwiftUI

/// A document's header: its icon, name and path with the controls beside them, or below them when
/// both can't fit, so a narrow pane never squeezes the name down to a few letters.
struct DocumentHeader<Controls: View>: View {
  let symbol: String
  let name: String
  let path: String
  @ViewBuilder let controls: Controls

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        title
        Spacer(minLength: 8)
        controls
      }
      VStack(alignment: .leading, spacing: 6) {
        title
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          controls
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var title: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(name)
          .font(.headline)
          .lineLimit(1)
        Text(path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
          .textSelection(.enabled)
      }
    }
  }
}

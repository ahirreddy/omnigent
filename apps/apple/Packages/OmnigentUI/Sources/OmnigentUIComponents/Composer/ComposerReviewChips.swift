public import SwiftUI

/// A local review comment attached to the draft, as the web's `ComposerLocalReviewChips` shows
/// it.
nonisolated public struct ComposerReviewComment: Hashable, Sendable, Identifiable {
  /// The comment's id.
  public var id: String
  /// "src/a.rs:3–5 (new)".
  public var label: String
  /// "src/a.rs · New line 3–5".
  public var detail: String
  /// The comment.
  public var body: String

  /// Creates a chip.
  public init(id: String, label: String, detail: String, body: String) {
    self.id = id
    self.label = label
    self.detail = detail
    self.body = body
  }

  /// A chip for a comment on `lines` of one side of `path`.
  /// - Parameters:
  ///   - id: The comment.
  ///   - path: The file.
  ///   - old: On the old side.
  ///   - lines: The lines; one line reads as a single number.
  ///   - body: The comment.
  /// - Returns: The chip.
  public static func make(
    id: String, path: String, old: Bool, lines: ClosedRange<UInt64>, body: String
  ) -> Self {
    let line =
      lines.lowerBound == lines.upperBound
      ? "\(lines.upperBound)" : "\(lines.lowerBound)\u{2013}\(lines.upperBound)"
    return Self(
      id: id, label: "\(path):\(line) (\(old ? "old" : "new"))",
      detail: "\(path) \u{00B7} \(old ? "Old" : "New") line \(line)", body: body)
  }
}

/// The attached local review comments: each opens its comment in the pull request's Changes
/// tab, shows the comment on hover, and deletes it with its ×.
struct ComposerReviewChips: View {
  let comments: [ComposerReviewComment]
  let open: (@MainActor (String) -> Void)?
  let delete: (@MainActor (String) -> Void)?

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: Theme.Spacing.small) {
        ForEach(comments) { comment in
          HStack(spacing: Theme.Spacing.extraSmall) {
            Button {
              open?(comment.id)
            } label: {
              Label(comment.label, systemImage: "text.bubble")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .buttonStyle(.borderless)
            .help("\(comment.detail)\n\(comment.body)")
            .accessibilityLabel("Open local review comment \(comment.label)")
            if let delete {
              Button(
                "Delete local review comment \(comment.label)", systemImage: "xmark.circle.fill"
              ) {
                delete(comment.id)
              }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("Delete comment")
            }
          }
          .frame(maxWidth: 260)
          .padding(.horizontal, Theme.Spacing.small)
          .padding(.vertical, Theme.Spacing.extraSmall)
          .cardSurface(cornerRadius: Theme.Radius.medium)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("composer-review-comment-\(comment.id)")
        }
      }
      .padding(Theme.Spacing.tiny)
    }
    .scrollIndicators(.never)
  }
}

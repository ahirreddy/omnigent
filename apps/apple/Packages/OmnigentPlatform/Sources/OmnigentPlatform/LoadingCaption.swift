public import SwiftUI

/// A spinner over its caption, drawn and read out as `ProgressView(title)` is. The caption is a
/// text of its own: SwiftUI sometimes builds a labelled `ProgressView` with no label at all.
public struct LoadingCaption: View {
  private let title: String

  /// - Parameter title: What is loading, such as "Loading inbox…".
  public init(title: String) {
    self.title = title
  }

  /// The spinner, with the caption under it in a labelled spinner's spacing, font and color.
  public var body: some View {
    VStack {
      ProgressView()
      Text(title).foregroundStyle(.secondary)
    }
    .accessibilityRepresentation { ProgressView().accessibilityLabel(title) }
  }
}

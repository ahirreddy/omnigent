import SwiftUI

/// A spinner over its caption, read out as one element. The caption is a text of its own:
/// `ProgressView`'s label can fail to arrive when the view is first built, leaving the spinner bare.
struct LoadingCaption: View {
  let title: String

  var body: some View {
    VStack {
      ProgressView()
      Text(title).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
  }
}

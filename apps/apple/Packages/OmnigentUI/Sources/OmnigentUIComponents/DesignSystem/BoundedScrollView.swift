import SwiftUI

/// A vertical scroll view that is only as tall as its content, up to `maxHeight`.
struct BoundedScrollView<Content: View>: View {
  let maxHeight: CGFloat
  @ViewBuilder var content: Content
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      content
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          contentHeight = height
        }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: min(max(contentHeight, 1), maxHeight))
  }
}

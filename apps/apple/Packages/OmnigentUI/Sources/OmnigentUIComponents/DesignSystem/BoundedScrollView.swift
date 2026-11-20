import SwiftUI

/// A vertical scroll view that is only as tall as its content, up to `maxHeight`. On the Mac it
/// is an ``InnerScrollView``: at its top or bottom, a scroll that starts over it moves the list
/// around it.
struct BoundedScrollView<Content: View>: View {
  let maxHeight: CGFloat
  @ViewBuilder var content: Content
  #if !os(macOS)
    @State private var contentHeight: CGFloat = 0
  #endif

  var body: some View {
    #if os(macOS)
      InnerScrollHost(axis: .vertical, maxHeight: maxHeight, content: content)
    #else
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
    #endif
  }
}

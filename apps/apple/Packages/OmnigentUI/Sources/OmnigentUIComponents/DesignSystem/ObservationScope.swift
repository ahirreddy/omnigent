public import SwiftUI

/// Builds `content` in a view of its own, so a change to the observable state it reads renders
/// this content again and not the view that declares it. A window's root that reads the session
/// list for its sidebar otherwise rebuilds its toolbar and every open tab for each row.
public struct ObservationScope<Content: View>: View {
  private let name: String
  private let content: () -> Content

  /// Creates a scope.
  /// - Parameters:
  ///   - name: The scope's name in the Debug render counts.
  ///   - content: The content; it is called in this view's body.
  public init(_ name: String, @ViewBuilder content: @escaping () -> Content) {
    self.name = name
    self.content = content
  }

  /// The content.
  public var body: some View {
    content().countsRenders(name)
  }
}

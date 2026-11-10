import SwiftUI

extension View {
  /// Records this row's height for ``LoopProbe`` in Debug builds, so a loop names the row.
  @ViewBuilder func probesRowHeight(_ id: String) -> some View {
    #if DEBUG
      modifier(RowHeightProbe(id: id))
    #else
      self
    #endif
  }
}

#if DEBUG
  private struct RowHeightProbe: ViewModifier {
    let id: String
    @Environment(\.transcriptScrollState) private var scroll

    func body(content: Content) -> some View {
      content.onGeometryChange(for: CGSize.self) { [id] proxy in
        HangTrace.pass("row \(id)")
        return proxy.size
      } action: { old, new in
        scroll?.probe(
          "transcript row height",
          "\(id) \(old.width)x\(old.height) -> \(new.width)x\(new.height)")
      }
    }
  }
#endif

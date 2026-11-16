#if os(macOS)
  import SwiftUI

  @testable import OmnigentUIComponents

  extension WorkspaceSlots {
    /// Every tab's content is a line a test can read.
    static var filled: WorkspaceSlots {
      WorkspaceSlots(
        files: AnyView(Text("files slot")), changes: AnyView(Text("changes slot")),
        search: AnyView(Text("search slot")), agents: AnyView(Text("agents slot")))
    }
  }
#endif

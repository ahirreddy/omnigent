#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  private struct TextKinds: View {
    @State private var isOpen = false

    var body: some View {
      VStack {
        Text("Plain text")
        Text("Count \(3) done")
        Text(verbatim: "Verbatim {braces}")
        Text(AttributedString("Attributed"))
        Text("Selectable").textSelection(.enabled)
        Button("Reveal") { isOpen = true }
        if isOpen { Text("Revealed") }
      }
    }
  }

  private struct NestedHosts: View {
    var body: some View {
      NavigationSplitView {
        List { Text("In a row") }
      } detail: {
        Text("In the detail")
      }
    }
  }

  @Suite("Shown text", .serialized)
  @MainActor
  struct ShownTextTests {
    @Test("Reads every kind of text, resolved, and follows state")
    func reads() throws {
      let screen = OffscreenWindow(TextKinds(), width: 300, height: 300)
      defer { screen.close() }
      for text in [
        "Plain text", "Count 3 done", "Verbatim {braces}", "Attributed", "Selectable", "Reveal",
      ] {
        #expect(try screen.shows(text), "\(text)")
      }
      #expect(try !screen.shows("Revealed"))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("Revealed"))
    }

    @Test("Reads split panes and list rows, which host their own view trees")
    func readsNestedHosts() throws {
      let screen = OffscreenWindow(NestedHosts(), width: 800, height: 400)
      defer { screen.close() }
      #expect(try screen.shows("In a row"))
      #expect(try screen.shows("In the detail"))
    }
  }
#endif

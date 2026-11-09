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

  private struct RowsAndSheet: View {
    @State private var names = ["Kept row", "Removed row"]
    @State private var isOpen = false

    var body: some View {
      VStack {
        Button("Remove") { names.removeLast() }
        Button("Open") { isOpen = true }
        List(names, id: \.self) { Text($0) }
      }
      .sheet(isPresented: $isOpen) { Text("Sheet text").frame(width: 200, height: 100) }
    }
  }

  @Suite("Shown text", .serialized)
  @MainActor
  struct ShownTextTests {
    /// Without the setting, an empty list would read as a view showing nothing.
    @Test("A process that records no view tree fails the read")
    func noViewTree() throws {
      let screen = OffscreenWindow(Text("Plain text"), width: 200, height: 100)
      defer { screen.close() }
      let setting = "SWIFTUI_VIEW_DEBUG"
      let saved = try #require(ProcessInfo.processInfo.environment[setting])
      unsafe unsetenv(setting)
      defer { unsafe setenv(setting, saved, 1) }
      #expect(throws: OffscreenWindowError.notFound("SwiftUI's view tree")) {
        try screen.shownText()
      }
    }

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

    @Test("Reads list rows, so a row that goes away reads as gone")
    func listRows() throws {
      let screen = OffscreenWindow(RowsAndSheet(), width: 300, height: 300)
      defer { screen.close() }
      #expect(try screen.shows("Kept row"))
      #expect(try screen.shows("Removed row"))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("Kept row"))
      #expect(try !screen.shows("Removed row"))
    }

    @Test("Reads a sheet over the window")
    func sheet() throws {
      let screen = OffscreenWindow(RowsAndSheet(), width: 300, height: 300)
      defer { screen.close() }
      #expect(try !screen.shows("Sheet text"))
      try screen.clickControl(at: 1)
      #expect(try screen.shows("Sheet text"))
    }
  }
#endif

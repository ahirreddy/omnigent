#if os(macOS)
  import AppKit
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
        Text("Laid out")
          .overlayPreferenceValue(Text.LayoutKey.self) { _ in Color.clear }
          .textSelection(.enabled)
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

  @MainActor
  @Observable
  private final class ToolbarTitle {
    var text = "Old title"
  }

  private struct ToolbarAndContent: View {
    let title: ToolbarTitle

    var body: some View {
      Text("Content").toolbar { ToolbarItem(placement: .principal) { Text(title.text) } }
    }
  }

  /// An AppKit text view in a SwiftUI host, as a message's TextKit text is.
  private struct TextKitText: NSViewRepresentable {
    let text: String
    var isEditable = false

    func makeNSView(context: Context) -> NSTextView {
      let view = NSTextView(usingTextLayoutManager: true)
      view.isEditable = isEditable
      view.string = text
      return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {}
  }

  /// A view showing a drawing of laid-out text, as a message's text drawn ahead is.
  private final class DrawnTextView: NSView {
    var text: String?

    @objc var drawnText: String? { text }
  }

  private struct DrawnText: NSViewRepresentable {
    let text: String?

    func makeNSView(context: Context) -> DrawnTextView {
      let view = DrawnTextView()
      view.text = text
      return view
    }

    func updateNSView(_ view: DrawnTextView, context: Context) {}
  }

  @Suite("Shown text", .serialized)
  @MainActor
  struct ShownTextTests {
    @Test("Reads a drawing of laid-out text by paragraph and cell, and nothing it doesn't show")
    func drawnText() throws {
      let screen = OffscreenWindow(
        VStack {
          Text("SwiftUI text")
          DrawnText(text: "Drawn paragraph\n\t1.\tA step\nCell\t\u{FFFC}")
            .frame(width: 300, height: 80)
          DrawnText(text: nil).frame(width: 300, height: 40)
        }, width: 320, height: 180)
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(
        shown.sorted() == ["1.", "A step", "Cell", "Drawn paragraph", "SwiftUI text"], "\(shown)")
    }

    @Test("Reads a read-only TextKit view by paragraph and cell, and leaves editors out")
    func textKitViews() throws {
      let screen = OffscreenWindow(
        VStack {
          Text("SwiftUI text")
          TextKitText(text: "First paragraph\n\t•\tAn item\nCell one\tCell two \u{FFFC}\n \nEnd")
            .frame(width: 300, height: 120)
          TextKitText(text: "Typed draft", isEditable: true).frame(width: 300, height: 40)
        }, width: 320, height: 260)
      defer { screen.close() }
      let shown = try screen.shownText()
      for piece in [
        "SwiftUI text", "First paragraph", "•", "An item", "Cell one", "Cell two", "End",
      ] {
        #expect(shown.filter { $0 == piece }.count == 1, "\(piece) in \(shown)")
      }
      #expect(shown.count == 7, "no blank or attachment pieces: \(shown)")
      #expect(try !screen.shows("Typed draft"), "an editor's text is typed, not shown")
    }

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
        "Plain text", "Count 3 done", "Verbatim {braces}", "Attributed", "Selectable", "Laid out",
        "Reveal",
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

    @Test("Reads one list row apart from the others")
    func oneRow() throws {
      let screen = OffscreenWindow(RowsAndSheet(), width: 300, height: 300)
      defer { screen.close() }
      let list = try #require(screen.allViews.lazy.compactMap { $0 as? NSTableView }.first)
      let rows = try (0..<list.numberOfRows).map { row in
        try screen.shownText(under: #require(list.rowView(atRow: row, makeIfNecessary: false)))
      }
      #expect(rows == [["Kept row"], ["Removed row"]])
    }

    @Test("Reads a sheet over the window")
    func sheet() throws {
      let screen = OffscreenWindow(RowsAndSheet(), width: 300, height: 300)
      defer { screen.close() }
      #expect(try !screen.shows("Sheet text"))
      try screen.clickControl(at: 1)
      #expect(try screen.shows("Sheet text"))
    }

    @Test("Reads the toolbar apart from the content, and follows its state")
    func toolbar() throws {
      let title = ToolbarTitle()
      let screen = OffscreenWindow(ToolbarAndContent(title: title), width: 400, height: 200)
      defer { screen.close() }
      #expect(try screen.toolbarText().isEmpty, "a window with no titlebar has no toolbar")
      screen.window.contentView = nil
      screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
      screen.host.sceneBridgingOptions = [.toolbars, .title]
      screen.window.contentView = screen.host
      screen.settle(0.5)
      #expect(try screen.toolbarText() == ["Old title"])
      #expect(try !screen.shows("Old title"))
      title.text = "New title"
      screen.settle(0.2)
      #expect(try screen.toolbarText() == ["New title"])
      #expect(try screen.shownText() == ["Content"])
    }
  }
#endif

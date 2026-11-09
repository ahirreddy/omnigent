#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentViewTesting

  private final class MouseDownRecorder: NSView {
    var stack: [String] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      stack = Thread.callStackSymbols
    }
  }

  private struct RecorderView: NSViewRepresentable {
    let recorder: MouseDownRecorder

    func makeNSView(context: Context) -> MouseDownRecorder { recorder }
    func updateNSView(_ view: MouseDownRecorder, context: Context) {}
  }

  @MainActor
  private final class Log {
    var picked: Set<String> = []
    var hovered: [Bool] = []
    var deleted: [String] = []
  }

  private struct Rows: View {
    let log: Log
    @State private var selection: Set<String> = []

    var body: some View {
      List(["First", "Second"], id: \.self, selection: $selection) { name in
        Text(name)
          .draggable(name)
          .contextMenu {
            Button("Delete") { log.deleted.append(name) }
          }
      }
      .onChange(of: selection) { _, new in log.picked = new }
    }
  }

  @MainActor
  @Suite("Offscreen events", .serialized)
  struct OffscreenEventTests {
    @Test("an event runs in its own run loop, so stopping that loop can't stop the test runner's")
    func eventIsNested() throws {
      let recorder = MouseDownRecorder()
      let screen = OffscreenWindow(RecorderView(recorder: recorder), width: 200, height: 200)
      defer { screen.close() }
      try screen.click(CGPoint(x: 100, y: 100))
      // A test's stack ends at its task's async frames, so any run loop on it is a nested one.
      #expect(recorder.stack.contains { $0.contains("__CFRunLoopRun") })
    }

    @Test("clicking a list row with a drag source selects it")
    func draggableRow() throws {
      let log = Log()
      let screen = OffscreenWindow(Rows(log: log), width: 300, height: 200)
      defer { screen.close() }
      let table = try #require(screen.allViews.compactMap { $0 as? NSTableView }.first)
      let row = table.convert(table.rect(ofRow: 1), to: screen.host)
      // On the row's text, where the drag source is.
      try screen.click(CGPoint(x: row.minX + 24, y: row.midY))
      #expect(log.picked == ["Second"])
    }

    @Test("a list row's context menu comes from the table around it")
    func rowContextMenu() throws {
      let log = Log()
      let screen = OffscreenWindow(Rows(log: log), width: 300, height: 200)
      defer { screen.close() }
      let table = try #require(screen.allViews.compactMap { $0 as? NSTableView }.first)
      let row = table.convert(table.rect(ofRow: 0), to: screen.host)
      let menu = try #require(try screen.contextMenu(at: CGPoint(x: row.midX, y: row.midY)))
      try screen.choose("Delete", in: menu)
      #expect(log.deleted == ["First"])
    }

    @Test("hovering a view reports entering it, and ending the hover reports leaving")
    func hover() throws {
      let log = Log()
      let screen = OffscreenWindow(
        Color.gray.frame(width: 200, height: 200).onHover { log.hovered.append($0) },
        width: 200, height: 200)
      defer { screen.close() }
      try screen.hover(CGPoint(x: 100, y: 100))
      #expect(log.hovered == [true])
      try screen.endHover()
      #expect(log.hovered == [true, false])
    }
  }
#endif

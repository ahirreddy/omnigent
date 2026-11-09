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

  /// Reports the menu item it was asked to run.
  @MainActor
  private final class MenuItemTarget: NSObject {
    private let report: (String) -> Void

    init(report: @escaping (String) -> Void) {
      self.report = report
    }

    @objc func choose(_ item: NSMenuItem) {
      report(item.title)
    }
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

  private struct ChangingControls: View {
    @State private var name = ""
    @State private var showsExtra = true

    var body: some View {
      VStack(spacing: 8) {
        TextField("Name", text: $name)
        Button("Save") {}.disabled(name.isEmpty)
        Button("Hide") { showsExtra = false }
        if showsExtra { Button("Extra") {} }
      }
      .frame(width: 200, height: 200)
    }
  }

  private struct BorderedInContainers: View {
    let log: Log

    var body: some View {
      VStack {
        List(["Row"], id: \.self) { _ in
          Button("In row") { log.deleted.append("row") }.buttonStyle(.bordered)
        }
        ScrollView {
          LazyVStack {
            Button("In lazy") { log.deleted.append("lazy") }
              .buttonStyle(.bordered).controlSize(.small)
          }
        }
      }
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

    @Test("the control list follows controls enabling and going away")
    func controlsChange() throws {
      let screen = OffscreenWindow(ChangingControls(), width: 300, height: 300)
      defer { screen.close() }
      let before = screen.controlFrames.count
      try screen.clickControl(at: 0)
      try screen.type("a")
      let enabled = screen.controlFrames.count
      #expect(enabled == before + 1, "\(before) then \(enabled)")
      try screen.clickControl(at: 2)
      #expect(screen.controlFrames.count == enabled - 1)
    }

    @Test("bordered buttons in a list row and a lazy stack are listed and clickable")
    func borderedInContainers() throws {
      let log = Log()
      let screen = OffscreenWindow(BorderedInContainers(log: log), width: 300, height: 300)
      defer { screen.close() }
      for index in screen.controlFrames.indices { try screen.clickControl(at: index) }
      #expect(Set(log.deleted) == ["row", "lazy"], "\(log.deleted)")
    }

    @Test("a borderless button-style menu is listed and opens")
    func borderlessMenu() throws {
      let screen = OffscreenWindow(
        Menu("More") { Button("Item") {} }.menuStyle(.button).buttonStyle(.borderless),
        width: 200, height: 100)
      defer { screen.close() }
      let frame = try #require(screen.controlFrames.first)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      #expect(menu.items.map(\.title).contains("Item"))
    }

    @Test("a plain click whose menu stays open closes it and fails, rather than hanging the run")
    func plainClickOnAMenuFails() throws {
      let screen = OffscreenWindow(
        StuckMenuView().frame(width: 200, height: 100), width: 200, height: 100)
      defer { screen.close() }
      let started = Date()
      #expect(throws: OffscreenWindowError.unexpectedMenu("Stuck")) {
        try screen.click(CGPoint(x: 100, y: 50))
      }
      #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test("a click reaches a destructive button of any style")
    func destructiveButtons() throws {
      let log = Log()
      let screen = OffscreenWindow(
        VStack(spacing: 8) {
          Button("Bordered", role: .destructive) { log.deleted.append("bordered") }
            .buttonStyle(.bordered)
          Button("Borderless", role: .destructive) { log.deleted.append("borderless") }
            .buttonStyle(.borderless)
          Button("Default", role: .destructive) { log.deleted.append("default") }
        },
        width: 200, height: 150)
      defer { screen.close() }
      for index in screen.controlFrames.indices { try screen.clickControl(at: index) }
      #expect(log.deleted == ["bordered", "borderless", "default"])
    }

    @Test("a stop queued as a synchronous test returns doesn't end the run")
    func stopAsSyncTestReturns() {
      let screen = OffscreenWindow(Text("Still"), width: 100, height: 100)
      // After close, whose run loop would otherwise take the stop.
      screen.close()
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        CFRunLoopStop(CFRunLoopGetMain())
      }
    }

    @Test("a click after a menu reaches a borderless button")
    func clickAfterMenu() throws {
      let log = Log()
      let screen = OffscreenWindow(
        VStack {
          Menu("More") { Button("Item") {} }
          Button("Remove") { log.deleted.append("remove") }.buttonStyle(.borderless)
        },
        width: 200, height: 120)
      defer { screen.close() }
      let frames = screen.controlFrames
      _ = try screen.openMenu(CGPoint(x: frames[0].midX, y: frames[0].midY))
      try screen.clickControl(at: 1)
      #expect(log.deleted == ["remove"])
    }

    @Test("clicking a view found in the window clicks its middle")
    func clickingAView() throws {
      let log = Log()
      let screen = OffscreenWindow(
        Button("Whole window") { log.deleted.append("clicked") }.buttonStyle(.borderless),
        width: 200, height: 100)
      defer { screen.close() }
      try screen.click(screen.host)
      #expect(log.deleted == ["clicked"])
    }

    @Test("a menu item is found at any depth, and a missing one is an error")
    func choosingMenuItems() throws {
      let screen = OffscreenWindow(Text("Menus"), width: 100, height: 100)
      defer { screen.close() }
      var chosen: [String] = []
      let target = MenuItemTarget { chosen.append($0) }
      let inner = NSMenu(title: "Inner")
      let item = inner.addItem(
        withTitle: "Deep", action: #selector(MenuItemTarget.choose(_:)), keyEquivalent: "")
      item.target = target
      let outer = NSMenu(title: "Outer")
      outer.addItem(withTitle: "Other", action: nil, keyEquivalent: "")
      outer.addItem(withTitle: "Folder", action: nil, keyEquivalent: "").submenu = inner

      try screen.choose("Deep", in: outer)
      #expect(chosen == ["Deep"])
      #expect(throws: OffscreenWindowError.notFound("Nowhere")) {
        try screen.choose("Nowhere", in: outer)
      }
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

#if os(macOS)
  /// Opens a context menu on a left click, which tracks until something closes it.
  private struct StuckMenuView: NSViewRepresentable {
    final class MenuView: NSView {
      override func mouseDown(with event: NSEvent) {
        let menu = NSMenu(title: "Stuck")
        menu.addItem(withTitle: "Item", action: nil, keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
      }
    }

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) {}
  }
#endif

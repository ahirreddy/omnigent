#if os(macOS)
  import AppKit
  import CoreGraphics
  import SwiftUI
  import Testing

  @testable import OmnigentViewTesting

  /// A view that presents each kind of modal from a default-style button.
  private struct Presenter: View {
    @State private var showsSheet = false
    @State private var showsDialog = false
    @State private var showsAlert = false
    let log: (String) -> Void

    var body: some View {
      VStack(spacing: 0) {
        Button("Sheet") { showsSheet = true }.frame(height: 40)
        Button("Dialog") { showsDialog = true }.frame(height: 40)
        Button("Alert") { showsAlert = true }.frame(height: 40)
        Menu("Menu") { Button("Item") { log("item") } }.frame(height: 40)
      }
      .sheet(isPresented: $showsSheet) {
        Button("Close") {
          log("close")
          showsSheet = false
        }
        .frame(width: 200, height: 100)
      }
      .confirmationDialog("Sure?", isPresented: $showsDialog) {
        Button("Do it") { log("dialog") }
      }
      .alert("Careful", isPresented: $showsAlert) {
        Button("OK") { log("alert") }
      }
    }
  }

  /// Windows of this process that a person could see right now.
  @MainActor
  private func visibleWindows() -> [String] {
    let options: CGWindowListOption = [.optionOnScreenOnly]
    let all = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let ours = all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    let shown = ours.filter { ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0 }
    return shown.map { "\($0[kCGWindowBounds as String] ?? "unknown bounds")" }
  }

  @MainActor
  @Suite("Product code can't reach the person using this Mac", .serialized)
  struct SystemSideEffectsTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
    }

    @Test("the clipboard stays private to the test")
    func clipboard() {
      let real = NSPasteboard(name: .general)
      let before = real.changeCount
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString("copied", forType: .string)
      #expect(real.changeCount == before)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "copied")
      #expect(NSPasteboard.general.name != real.name)
    }

    @Test("opening and revealing are recorded")
    func workspace() throws {
      let link = try #require(URL(string: "https://example.com/a"))
      let file = URL(filePath: "/tmp/a.txt")
      #expect(NSWorkspace.shared.open(link))
      NSWorkspace.shared.open(link, configuration: .init()) { _, error in
        #expect(error == nil)
      }
      NSWorkspace.shared.activateFileViewerSelecting([file])
      #expect(SystemSideEffects.record.openedURLs == [link, link])
      #expect(SystemSideEffects.record.revealedURLs == [file])
    }

    @Test("opening files with an app records both, and a sheet or background panel answers")
    func openingWithAndPanelSheets() throws {
      let file = URL(filePath: "/tmp/a.txt")
      let app = URL(filePath: "/Applications/Editor.app")
      var opened = false
      NSWorkspace.shared.open([file], withApplicationAt: app, configuration: .init()) { _, error in
        #expect(error == nil)
        opened = true
      }
      #expect(opened)
      #expect(SystemSideEffects.record.openedURLs == [file, app])

      SystemSideEffects.answer(panel: .OK)
      var answers: [NSApplication.ModalResponse] = []
      let window = NSWindow(
        contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      NSSavePanel().beginSheetModal(for: window) { answers.append($0) }
      NSOpenPanel().begin { answers.append($0) }
      #expect(answers == [.OK, .OK])
      #expect(SystemSideEffects.record.panelCount == 2)
      #expect(window.attachedSheet == nil)
    }

    /// The call itself is deprecated, and product code on an older path still makes it.
    @Test("the older way of bringing the app forward is recorded too")
    func activatingIgnoringOtherApps() {
      _ = unsafe NSApplication.shared.perform(
        NSSelectorFromString("activateIgnoringOtherApps:"), with: nil)
      #expect(SystemSideEffects.record.activationCount == 1)
    }

    @Test("panels and alerts answer without showing")
    func modals() {
      let alert = NSAlert()
      alert.messageText = "Delete?"
      #expect(alert.runModal() == .alertFirstButtonReturn)
      SystemSideEffects.answer(alert: .alertSecondButtonReturn, panel: .OK)
      #expect(alert.runModal() == .alertSecondButtonReturn)
      #expect(NSOpenPanel().runModal() == .OK)
      #expect(NSSavePanel().runModal() == .OK)
      #expect(SystemSideEffects.record.alertMessages == ["Delete?", "Delete?"])
      #expect(SystemSideEffects.record.panelCount == 2)
      SystemSideEffects.reset()
      #expect(NSOpenPanel().runModal() == .cancel)
    }

    @Test("a panel can hold a chosen file, and opening can fail")
    func chosenFileAndFailedOpen() async throws {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      defer { SystemSideEffects.reset() }
      let chosen = URL(fileURLWithPath: "/nonexistent/chosen.html")
      SystemSideEffects.answer(panel: .OK, panelURL: chosen, opensFail: true)
      let openPanel = NSOpenPanel()
      #expect(openPanel.runModal() == .OK)
      #expect(openPanel.url == chosen)
      #expect(openPanel.urls == [chosen])
      #expect(NSSavePanel().url == chosen)
      await #expect(throws: (any Error).self) {
        _ = try await NSWorkspace.shared.open(chosen, configuration: .init())
      }
      SystemSideEffects.reset()
      #expect(NSOpenPanel().url == nil)
      #expect(NSOpenPanel().urls.isEmpty)
    }

    @Test("sheets, dialogs, alerts and menus never become visible", .timeLimit(.minutes(1)))
    func invisibleModals() throws {
      var log: [String] = []
      let screen = OffscreenWindow(Presenter { log.append($0) }, width: 200, height: 200)
      defer { screen.close() }
      #expect(visibleWindows().isEmpty)
      #expect(screen.window.alphaValue == 0)

      try screen.clickControl(at: 0)
      screen.settle(0.5)
      #expect(screen.window.attachedSheet != nil)
      #expect(visibleWindows().isEmpty)
      #expect(screen.controlFrames.count == 1)
      try screen.clickControl(at: 0)
      screen.settle(0.5)
      #expect(log == ["close"])
      #expect(screen.window.attachedSheet == nil)

      log = []
      try screen.clickControl(at: 1)
      screen.settle(0.5)
      #expect(visibleWindows().isEmpty)
      #expect(log == ["dialog"])
      #expect(SystemSideEffects.record.alertMessages == ["Sure?"])

      log = []
      try screen.clickControl(at: 2)
      screen.settle(0.5)
      #expect(visibleWindows().isEmpty)
      #expect(log == ["alert"])

      var seenDuringMenu: [String] = []
      let sample = Timer(timeInterval: 0.01, repeats: true) { _ in
        MainActor.assumeIsolated { seenDuringMenu += visibleWindows() }
      }
      RunLoop.main.add(sample, forMode: .common)
      defer { sample.invalidate() }
      let menu = try screen.openMenu(CGPoint(x: 100, y: 160))
      #expect(menu.items.map(\.title).contains("Item"))
      #expect(seenDuringMenu.isEmpty, "\(seenDuringMenu)")
    }

    @Test("an exit from the runner's own loop counts as ending the run early")
    func falsePassDetection() {
      let early = ["exit", "swift_task_asyncMainDrainQueue", "main"]
      let normal = ["exit", "__SwiftPMGeneratedTestRunner", "swift_task_asyncMainDrainQueue"]
      #expect(SystemSideEffects.endsRunEarly(callStack: early))
      #expect(!SystemSideEffects.endsRunEarly(callStack: normal))
      #expect(!SystemSideEffects.endsRunEarly(callStack: ["exit", "main"]))
    }

    @Test("an exit that's on time goes on as usual")
    func onTimeExit() {
      SystemSideEffects.endRunIfEarly(callStack: ["exit", "main"])
    }

    @Test("the methods it replaces are there to find")
    func foundMethods() {
      #expect(
        unsafe method_getName(SystemSideEffects.method(NSAlert.self, "runModal")) == #selector(
          NSAlert.runModal))
    }

    @Test("focus, new windows, menus and quitting are recorded")
    func application() {
      let app = NSApplication.shared
      app.activate()
      app.terminate(nil)
      let window = NSWindow(
        contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.title = "Logs"
      window.makeKeyAndOrderFront(nil)
      #expect(!window.isVisible)
      let shown = NSMenu().popUp(positioning: nil, at: .zero, in: nil)
      #expect(!shown)
      let record = SystemSideEffects.record
      #expect(record.activationCount == 1)
      #expect(record.terminationCount == 1)
      #expect(record.shownWindowTitles == ["Logs"])
      #expect(record.poppedUpMenuCount == 1)
    }
  }
#endif

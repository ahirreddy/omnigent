#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentViewTesting

  /// A lazy stack whose one row changes identity.
  private struct SwappedRows: View {
    @State private var row = "first"

    var body: some View {
      VStack {
        Button("Swap") { row = "second" }
        ScrollView {
          LazyVStack {
            ForEach([row], id: \.self) { name in
              Button(name) {}.buttonStyle(.borderless)
            }
          }
        }
      }
    }
  }

  @MainActor
  private final class Taps {
    var log: [String] = []
  }

  private struct Controls: View {
    let taps: Taps
    @State private var isOn = false
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
      VStack(spacing: 0) {
        Button("Default") { taps.log.append("default") }
          .frame(width: 200, height: 40)
        Button {
          taps.log.append("plain")
        } label: {
          Color.gray.frame(width: 200, height: 40)
        }
        .buttonStyle(.plain)
        Color.gray.frame(width: 200, height: 40)
        Toggle("Switch", isOn: $isOn)
          .onChange(of: isOn) { taps.log.append("toggle \(isOn)") }
          .frame(width: 200, height: 40)
        TextField("Field", text: $text)
          .focused($isFocused)
          .onChange(of: text) { taps.log.append("text \(text)") }
          .frame(width: 200, height: 40)
        Color.gray.frame(width: 200, height: 40)
          .contextMenu { Button("Rename") { taps.log.append("rename") } }
        Menu("Actions") { Button("Archive") { taps.log.append("archive") } }
          .frame(width: 200, height: 40)
      }
      .frame(width: 200, height: 280, alignment: .top)
    }
  }

  /// One control of each style, with those in the scroll view above those outside it.
  private struct EveryStyle: View {
    let taps: Taps
    @State private var isOn = false
    @State private var isPressed = false
    @State private var text = ""

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        ScrollView {
          Button("Scrolled") { taps.log.append("scrolled") }.buttonStyle(.plain)
        }
        .frame(height: 30)
        HStack(spacing: 8) {
          Button("Left") { taps.log.append("left") }.buttonStyle(.plain)
          Button("Middle") { taps.log.append("middle") }.buttonStyle(.borderless)
          Button("Right") { taps.log.append("right") }
        }
        Toggle("Check", isOn: $isOn).onChange(of: isOn) { taps.log.append("check") }
        Toggle("Press", isOn: $isPressed)
          .toggleStyle(.button)
          .onChange(of: isPressed) { taps.log.append("press") }
        Menu("Menu") { Button("Item") { taps.log.append("item") } }
        TextField("Field", text: $text)
      }
      .padding(8)
      .frame(width: 300, height: 260, alignment: .top)
    }
  }

  @MainActor
  @Suite("A view in an offscreen window takes real input", .serialized)
  struct OffscreenWindowTests {
    @Test("the runner's loop keeps going after a stop while a test is suspended")
    func stopWhileSuspended() async throws {
      let screen = OffscreenWindow(Text("Still"), width: 100, height: 100)
      defer { screen.close() }
      // Long enough for the shield's retry to find the runner's loop.
      try await Task.sleep(for: .milliseconds(60))
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        CFRunLoopStop(CFRunLoopGetMain())
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
      try await Task.sleep(for: .milliseconds(20))
      #expect(screen.window.isVisible, "the process is still here to check")
    }

    @Test("only the runner's loop itself is taken over, never one inside a test")
    func shieldChoosesItsLoop() {
      let drain = "libswift_Concurrency swift_task_asyncMainDrainQueue + 40"
      let job = "CoreFoundation __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__ + 16"
      #expect(RunnerLoopShield.isDirectlyOnRunnerLoop(callStack: ["timer", drain]))
      #expect(!RunnerLoopShield.isDirectlyOnRunnerLoop(callStack: ["timer", job, drain]))
      #expect(!RunnerLoopShield.isDirectlyOnRunnerLoop(callStack: ["timer", "completeTask"]))
    }

    @Test("a window doesn't animate: the animation's end would stop the test runner's run loop")
    func windowsDontAnimate() {
      let screen = OffscreenWindow(Text("Still"), width: 100, height: 100)
      defer { screen.close() }
      #expect(screen.window.animationBehavior == .none)
    }

    @Test("a window given a title bar, for its toolbar, stays off every display")
    func titledStaysOffscreen() {
      let screen = OffscreenWindow(Text("Still"), width: 300, height: 200)
      defer { screen.close() }
      let frame = screen.window.frame
      screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
      screen.settle()
      #expect(screen.window.frame == frame)
    }

    @Test("opening a menu where there is none is an error")
    func noMenu() {
      let screen = OffscreenWindow(Text("Still"), width: 100, height: 100)
      defer { screen.close() }
      #expect(throws: OffscreenWindowError.notFound("a menu")) {
        try screen.openMenu(CGPoint(x: 50, y: 50))
      }
    }

    @Test("a click reaches each kind of control")
    func clicks() throws {
      let taps = Taps()
      let screen = OffscreenWindow(Controls(taps: taps), width: 200, height: 280)
      defer { screen.close() }
      #expect(!screen.window.occlusionState.contains(.visible) || screen.window.frame.minX < 0)
      try screen.click(CGPoint(x: 100, y: 20))
      try screen.click(CGPoint(x: 100, y: 60))
      try screen.click(CGPoint(x: 100, y: 100))
      try screen.click(CGPoint(x: 100, y: 140))
      #expect(taps.log == ["default", "plain", "toggle true"])
    }

    @Test("typing reaches the focused field and controls are found in order")
    func typing() throws {
      let taps = Taps()
      let screen = OffscreenWindow(Controls(taps: taps), width: 200, height: 280)
      defer { screen.close() }
      try screen.click(CGPoint(x: 100, y: 180))
      try screen.type("hi")
      #expect(taps.log == ["text h", "text hi"])
      try screen.clickControl(at: 0)
      #expect(taps.log.last == "default")
      #expect(throws: OffscreenWindowError.self) { try screen.clickControl(at: 99) }
    }

    @Test("controls of every style are listed once, in reading order")
    func controlOrder() throws {
      let taps = Taps()
      let screen = OffscreenWindow(EveryStyle(taps: taps), width: 300, height: 260)
      defer { screen.close() }
      let frames = screen.controlFrames
      #expect(frames.count == 8, "\(frames)")
      for index in [0, 1, 2, 3, 4, 5] { try screen.clickControl(at: index) }
      #expect(taps.log == ["scrolled", "left", "middle", "right", "check", "press"])
      let menu = try screen.openMenu(CGPoint(x: frames[6].midX, y: frames[6].midY))
      #expect(menu.items.map(\.title).contains("Item"))
      try screen.click(CGPoint(x: frames[7].midX, y: frames[7].midY))
      try screen.type("a")
      #expect(screen.window.firstResponder is NSText)
    }

    @Test("the controls of a row a lazy stack dropped aren't listed")
    func droppedRowControls() throws {
      let screen = OffscreenWindow(SwappedRows(), width: 300, height: 200)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 2, "the swap button and the row's")
      try screen.clickControl(at: 0)
      #expect(screen.controlFrames.count == 2, "\(screen.controlFrames)")
    }

    @Test("a context menu can be read and chosen from without opening it")
    func contextMenu() throws {
      let taps = Taps()
      let screen = OffscreenWindow(Controls(taps: taps), width: 200, height: 280)
      defer { screen.close() }
      let menu = try #require(try screen.contextMenu(at: CGPoint(x: 100, y: 220)))
      #expect(menu.items.map(\.title) == ["Rename"])
      try screen.choose("Rename", in: menu)
      #expect(taps.log == ["rename"])
    }

    @Test("a menu opens, closes at once and can be chosen from", .timeLimit(.minutes(1)))
    func menu() throws {
      let taps = Taps()
      let screen = OffscreenWindow(Controls(taps: taps), width: 200, height: 280)
      defer { screen.close() }
      let menu = try screen.openMenu(CGPoint(x: 100, y: 260))
      #expect(menu.items.map(\.title).contains("Archive"))
      try screen.choose("Archive", in: menu)
      #expect(taps.log == ["archive"])
    }
  }
#endif

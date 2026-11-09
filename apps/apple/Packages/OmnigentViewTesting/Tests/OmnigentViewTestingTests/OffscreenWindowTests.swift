#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentViewTesting

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

  @MainActor
  @Suite("A view in an offscreen window takes real input", .serialized)
  struct OffscreenWindowTests {
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

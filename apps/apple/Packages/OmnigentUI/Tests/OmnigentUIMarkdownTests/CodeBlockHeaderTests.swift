#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  @Suite("Code block headers", .serialized)
  struct CodeBlockHeaderTests {
    private func header(language: String?, width: CGFloat) -> OffscreenWindow<CodeBlockView> {
      OffscreenWindow(
        CodeBlockView(code: "let answer = 42", language: language), width: width, height: 200)
    }

    @Test("the header names the language and the copy control on one line")
    func wideHeader() throws {
      let screen = header(language: "swift", width: 480)
      defer { screen.close() }
      screen.settle()
      #expect(try screen.shows("Swift"))
      #expect(try screen.shows("Copy code"))
      let controls = screen.controlFrames
      try #require(controls.count == 3)
      let centers = Set(controls.map { Int($0.midY.rounded()) })
      #expect(centers.count == 1, "\(controls)")
    }

    @Test("a fence with no language still says Code")
    func noLanguage() throws {
      let screen = header(language: nil, width: 480)
      defer { screen.close() }
      screen.settle()
      #expect(try screen.shows("Code"))
    }

    @Test("too narrow for its title, the copy control stays a single-line icon")
    func narrowHeader() throws {
      let screen = header(language: "swift", width: 150)
      defer { screen.close() }
      screen.settle()
      let controls = screen.controlFrames
      try #require(controls.count == 3)
      #expect(try screen.shows("Swift"))
      #expect(controls[2].width <= Theme.Control.target + 1, "\(controls)")
      let centers = Set(controls.map { Int($0.midY.rounded()) })
      #expect(centers.count == 1, "\(controls)")
      let tallest = try #require(controls.map(\.height).max())
      #expect(tallest <= Theme.Control.target + 1, "\(controls)")
    }

    @Test("copying from a narrow header still copies the code")
    func narrowCopy() throws {
      let screen = header(language: nil, width: 150)
      defer { screen.close() }
      screen.settle()
      try screen.clickControl(at: 2)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "let answer = 42")
    }
  }
#endif

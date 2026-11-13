#if os(iOS)
  import SwiftUI
  import Testing
  import UIKit

  @testable import OmnigentViewTesting

  @MainActor
  @Observable
  private final class Tally {
    var presses = 0
    var isOn = false
  }

  private struct Controls: View {
    let tally: Tally
    var canPress = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
      VStack {
        Text(sizeClass == .compact ? "Phone layout" : "Tablet layout")
        Text("Pressed \(tally.presses)")
        Button("Press") { tally.presses += 1 }
          .disabled(!canPress)
          .accessibilityIdentifier("controls.press")
        Toggle(
          "Loud",
          isOn: Binding {
            tally.isOn
          } set: {
            tally.isOn = $0
          })
        ProgressView(value: 0.25).accessibilityIdentifier("controls.progress")
      }
    }
  }

  private final class KeyTaker: UIView, UIKeyInput {
    var typed = ""
    var hasText: Bool { !typed.isEmpty }
    override var canBecomeFirstResponder: Bool { true }
    func insertText(_ text: String) { typed += text }
    func deleteBackward() { typed.removeLast() }
  }

  @MainActor
  @Suite("A window in the test process", .serialized)
  struct InProcessWindowTests {
    @Test("activating a button by identifier or label runs its action and redraws")
    func activation() async throws {
      let tally = Tally()
      let screen = try InProcessWindow(Controls(tally: tally))
      defer { screen.close() }
      await screen.settle()
      #expect(screen.identifiers.contains("controls.press"))
      #expect(screen.labels.contains("Pressed 0"))
      try await screen.activate("controls.press")
      try await screen.activate("Press")
      #expect(tally.presses == 2)
      #expect(screen.shows("Pressed 2"))
      #expect(!screen.shows("Pressed 0"))
    }

    @Test("a toggle flips its binding and reports its value")
    func toggle() async throws {
      let tally = Tally()
      let screen = try InProcessWindow(Controls(tally: tally))
      defer { screen.close() }
      await screen.settle()
      #expect(try screen.value(of: "Loud") == "0")
      try await screen.activate("Loud")
      #expect(tally.isOn)
      #expect(try screen.value(of: "Loud") == "1")
      #expect(try screen.value(of: "controls.progress") == "25%")
    }

    @Test("a disabled control is on screen, reads as disabled and takes no press")
    func disabled() async throws {
      let tally = Tally()
      let screen = try InProcessWindow(Controls(tally: tally, canPress: false))
      defer { screen.close() }
      await screen.settle()
      #expect(try !screen.isEnabled("controls.press"))
      await #expect(throws: InProcessWindowError.notActivated("controls.press")) {
        try await screen.activate("controls.press")
      }
      #expect(tally.presses == 0)
    }

    @Test("a name nothing has is an error, never a silent pass")
    func missing() async throws {
      let screen = try InProcessWindow(Controls(tally: Tally()))
      defer { screen.close() }
      await screen.settle()
      #expect(!screen.shows("controls.absent"))
      #expect(throws: InProcessWindowError.notFound("controls.absent")) {
        try screen.element("controls.absent")
      }
      #expect(throws: InProcessWindowError.notFound("controls.absent")) {
        try screen.isEnabled("controls.absent")
      }
      await #expect(throws: InProcessWindowError.notFound("controls.absent")) {
        try await screen.activate("controls.absent")
      }
    }

    @Test("the size class chooses the layout: compact unless the test asks for regular")
    func sizeClass() async throws {
      let phone = try InProcessWindow(Controls(tally: Tally()))
      await phone.settle()
      #expect(phone.shows("Phone layout"))
      #expect(phone.window.bounds.size == CGSize(width: 393, height: 852))
      phone.close()
      let tablet = try InProcessWindow(
        Controls(tally: Tally()), width: 1024, height: 768, horizontalSizeClass: .regular)
      defer { tablet.close() }
      await tablet.settle()
      #expect(tablet.shows("Tablet layout"))
      #expect(tablet.window.traitCollection.userInterfaceStyle == .dark)
    }

    @Test("a UIKit view fills the window, takes the keyboard, and is found by type")
    func hostedView() throws {
      let taker = KeyTaker()
      let screen = try InProcessWindow(view: taker, width: 300, height: 200)
      defer { screen.close() }
      #expect(taker.frame == CGRect(x: 0, y: 0, width: 300, height: 200))
      #expect(screen.window.isKeyWindow)
      #expect(taker.becomeFirstResponder())
      taker.insertText("hi")
      #expect(taker.isFirstResponder)
      #expect(screen.views(KeyTaker.self).map(\.typed) == ["hi"])
    }

    @Test("a closed window shows nothing")
    func closed() async throws {
      let screen = try InProcessWindow(Controls(tally: Tally()))
      await screen.settle()
      screen.close()
      #expect(screen.window.isHidden)
      #expect(!screen.shows("controls.press"))
    }

    @Test("settling waits about as long as asked")
    func settleWaits() async throws {
      let screen = try InProcessWindow(Controls(tally: Tally()))
      defer { screen.close() }
      let clock = ContinuousClock()
      let waited = await clock.measure { await screen.settle(.milliseconds(250)) }
      #expect(waited >= .milliseconds(240))
      #expect(waited < .seconds(5))
    }

    @Test("each failure says what was missing")
    func descriptions() {
      #expect(
        InProcessWindowError.unavailable("a window").description
          == "Not available in this process: a window.")
      #expect(InProcessWindowError.notFound("go").description == "Nothing is named go.")
      #expect(
        InProcessWindowError.notActivated("go").description
          == "go is disabled or took no activation.")
    }

    @Test("a missing accessibility library is reported, not skipped")
    func missingLibrary() {
      let path = "/usr/lib/no-such-accessibility.dylib"
      #expect(throws: InProcessWindowError.unavailable("the accessibility library at \(path)")) {
        try AccessibilityAutomation.enable(library: path)
      }
      // A library without the switch: the C library has no such symbol.
      #expect(throws: InProcessWindowError.unavailable("the accessibility automation switch")) {
        try AccessibilityAutomation.enable(library: "/usr/lib/libSystem.B.dylib")
      }
    }
  }
#endif

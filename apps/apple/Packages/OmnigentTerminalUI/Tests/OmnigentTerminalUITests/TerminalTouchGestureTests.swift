#if os(iOS)
  import Foundation
  import GhosttyKit
  import OmnigentViewTesting
  import Testing
  import UIKit

  @testable import OmnigentTerminalUI

  /// SGR mouse tracking: the program asks for button and wheel reports as `ESC [ < ...`.
  private let trackMouse = "\u{1b}[?1000h\u{1b}[?1006h"

  @Suite("Terminal on iOS: hardware keys, focus and frames", .serialized)
  struct TerminalHardwareKeyTests {
    @Test("a Control chord goes through Ghostty's encoder and is held until released")
    func controlChord() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      let key = ScriptedKey("c", .keyboardC, .control)
      surface.view.pressesBegan(key.pressed, with: nil)
      #expect(await surface.receives("\u{3}"))
      #expect(surface.view.heldKeys[.keyboardC] == 0x08)
      surface.view.pressesEnded(key.pressed, with: nil)
      #expect(surface.view.heldKeys.isEmpty)
      // A release of a key that was never held is UIKit's to handle.
      surface.view.pressesEnded(key.pressed, with: nil)
      surface.view.pressesBegan(key.pressed, with: nil)
      surface.view.pressesCancelled(key.pressed, with: nil)
      #expect(surface.view.heldKeys.isEmpty)
      #expect(await surface.receives("\u{3}\u{3}"))
    }

    @Test("keys that type nothing are encoded; plain text keys are left to the text system")
    func whichKeysAreEncoded() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      let view = surface.view
      let arrow = String(UnicodeScalar(0xF700 as UInt32).map(Character.init) ?? " ")
      view.pressesBegan(ScriptedKey(arrow, .keyboardUpArrow).pressed, with: nil)
      #expect(await surface.receives("\u{1b}[A"))
      view.pressesBegan(ScriptedKey("", .keyboardEscape).pressed, with: nil)
      #expect(await surface.receives("\u{1b}[A\u{1b}"))
      view.pressesBegan(ScriptedKey("\u{7f}", .keyboardDeleteOrBackspace).pressed, with: nil)
      #expect(await surface.receives("\u{1b}[A\u{1b}\u{7f}"))
      #expect(view.heldKeys.count == 3)

      view.pressesBegan(ScriptedKey("a", .keyboardA).pressed, with: nil)
      view.pressesBegan([ScriptedPress(key: nil)], with: nil)
      #expect(view.heldKeys.count == 3)
      // Option with a letter carries the letter's text to the encoder.
      view.pressesBegan(ScriptedKey("a", .keyboardA, .alternate).pressed, with: nil)
      #expect(await eventually { surface.connection.received.last == 0x61 })
      #expect(view.heldKeys[.keyboardA] == 0x00)
      // A usage with no key code is dropped rather than sent as some other key.
      let before = surface.connection.received
      view.pressesBegan(ScriptedKey("", .keyboardLANG9, .control).pressed, with: nil)
      try await Task.sleep(for: .milliseconds(80))
      #expect(surface.connection.received == before)
      #expect(view.heldKeys[.keyboardLANG9] == nil)
    }

    @Test("UIKit's modifier flags map to Ghostty's bits")
    func modifierBits() {
      #expect(ghosttyMods([]) == GHOSTTY_MODS_NONE)
      #expect(ghosttyMods(.shift) == GHOSTTY_MODS_SHIFT)
      #expect(ghosttyMods(.control) == GHOSTTY_MODS_CTRL)
      #expect(ghosttyMods(.alternate) == GHOSTTY_MODS_ALT)
      #expect(ghosttyMods(.command) == GHOSTTY_MODS_SUPER)
      #expect(ghosttyMods(.alphaShift) == GHOSTTY_MODS_CAPS)
      let all = ghosttyMods([.shift, .control, .alternate, .command, .alphaShift])
      #expect(
        all.rawValue
          == GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_ALT.rawValue
          | GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_CAPS.rawValue)
    }

    @Test("focus is reported to a program that asked, and keeps the cursor blinking")
    func focus() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      #expect(surface.view.canBecomeFirstResponder)
      #expect(surface.view.blinkTimer == nil)
      surface.controller.focus()
      #expect(surface.view.isFirstResponder)
      #expect(surface.view.blinkTimer?.isValid == true)
      // The blink asks for a frame about twice a second; a frame is pending for an instant.
      let link = try #require(surface.view.displayLink)
      #expect(await eventually { link.isPaused })
      var blinked = false
      let deadline = ContinuousClock.now + .seconds(2)
      while !blinked, ContinuousClock.now < deadline {
        blinked = !link.isPaused
        try await Task.sleep(for: .milliseconds(2))
      }
      #expect(blinked)

      #expect(surface.view.resignFirstResponder())
      #expect(surface.view.blinkTimer == nil)
      #expect(!surface.view.isFirstResponder)
      // Focus alone types nothing.
      #expect(surface.connection.received.isEmpty)
    }

    @Test("the surface follows its view's size, and draws only while on a window")
    func sizeAndFrames() async throws {
      let surface = try TouchSurface(width: 480, height: 240)
      defer { surface.close() }
      #expect(await surface.ready())
      let first = try #require(surface.controller.gridSize)
      #expect(surface.connection.sizes.last == first)
      #expect(surface.view.layer.sublayers?.allSatisfy { $0.frame == surface.view.bounds } == true)

      surface.screen.window.frame = CGRect(x: 0, y: 0, width: 800, height: 480)
      surface.screen.window.layoutIfNeeded()
      #expect(await eventually { (surface.controller.gridSize?.columns ?? 0) > first.columns })
      #expect((surface.controller.gridSize?.rows ?? 0) > first.rows)

      #expect(surface.view.requestRender())
      let link = try #require(surface.view.displayLink)
      #expect(!link.isPaused)
      // Each frame is drawn once; with nothing new the link idles.
      #expect(await eventually { !surface.view.renderPending && link.isPaused })
      #expect(surface.view.requestRender())
      #expect(!link.isPaused)
      surface.view.removeFromSuperview()
      #expect(link.isPaused)
      surface.view.stopRendering()
      #expect(surface.view.displayLink == nil)
      #expect(!surface.view.renderPending)
    }

    @Test("a bell and a pointer shape from the program leave the terminal working")
    func programActions() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      surface.view.setPointerShape(GHOSTTY_MOUSE_SHAPE_TEXT)
      try await surface.programPrints("\u{7}after the bell")
      #expect(await eventually { surface.controller.visibleText().contains("after the bell") })
    }
  }

  @Suite("Terminal on iOS: touch and the edit menu", .serialized)
  struct TerminalTouchTests {
    @Test("a tap focuses the terminal, and clears a selection instead of clicking")
    func tap() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      surface.view.tapped(ScriptedTap(at: CGPoint(x: 20, y: 20)))
      #expect(surface.view.isFirstResponder)
      surface.controller.selectAll()
      #expect(await eventually { surface.controller.hasSelection })
      surface.view.tapped(ScriptedTap(at: CGPoint(x: 20, y: 20)))
      #expect(!surface.controller.hasSelection)
      #expect(!surface.view.selecting)
      try await Task.sleep(for: .milliseconds(80))
      #expect(surface.connection.received.isEmpty)
    }

    @Test("a program that tracks the mouse gets a tap as a click where the finger was")
    func tapClicksInATUI() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      try await surface.programPrints(trackMouse)
      surface.view.tapped(ScriptedTap(at: CGPoint(x: 4, y: 4)))
      #expect(await surface.receives("\u{1b}[<0;1;1M\u{1b}[<0;1;1m"))
    }

    @Test("a drag scrolls: wheel reports for a TUI, by how far the finger moved")
    func dragScrolls() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      try await surface.programPrints(trackMouse)
      // The reports carry the pointer's place, which the first tap gives.
      surface.view.tapped(ScriptedTap(at: CGPoint(x: 40, y: 40)))
      let pan = ScriptedPan()
      pan.phase = .began
      surface.view.panned(pan)
      #expect(surface.view.lastPan == .zero)
      pan.phase = .changed
      pan.moved = CGPoint(x: 0, y: 90)
      surface.view.panned(pan)
      #expect(surface.view.lastPan == CGPoint(x: 0, y: 90))
      #expect(await eventually { surface.sent.contains("\u{1b}[<64;") })
      let afterScrollingUp = surface.connection.received.count
      // The finger coming back scrolls the other way, by the difference only.
      pan.moved = .zero
      surface.view.panned(pan)
      #expect(await eventually { surface.sent.contains("\u{1b}[<65;") })
      #expect(surface.connection.received.count > afterScrollingUp)
      pan.phase = .possible
      surface.view.panned(pan)
      pan.phase = .ended
      pan.speed = CGPoint(x: 0, y: 30)
      surface.view.panned(pan)
      #expect(surface.view.momentum == nil)
    }

    @Test("a flick keeps scrolling, slows and stops; a new drag stops it at once")
    func momentum() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      try await surface.programPrints(trackMouse)
      surface.view.tapped(ScriptedTap(at: CGPoint(x: 40, y: 40)))
      let pan = ScriptedPan()
      pan.phase = .ended
      pan.speed = CGPoint(x: 0, y: 900)
      surface.view.panned(pan)
      #expect(surface.view.momentum != nil)
      #expect(await eventually { surface.sent.contains("\u{1b}[<64;") })
      #expect(await eventually(timeout: .seconds(4)) { surface.view.momentum == nil })
      #expect(abs(surface.view.momentumVelocity.y) <= 20)

      surface.view.panned(pan)
      #expect(surface.view.momentum != nil)
      pan.phase = .began
      surface.view.panned(pan)
      #expect(surface.view.momentum == nil)
      let sent = surface.connection.received.count
      try await Task.sleep(for: .milliseconds(150))
      #expect(surface.connection.received.count == sent)
    }

    @Test("a long press selects, a drag extends, and lifting offers the edit menu there")
    func longPressSelects() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      let press = ScriptedLongPress()
      press.phase = .began
      press.point = CGPoint(x: 4, y: 8)
      surface.view.longPressed(press)
      #expect(surface.view.selecting)
      press.phase = .changed
      press.point = CGPoint(x: 200, y: 8)
      surface.view.longPressed(press)
      #expect(await eventually { surface.controller.hasSelection })
      #expect(surface.editMenu.presentedAt.isEmpty)
      press.phase = .possible
      surface.view.longPressed(press)
      press.phase = .ended
      surface.view.longPressed(press)
      #expect(surface.editMenu.presentedAt == [CGPoint(x: 200, y: 8)])
      #expect(surface.controller.hasSelection)

      // A test process may write the pasteboard but not read its text back.
      UIPasteboard.general.items = []
      surface.view.copy(nil)
      #expect(await eventually { UIPasteboard.general.hasStrings })
      let pan = UIPanGestureRecognizer()
      #expect(!surface.view.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: press))
    }

    @Test("the edit menu offers Copy with a selection, Paste with text to paste, and Select All")
    func editActions() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      let view = surface.view
      let copy = #selector(UIResponder.copy(_:))
      let paste = #selector(UIResponder.paste(_:))
      let selectAll = #selector(UIResponder.selectAll(_:))
      UIPasteboard.general.items = []
      #expect(!view.canPerformAction(copy, withSender: nil))
      #expect(!view.canPerformAction(paste, withSender: nil))
      #expect(view.canPerformAction(selectAll, withSender: nil))
      #expect(!view.canPerformAction(#selector(UIResponder.cut(_:)), withSender: nil))

      view.selectAll(nil)
      #expect(await eventually { surface.controller.hasSelection })
      #expect(view.canPerformAction(copy, withSender: nil))
      UIPasteboard.general.string = "pasted"
      #expect(view.canPerformAction(paste, withSender: nil))
      // The paste itself finds no text a test process may read, and types nothing.
      view.paste(nil)
      try await surface.programPrints("after the paste")
      #expect(await eventually { surface.controller.visibleText().contains("after the paste") })
      #expect(surface.connection.received.isEmpty)
    }
  }
#endif

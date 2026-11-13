#if os(iOS)
  import Testing
  import UIKit

  @testable import OmnigentViewTesting

  /// A handler written as product code writes one: it reads only its recognizer.
  @MainActor
  private final class PanReader: NSObject {
    var states: [UIGestureRecognizer.State] = []
    var travelled = CGPoint.zero
    var lastPoint = CGPoint.zero
    var lastSpeed = CGPoint.zero
    var fingers = 0

    @objc func panned(_ recognizer: UIPanGestureRecognizer) {
      states.append(recognizer.state)
      let step = recognizer.translation(in: nil)
      travelled = CGPoint(x: travelled.x + step.x, y: travelled.y + step.y)
      recognizer.setTranslation(.zero, in: nil)
      lastPoint = recognizer.location(in: nil)
      lastSpeed = recognizer.velocity(in: nil)
      fingers = recognizer.numberOfTouches
    }
  }

  @MainActor
  @Suite("Scripted touches and keys")
  struct ScriptedTouchTests {
    @Test("a tap is where the test put it, in any view's coordinates")
    func tap() {
      let tap = ScriptedTap(at: CGPoint(x: 12, y: 34))
      #expect(tap.location(in: nil) == CGPoint(x: 12, y: 34))
      #expect(tap.location(in: UIView()) == CGPoint(x: 12, y: 34))
      tap.point = CGPoint(x: 1, y: 2)
      #expect(tap.location(in: nil) == CGPoint(x: 1, y: 2))
      #expect(ScriptedTap().location(in: nil) == .zero)
    }

    @Test("a handler reads a scripted pan as it reads a finger's, and its resets stick")
    func pan() {
      let reader = PanReader()
      let pan = ScriptedPan()
      #expect(pan.state == .possible)
      pan.phase = .began
      pan.point = CGPoint(x: 5, y: 5)
      pan.moved = CGPoint(x: 0, y: 10)
      reader.panned(pan)
      #expect(pan.moved == .zero)
      pan.phase = .changed
      pan.moved = CGPoint(x: 3, y: 20)
      pan.point = CGPoint(x: 8, y: 35)
      pan.speed = CGPoint(x: 0, y: 400)
      pan.fingers = 2
      reader.panned(pan)
      #expect(reader.states == [.began, .changed])
      #expect(reader.travelled == CGPoint(x: 3, y: 30))
      #expect(reader.lastPoint == CGPoint(x: 8, y: 35))
      #expect(reader.lastSpeed == CGPoint(x: 0, y: 400))
      #expect(reader.fingers == 2)
      // UIKit's own setter writes the scripted phase too.
      pan.state = .ended
      #expect(pan.phase == .ended)
    }

    @Test("pinch, long press and hover report the phase and point they were given")
    func phases() {
      let pinch = ScriptedPinch()
      pinch.phase = .changed
      pinch.point = CGPoint(x: 9, y: 9)
      pinch.scale = 1.5
      #expect(pinch.state == .changed)
      #expect(pinch.location(in: nil) == CGPoint(x: 9, y: 9))
      #expect(pinch.scale == 1.5)
      pinch.state = .ended
      #expect(pinch.phase == .ended)

      let press = ScriptedLongPress()
      #expect(press.state == .possible)
      press.phase = .began
      press.point = CGPoint(x: 4, y: 6)
      #expect(press.state == .began)
      #expect(press.location(in: UIView()) == CGPoint(x: 4, y: 6))
      press.state = .cancelled
      #expect(press.phase == .cancelled)

      let hover = ScriptedHover()
      #expect(hover.state == .possible)
      hover.phase = .changed
      hover.point = CGPoint(x: 7, y: 1)
      #expect(hover.state == .changed)
      #expect(hover.location(in: nil) == CGPoint(x: 7, y: 1))
      hover.state = .ended
      #expect(hover.phase == .ended)
    }

    @Test("a recording edit menu notes each presentation and dismissal and shows nothing")
    func editMenu() {
      let menu = RecordingEditMenu(delegate: nil)
      let view = UIView()
      view.addInteraction(menu)
      menu.presentEditMenu(
        with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: 1, y: 2)))
      menu.dismissMenu()
      menu.presentEditMenu(
        with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: 3, y: 4)))
      #expect(menu.presentedAt == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])
      #expect(menu.dismissals == 1)
    }

    @Test("a scripted key carries its usage, characters and modifiers into a press")
    func key() throws {
      let key = ScriptedKey("A", .keyboardA, [.shift, .command])
      #expect(key.keyCode == .keyboardA)
      #expect(key.characters == "A")
      #expect(key.charactersIgnoringModifiers == "A")
      #expect(key.modifierFlags == [.shift, .command])
      let press = try #require(key.pressed.first)
      #expect(key.pressed.count == 1)
      #expect(press.key === key)
      #expect(ScriptedKey("", .keyboardEscape).modifierFlags.isEmpty)
      #expect(ScriptedPress(key: nil).key == nil)
    }
  }
#endif

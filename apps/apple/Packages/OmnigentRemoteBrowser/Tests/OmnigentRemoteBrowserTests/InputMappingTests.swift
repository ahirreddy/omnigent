import CoreGraphics
import OmnigentCoreFFI
import OmnigentInput
import Testing

@testable import OmnigentRemoteBrowser

#if os(macOS)
  import AppKit
#endif

@Suite("Viewport geometry")
struct GeometryTests {
  private let viewport = RemoteViewport(width: 1280, height: 800, dpr: 1)

  @Test func aWideViewLetterboxesLeftAndRight() throws {
    let geometry = try #require(
      RemoteViewportGeometry(viewport: viewport, bounds: CGSize(width: 2000, height: 800)))
    #expect(geometry.scale == 1)
    #expect(geometry.contentRect == CGRect(x: 360, y: 0, width: 1280, height: 800))
    #expect(geometry.cssPoint(for: CGPoint(x: 360, y: 10)) == CGPoint(x: 0, y: 10))
    #expect(geometry.cssPoint(for: CGPoint(x: 100, y: 10)) == nil)
    #expect(geometry.cssPoint(for: CGPoint(x: 100, y: 10), clamped: true) == CGPoint(x: 0, y: 10))
  }

  @Test func aTallViewScalesDownAndLetterboxesTopAndBottom() throws {
    let geometry = try #require(
      RemoteViewportGeometry(viewport: viewport, bounds: CGSize(width: 640, height: 1000)))
    #expect(geometry.scale == 0.5)
    #expect(geometry.contentRect == CGRect(x: 0, y: 300, width: 640, height: 400))
    #expect(geometry.cssPoint(for: CGPoint(x: 320, y: 500)) == CGPoint(x: 640, y: 400))
    #expect(geometry.viewPoint(for: CGPoint(x: 640, y: 400)) == CGPoint(x: 320, y: 500))
    #expect(geometry.cssLength(10) == 20)
  }

  @Test func deviceScaleChangesVideoPixelsNotCSSPixels() throws {
    let viewport = RemoteViewportGeometry.viewport(
      videoSize: CGSize(width: 2560, height: 1600), deviceScale: 2)
    #expect(viewport == RemoteViewport(width: 1280, height: 800, dpr: 2))
    let geometry = try #require(
      RemoteViewportGeometry(viewport: viewport, bounds: CGSize(width: 1280, height: 800)))
    #expect(geometry.cssPoint(for: CGPoint(x: 1279, y: 799)) == CGPoint(x: 1279, y: 799))
  }
}

@Suite("Remote input mapping")
struct InputMappingTests {
  private let geometry: RemoteViewportGeometry

  init() throws {
    geometry = try #require(
      RemoteViewportGeometry(
        viewport: RemoteViewport(width: 1280, height: 800, dpr: 1),
        bounds: CGSize(width: 640, height: 400)))
  }

  @Test func clicksMapToCSSPixelsWithTheCoresModifierBits() throws {
    let down = PointerInput(
      kind: .press, location: CGPoint(x: 100, y: 50), button: .right, clickCount: 2,
      modifiers: [.shift, .command, .rightMouse])
    let mapped = try #require(RemoteInputMapping.mouse(down, geometry: geometry))
    #expect(mapped.kind == .down)
    #expect(mapped.x == 200 && mapped.y == 100)
    #expect(mapped.button == .right)
    #expect(mapped.clicks == 2)
    #expect(RemoteModifiers(rawValue: mapped.modifiers) == [.shift, .meta, .rightButton])
    #expect(mapped.modifiers == 1 << 0 | 1 << 3 | 1 << 8)
  }

  @Test func wheelDeltasUseTheDOMSignAndCSSPixels() throws {
    // CEF: positive deltaY scrolls toward the top. DOM: positive deltaY scrolls down.
    let wheel = PointerInput(kind: .wheel, location: CGPoint(x: 10, y: 10), deltaY: -30)
    let mapped = try #require(RemoteInputMapping.mouse(wheel, geometry: geometry))
    #expect(mapped.dy == 60)
    #expect(mapped.dx == 0)
    #expect(mapped.button == nil)
  }

  @Test func dragsOutsideThePageClampAndHoversOutsideDrop() {
    let outside = CGPoint(x: 700, y: 10)
    #expect(
      RemoteInputMapping.mouse(PointerInput(kind: .move, location: outside), geometry: geometry)
        == nil)
    let drag = RemoteInputMapping.mouse(
      PointerInput(kind: .move, location: outside, modifiers: [.leftMouse]), geometry: geometry)
    #expect(drag?.x == 1279)
    let release = RemoteInputMapping.mouse(
      PointerInput(kind: .release, location: outside), geometry: geometry)
    #expect(release?.x == 1279)
    #expect(drag?.modifiers == RemoteModifiers.leftButton.rawValue)
  }

  @Test func pressesHoldTheirButtonAndReleasesClearIt() throws {
    let point = CGPoint(x: 10, y: 10)
    let press = try #require(
      RemoteInputMapping.mouse(PointerInput(kind: .press, location: point), geometry: geometry))
    #expect(press.modifiers == RemoteModifiers.leftButton.rawValue)
    let release = try #require(
      RemoteInputMapping.mouse(
        PointerInput(kind: .release, location: point, modifiers: [.leftMouse, .shift]),
        geometry: geometry))
    #expect(release.modifiers == RemoteModifiers.shift.rawValue)
    #expect(release.button == .left)
  }

  @Test func namedKeysAndTypedText() {
    #expect(RemoteInputMapping.key(macKeyCode: 36, characters: "\r") == "Enter")
    #expect(RemoteInputMapping.key(macKeyCode: 123, characters: "\u{F702}") == "ArrowLeft")
    #expect(RemoteInputMapping.key(macKeyCode: 0, characters: "a") == "a")
    #expect(RemoteInputMapping.key(macKeyCode: 0, characters: "") == "Dead")
    #expect(RemoteInputMapping.key(macKeyCode: 122, characters: "\u{F704}") == "F1")
    #expect(RemoteInputMapping.namedKey(hidUsage: 0x28) == "Enter")
    #expect(RemoteInputMapping.namedKey(hidUsage: 0x45) == "F12")
    #expect(RemoteInputMapping.namedKey(hidUsage: 0x04) == nil)
  }

  @Test func charsAreWholeCharactersNotUTF16Units() {
    let inputs = [
      NativeKeyInput(kind: .rawKeyDown, nativeKeyCode: 0, character: 0xD83D),
      NativeKeyInput(kind: .char, nativeKeyCode: 0, character: 0xD83D),
      NativeKeyInput(kind: .char, nativeKeyCode: 0, character: 0xDE00),
    ]
    let keys = RemoteInputMapping.keys(inputs, characters: "\u{1F600}")
    #expect(keys.map(\.kind) == [.rawKeyDown, .char])
    #expect(keys[1].text == "\u{1F600}")
    #expect(keys[0].macKeyCode == 0)
    #expect(keys[0].code == nil)  // The core fills `code` from the key code.
  }

  #if os(macOS)
    private func event(
      _ type: NSEvent.EventType, code: UInt16, characters: String,
      flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false
    ) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: isRepeat, keyCode: code))
    }

    private func keys(_ event: NSEvent) -> [KeyInput] {
      RemoteInputMapping.keys(
        InputTranslator.keyInputs(for: event), characters: event.characters ?? "")
    }

    @Test func macKeyEventsBecomeKeyRecords() throws {
      let letter = keys(try event(.keyDown, code: 0, characters: "a", flags: .shift))
      #expect(letter.map(\.kind) == [.rawKeyDown, .char])
      #expect(letter.map(\.key) == ["a", "a"])
      #expect(RemoteModifiers(rawValue: letter[0].modifiers) == [.shift])
      let enter = keys(try event(.keyDown, code: 36, characters: "\r"))
      #expect(enter.map(\.key) == ["Enter", "Enter"])
      #expect(enter[1].text == "\r")
      let arrow = keys(try event(.keyDown, code: 123, characters: "\u{F702}", isRepeat: true))
      #expect(arrow.map(\.kind) == [.rawKeyDown])
      #expect(arrow[0].key == "ArrowLeft")
      #expect(arrow[0].repeat)
      let copy = keys(try event(.keyDown, code: 8, characters: "c", flags: .command))
      #expect(copy.map(\.kind) == [.rawKeyDown])
      #expect(RemoteModifiers(rawValue: copy[0].modifiers) == [.meta])
      let release = keys(try event(.keyUp, code: 0, characters: "a"))
      #expect(release.map(\.kind) == [.keyUp])
    }
  #endif

  @Test func cssCursorsMapToNativeShapes() {
    #expect(RemoteBrowserCursor(keyword: "pointer", custom: nil).pageCursor == .hand)
    #expect(RemoteBrowserCursor(keyword: "text", custom: nil).pageCursor == .iBeam)
    #expect(RemoteBrowserCursor(keyword: "ew-resize", custom: nil).pageCursor == .resizeLeftRight)
    #expect(
      RemoteBrowserCursor(keyword: "-webkit-future-cursor", custom: nil).pageCursor == .pointer)
  }
}

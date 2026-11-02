public import AppKit
internal import OWLProtocol
internal import OmnigentInput
internal import os

/// Mouse buttons for agent input.
nonisolated public enum AgentMouseButton: Sendable, Hashable {
  /// Primary button.
  case left
  /// Middle button.
  case middle
  /// Secondary button.
  case right

  var wire: PointerButton {
    switch self {
    case .left: .left
    case .middle: .middle
    case .right: .right
    }
  }
}

/// Modifier keys held during agent input.
nonisolated public struct AgentModifiers: OptionSet, Sendable, Hashable {
  /// Raw bits.
  public let rawValue: Int
  /// Creates modifiers from raw bits.
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Shift.
  public static let shift = Self(rawValue: 1 << 0)
  /// Control.
  public static let control = Self(rawValue: 1 << 1)
  /// Option.
  public static let option = Self(rawValue: 1 << 2)
  /// Command.
  public static let command = Self(rawValue: 1 << 3)

  var wire: InputModifiers {
    var result: InputModifiers = []
    if contains(.shift) { result.insert(.shift) }
    if contains(.control) { result.insert(.control) }
    if contains(.option) { result.insert(.alt) }
    if contains(.command) { result.insert(.command) }
    return result
  }
}

/// Forwards input into a view's renderer.
///
/// Two paths, kept apart on purpose (see DESIGN.md, "Agent input"):
/// - User input: NSEvents from the hosting view, translated here. Keys the page does not handle
///   come back and are re-dispatched to the app through `onUnhandledKeyEvent`.
/// - Agent input: synthetic events tagged as agent-originated. The host sends them straight to
///   the page's render widget; they never reach the app's menus or responders, browser-level
///   shortcuts, DevTools, or permission and dialog UI, and unhandled ones are dropped.
public final class WebContentRenderer {
  /// Receives re-synthesized NSEvents for user keys the page did not handle. `WebLayerView`
  /// sets this to dispatch them to the main menu and the responder chain.
  public var onUnhandledKeyEvent: ((NSEvent) -> Void)?

  weak var webView: WebView?
  private var lastKeyDown: [UInt16: NSEvent] = [:]

  init(webView: WebView) {
    self.webView = webView
  }

  // MARK: User input

  /// Forwards a mouse, drag or scroll event. `location` is in the view's top-left coordinates.
  public func forwardMouseEvent(_ event: NSEvent, location: CGPoint) {
    guard let input = InputTranslator.pointerInput(for: event, location: location) else { return }
    webView?.sendIfLive(.inputMouse, input.encoded(origin: .user))
  }

  /// Forwards keyDown, keyUp and flagsChanged.
  public func forwardKeyEvent(_ event: NSEvent) {
    if event.type == .keyDown {
      lastKeyDown[event.keyCode] = event
    }
    for input in InputTranslator.keyInputs(for: event) {
      webView?.sendIfLive(.inputKey, input.encoded(origin: .user))
    }
  }

  func handleUnhandledKey(_ fields: WireDecoder) {
    guard let keyCode = fields.u64(.nativeKeyCode).map({ UInt16(truncatingIfNeeded: $0) }) else {
      Logger.view.error("KeyUnhandled without a key code.")
      return
    }
    let template = lastKeyDown.removeValue(forKey: keyCode)
    guard
      let event = InputTranslator.unhandledKeyEvent(
        UnhandledKey(
          keyCode: keyCode, modifiers: InputModifiers(rawValue: fields.u64(.modifiers) ?? 0),
          character: UInt16(truncatingIfNeeded: fields.u64(.character) ?? 0),
          unmodifiedCharacter: UInt16(truncatingIfNeeded: fields.u64(.unmodifiedCharacter) ?? 0)),
        template: template, windowNumber: template?.windowNumber ?? 0)
    else {
      Logger.view.error("Could not rebuild an NSEvent for unhandled key \(keyCode).")
      return
    }
    guard let onUnhandledKeyEvent else {
      Logger.view.debug("Unhandled key \(keyCode) has no receiver; no view is attached.")
      return
    }
    onUnhandledKeyEvent(event)
  }

  // MARK: Agent input

  /// Clicks at `point` (view coordinates, points, top-left origin).
  public func agentClick(
    at point: CGPoint, button: AgentMouseButton = .left, clickCount: Int = 1,
    modifiers: AgentModifiers = []
  ) throws(WebLayerError) {
    try agentMove(to: point, modifiers: modifiers)
    for kind in [PointerEventKind.press, .release] {
      try sendAgentMessage(
        .inputMouse,
        PointerInput(
          kind: kind, location: point, button: button.wire, clickCount: clickCount,
          modifiers: modifiers.wire
        ).encoded(origin: .agent))
    }
  }

  /// Moves the pointer to `point`.
  public func agentMove(to point: CGPoint, modifiers: AgentModifiers = []) throws(WebLayerError) {
    try sendAgentMessage(
      .inputMouse,
      PointerInput(kind: .move, location: point, modifiers: modifiers.wire).encoded(
        origin: .agent))
  }

  /// Scrolls by the given deltas in points; positive `deltaY` scrolls up.
  public func agentScroll(at point: CGPoint, deltaX: Double, deltaY: Double)
    throws(WebLayerError)
  {
    try sendAgentMessage(
      .inputMouse,
      PointerInput(kind: .wheel, location: point, deltaX: deltaX, deltaY: deltaY).encoded(
        origin: .agent))
  }

  /// Types `text` into the focused element, one key press per character.
  public func agentType(_ text: String) throws(WebLayerError) {
    for character in text {
      try agentPress(character == "\n" ? .enter : .character(character))
    }
  }

  /// Presses and releases one key.
  public func agentPress(_ key: AgentKey, modifiers: AgentModifiers = []) throws(WebLayerError) {
    for input in key.keyInputs(modifiers: modifiers.wire) {
      try sendAgentMessage(.inputKey, input.encoded(origin: .agent))
    }
  }

  func sendAgentMessage(_ kind: OWLMessageKind, _ fields: WireEncoder) throws(WebLayerError) {
    guard let webView else { throw .viewClosed }
    switch webView.status {
    case .live:
      try webView.session.post(kind, target: webView.id, fields)
    case .closed:
      throw .viewClosed
    case .unavailable(let error):
      throw error
    case .waitingForHost, .creating:
      throw .notReady
    }
  }
}

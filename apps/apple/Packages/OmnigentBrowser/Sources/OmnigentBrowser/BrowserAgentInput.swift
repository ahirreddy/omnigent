public import CoreGraphics

/// Input an agent sends to a tab's page. It never reaches the app's menus, responders or
/// browser UI. On Chromium it goes straight to the page's renderer (`WebContentRenderer`'s
/// agent path, tagged agent-originated on the wire); on WebKit it is dispatched as DOM events
/// from script, which pages can tell apart from user input (`isTrusted` is false).
public protocol BrowserAgentInput: AnyObject {
  /// Whether input reaches the renderer as trusted input events (Chromium).
  var isRendererDirect: Bool { get }
  /// Whether the page needs its view in a window to render and take input. WebKit does; the
  /// out-of-process Chromium page renders on its own.
  var needsHostWindow: Bool { get }
  /// Makes the tab an agent page: it renders at `viewport` (points) and takes input while no
  /// app window shows it.
  func prepareForAgent(viewport: CGSize)
  /// Clicks at `point` in page coordinates (CSS pixels from the viewport's top-left).
  func click(at point: CGPoint, clickCount: Int) async throws(BrowserError)
  /// Scrolls by `deltaX`/`deltaY` CSS pixels at `point`; positive `deltaY` scrolls down.
  func scroll(at point: CGPoint, deltaX: Double, deltaY: Double) async throws(BrowserError)
  /// Inserts text into the focused element as one input event.
  func insertText(_ text: String) async throws(BrowserError)
  /// Presses and releases a key.
  func press(_ key: BrowserAgentKey, modifiers: BrowserAgentModifiers) async throws(BrowserError)
}

/// Keys an agent can press.
nonisolated public enum BrowserAgentKey: Sendable, Hashable {
  /// Return.
  case enter
  /// Tab.
  case tab
  /// Escape.
  case escape
  /// Delete backward.
  case backspace
  /// Forward delete.
  case delete
  /// Arrow left.
  case arrowLeft
  /// Arrow right.
  case arrowRight
  /// Arrow up.
  case arrowUp
  /// Arrow down.
  case arrowDown
  /// Home.
  case home
  /// End.
  case end
  /// Page up.
  case pageUp
  /// Page down.
  case pageDown
  /// A printable character.
  case character(Character)

  private static let named: [String: Self] = [
    "enter": .enter, "return": .enter, "tab": .tab, "escape": .escape, "esc": .escape,
    "backspace": .backspace, "delete": .delete, "arrowleft": .arrowLeft,
    "arrowright": .arrowRight, "arrowup": .arrowUp, "arrowdown": .arrowDown, "home": .home,
    "end": .end, "pageup": .pageUp, "pagedown": .pageDown, "space": .character(" "),
  ]

  /// Parses a DOM `KeyboardEvent.key`-style name ("Enter", "ArrowDown", "a").
  public init?(name: String) {
    if let key = Self.named[name.lowercased()] {
      self = key
    } else if name.count == 1, let character = name.first {
      self = .character(character)
    } else {
      return nil
    }
  }

  /// The DOM `key` value.
  public var domKey: String {
    switch self {
    case .enter: "Enter"
    case .tab: "Tab"
    case .escape: "Escape"
    case .backspace: "Backspace"
    case .delete: "Delete"
    case .arrowLeft: "ArrowLeft"
    case .arrowRight: "ArrowRight"
    case .arrowUp: "ArrowUp"
    case .arrowDown: "ArrowDown"
    case .home: "Home"
    case .end: "End"
    case .pageUp: "PageUp"
    case .pageDown: "PageDown"
    case .character(let character): String(character)
    }
  }
}

/// Modifier keys held during an agent key press.
nonisolated public struct BrowserAgentModifiers: OptionSet, Sendable, Hashable {
  /// Raw bits.
  public let rawValue: Int
  /// Creates modifiers from raw bits.
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Shift.
  public static let shift = Self(rawValue: 1 << 0)
  /// Control.
  public static let control = Self(rawValue: 1 << 1)
  /// Option (Alt).
  public static let option = Self(rawValue: 1 << 2)
  /// Command (Meta).
  public static let command = Self(rawValue: 1 << 3)

  /// Parses names such as "Shift", "Control", "Alt", "Meta". Unknown names return nil.
  public init?(names: [String]) {
    var result: Self = []
    for name in names {
      switch name.lowercased() {
      case "shift": result.insert(.shift)
      case "control", "ctrl": result.insert(.control)
      case "alt", "option": result.insert(.option)
      case "meta", "command", "cmd": result.insert(.command)
      default: return nil
      }
    }
    self = result
  }
}

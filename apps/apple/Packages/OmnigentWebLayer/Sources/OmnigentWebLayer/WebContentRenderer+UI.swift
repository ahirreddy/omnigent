public import AppKit
internal import OWLProtocol
internal import OmnigentInput

/// What a drag carries between the app and the page (protocol 1.1).
nonisolated public struct WebDragData: Sendable, Hashable, Codable {
  /// Plain text.
  public var text: String?
  /// An HTML fragment.
  public var html: String?
  /// A link.
  public var url: String?
  /// The link's title.
  public var urlTitle: String?
  /// The name of a dragged virtual file (for example an image dragged out of the page).
  public var fileName: String?
  /// Absolute paths of dragged files; empty when none.
  public var paths: [String]

  private enum CodingKeys: String, CodingKey {
    case text, html, url, urlTitle, fileName, paths
  }

  /// Creates drag data.
  public init(
    text: String? = nil, html: String? = nil, url: String? = nil, urlTitle: String? = nil,
    fileName: String? = nil, paths: [String] = []
  ) {
    self.text = text
    self.html = html
    self.url = url
    self.urlTitle = urlTitle
    self.fileName = fileName
    self.paths = paths
  }

  /// Decodes the DragData JSON; every key is optional.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    text = try container.decodeIfPresent(String.self, forKey: .text)
    html = try container.decodeIfPresent(String.self, forKey: .html)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    urlTitle = try container.decodeIfPresent(String.self, forKey: .urlTitle)
    fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
    paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
  }
}

/// Drag operations, matching Chromium's mask.
nonisolated public struct WebDragOperations: OptionSet, Sendable, Hashable {
  /// Raw bits.
  public let rawValue: UInt64
  /// Creates operations from raw bits.
  public init(rawValue: UInt64) { self.rawValue = rawValue }

  /// Copy.
  public static let copy = Self(rawValue: OWLDragOperation.copy.rawValue)
  /// Link.
  public static let link = Self(rawValue: OWLDragOperation.link.rawValue)
  /// Generic (AppKit's default).
  public static let generic = Self(rawValue: OWLDragOperation.generic.rawValue)
  /// Move.
  public static let move = Self(rawValue: OWLDragOperation.move.rawValue)
  /// Delete.
  public static let delete = Self(rawValue: OWLDragOperation.delete.rawValue)

  /// The AppKit equivalent.
  public var dragOperation: NSDragOperation {
    var result: NSDragOperation = []
    if contains(.copy) { result.insert(.copy) }
    if contains(.link) { result.insert(.link) }
    if contains(.generic) { result.insert(.generic) }
    if contains(.move) { result.insert(.move) }
    if contains(.delete) { result.insert(.delete) }
    return result
  }

  /// From AppKit.
  public init(_ operation: NSDragOperation) {
    var result: Self = []
    if operation.contains(.copy) { result.insert(.copy) }
    if operation.contains(.link) { result.insert(.link) }
    if operation.contains(.generic) { result.insert(.generic) }
    if operation.contains(.move) { result.insert(.move) }
    if operation.contains(.delete) { result.insert(.delete) }
    self = result
  }
}

/// IME composition and drag and drop, in view points with a top-left origin. These are user
/// input; `agentInsertText` is the agent path. All need a 1.1 host (`Session.supportsBrowserUI`).
extension WebContentRenderer {
  /// Shows marked (composing) text. `selectedRange` is within `text`; `replacementRange`, in
  /// the field, is replaced by the composition.
  public func setComposition(_ text: String, selectedRange: NSRange, replacementRange: NSRange?) {
    var fields = WireEncoder()
      .string(.text, text)
      .i64(.rangeStart, Int64(selectedRange.location))
      .i64(.rangeEnd, Int64(NSMaxRange(selectedRange)))
    if let replacementRange, replacementRange.location != NSNotFound {
      fields = fields.i64(.replaceStart, Int64(replacementRange.location))
        .i64(.replaceEnd, Int64(NSMaxRange(replacementRange)))
    }
    sendUser(.imeSetComposition, fields)
  }

  /// Inserts committed text, ending any composition.
  public func commitText(_ text: String, replacementRange: NSRange?) {
    sendUser(.imeCommitText, Self.commitFields(text, replacementRange: replacementRange))
  }

  /// Commits the composition as it is.
  public func finishComposing(keepSelection: Bool) {
    sendUser(.imeFinishComposing, WireEncoder().bool(.keepSelection, keepSelection))
  }

  /// Discards the composition.
  public func cancelComposition() {
    sendUser(.imeCancelComposition)
  }

  /// Agent input: inserts `text` into the focused element as one input event, as an IME commit
  /// does. Faster than `agentType` for long text and fires the same `beforeinput` and `input`.
  public func agentInsertText(_ text: String) throws(WebLayerError) {
    guard let webView else { throw .viewClosed }
    guard webView.session.supportsBrowserUI else {
      try agentType(text)
      return
    }
    try sendAgentMessage(
      .imeCommitText, Self.commitFields(text, replacementRange: nil).bool(.agentInput, true))
  }

  /// A drag entered the page.
  public func dragEntered(
    _ data: WebDragData, at point: CGPoint, operations: WebDragOperations,
    modifiers: NSEvent.ModifierFlags = []
  ) {
    sendUser(
      .dragEnter,
      Self.dragFields(point, modifiers).u64(.dragOperations, operations.rawValue)
        .string(.dragData, WireJSON.encode(data)))
  }

  /// The drag moved over the page.
  public func dragUpdated(
    at point: CGPoint, operations: WebDragOperations, modifiers: NSEvent.ModifierFlags = []
  ) {
    sendUser(.dragOver, Self.dragFields(point, modifiers).u64(.dragOperations, operations.rawValue))
  }

  /// The drag left the page.
  public func dragExited() {
    sendUser(.dragLeave)
  }

  /// The drag was dropped on the page.
  public func performDrop(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
    sendUser(.dragDrop, Self.dragFields(point, modifiers))
  }

  /// A drag the page started ended at `point` with `operation`.
  public func dragSourceEnded(at point: CGPoint, operation: WebDragOperations) {
    sendUser(
      .dragSourceEnded, Self.dragFields(point, []).u64(.dragOperations, operation.rawValue))
  }

  private static func commitFields(_ text: String, replacementRange: NSRange?) -> WireEncoder {
    var fields = WireEncoder().string(.text, text).i64(.cursorPosition, 0)
    if let replacementRange, replacementRange.location != NSNotFound {
      fields = fields.i64(.replaceStart, Int64(replacementRange.location))
        .i64(.replaceEnd, Int64(NSMaxRange(replacementRange)))
    }
    return fields
  }

  private static func dragFields(_ point: CGPoint, _ modifiers: NSEvent.ModifierFlags)
    -> WireEncoder
  {
    WireEncoder()
      .double(.X, point.x)
      .double(.Y, point.y)
      .u64(.modifiers, InputTranslator.modifiers(modifiers).rawValue)
  }

  private func sendUser(_ kind: OWLMessageKind, _ fields: WireEncoder = WireEncoder()) {
    guard let webView, webView.session.supportsBrowserUI else { return }
    webView.sendIfLive(kind, fields)
  }
}

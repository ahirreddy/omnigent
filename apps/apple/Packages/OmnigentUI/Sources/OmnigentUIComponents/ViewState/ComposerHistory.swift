/// What the composer's Up and Down arrows and ⌘Return reach beyond the draft. Read on the key
/// press, never while rendering.
public struct ComposerHistoryActions {
  /// The user's earlier prompts in this session, oldest first.
  public var prompts: (@MainActor () -> [String])?
  /// Takes the newest queued message out of the queue to edit it; `nil` when none is queued.
  public var takeLastQueued: (@MainActor () -> String?)?
  /// Sends every queued message now, oldest first, steering the running turn.
  public var sendAllQueued: (@MainActor () -> Void)?

  /// Creates the actions.
  /// - Parameters:
  ///   - prompts: Earlier prompts, oldest first.
  ///   - takeLastQueued: Pulls the newest queued message back into the field.
  ///   - sendAllQueued: Sends the whole queue now.
  public init(
    prompts: (@MainActor () -> [String])? = nil,
    takeLastQueued: (@MainActor () -> String?)? = nil,
    sendAllQueued: (@MainActor () -> Void)? = nil
  ) {
    self.prompts = prompts
    self.takeLastQueued = takeLastQueued
    self.sendAllQueued = sendAllQueued
  }
}

/// Up and Down through earlier prompts, as a shell does: Up from an empty field shows the
/// newest, each Up an older one, Down a newer one and finally the text the field had. Typing
/// ends browsing.
struct PromptRecall: Equatable {
  /// How far back the shown prompt is (0 is the newest); `nil` while not browsing.
  private(set) var offset: Int?
  /// The field's text before browsing.
  private var stash = ""
  /// The prompt last put in the field.
  private var shown: String?

  /// Whether the field shows a recalled prompt the user has not edited.
  func isBrowsing(_ draft: String) -> Bool { offset != nil && draft == shown }

  /// The next older prompt, or `nil` when there is none or the field holds other text.
  mutating func older(draft: String, prompts: [String]) -> String? {
    if !isBrowsing(draft) { self = Self() }
    guard offset != nil || draft.isEmpty else { return nil }
    let next = offset.map { $0 + 1 } ?? 0
    guard next < prompts.count else { return nil }
    if offset == nil { stash = draft }
    offset = next
    shown = prompts[prompts.count - 1 - next]
    return shown
  }

  /// The next newer prompt, then the text the field had; `nil` while not browsing.
  mutating func newer(draft: String, prompts: [String]) -> String? {
    guard isBrowsing(draft), let offset else {
      self = Self()
      return nil
    }
    guard offset > 0, offset - 1 < prompts.count else {
      let original = stash
      self = Self()
      return original
    }
    self.offset = offset - 1
    shown = prompts[prompts.count - offset]
    return shown
  }
}

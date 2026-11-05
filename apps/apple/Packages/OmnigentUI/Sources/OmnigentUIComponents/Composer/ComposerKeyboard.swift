import SwiftUI

/// The composer editor's own keys; they act only while it has focus.
///
/// - Completions: Up and Down move the highlight, Return and Tab apply it, Esc dismisses. A
///   Command-Return still sends.
/// - Return sends (or queues), as ``ComposerSendRules`` says; ⌥⌘Return does the other. ⌘Return
///   (⇧⌘Return with "Send with Command-Return") also sends every queued message now.
/// - ⇧Tab cycles the approval mode.
/// - Up in an empty field first pulls back the newest queued message, then walks earlier
///   prompts; Down walks back.
/// - Esc stops the running turn once nothing else is open.
struct ComposerKeyboard {
  let state: ComposerViewState
  let actions: ComposerActions
  let rules: ComposerSendRules
  let completions: ComposerCompletions
  let commandReturnOwner: CommandReturnOwner?
  @Binding var draft: String
  @Binding var dismissedCompletionsDraft: String?
  @Binding var highlighted: Int
  @Binding var recall: PromptRecall
  @Binding var modeHUD: ApprovalModeOption?
  let perform: (ComposerSendIntent) -> Void

  /// The steer-all chord: ⌘Return, or ⇧⌘Return when ⌘Return is the send chord.
  private func isSendAll(_ press: KeyPress) -> Bool {
    let chord: EventModifiers = state.submitWithCommandReturn ? [.command, .shift] : .command
    return press.modifiers == chord
  }

  /// Applies a completion: a command fills the field; a path becomes a chip when the composer
  /// takes them (else `@path` stays in the text).
  func apply(_ item: ComposerCompletions.Item) {
    if let path = item.mentionPath, let attach = actions.extras.attachMention {
      draft = completions.removingToken()
      attach(path)
    } else {
      draft = completions.applying(item)
    }
  }

  func handleReturn(_ press: KeyPress) -> KeyPress.Result {
    if !press.modifiers.contains(.command), let item = completions.item(at: highlighted) {
      apply(item)
      return .handled
    }
    #if os(iOS)
      // Touch keyboards always insert a newline, as on the web; hardware keyboards use ⌘Return.
      if !press.modifiers.contains(.command) { return .ignored }
    #endif
    // A pending request's Approve owns Command-Return while there is nothing to send.
    if press.modifiers == .command, commandReturnOwner == .approve { return .ignored }
    if press.modifiers.contains(.command), press.modifiers.contains(.option) {
      guard let alternative = rules.alternative else { return .ignored }
      perform(alternative)
      return .handled
    }
    if isSendAll(press), !state.queue.isEmpty, let sendAll = actions.extras.history.sendAllQueued {
      if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        guard let queueDraft = actions.extras.queueDraft else { return .ignored }
        queueDraft()
      }
      sendAll()
      return .handled
    }
    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
    if state.submitWithCommandReturn, !press.modifiers.contains(.command) { return .ignored }
    perform(rules.intent)
    return .handled
  }

  func handleTab(_ press: KeyPress) -> KeyPress.Result {
    if press.modifiers.contains(.shift), let modes = state.approvalModes, let next = modes.next,
      let select = actions.extras.selectApprovalMode
    {
      select(next)
      modeHUD = next
      AccessibilityNotification.Announcement(
        "Approval mode \(next.label)\(next.detail.map { ", \($0)" } ?? "")"
      ).post()
      return .handled
    }
    if !press.modifiers.contains(.shift), let item = completions.item(at: highlighted) {
      apply(item)
      return .handled
    }
    return .ignored
  }

  /// Esc closes the completions first; only then does it stop the turn.
  func handleEscape() -> KeyPress.Result {
    if !completions.items.isEmpty {
      dismissedCompletionsDraft = draft
      return .handled
    }
    guard state.isRunning, let interrupt = actions.interrupt, !state.isStopping else {
      return .ignored
    }
    interrupt()
    return .handled
  }

  func handleArrow(_ press: KeyPress) -> KeyPress.Result {
    guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
    let isUp = press.key == .upArrow
    if !completions.items.isEmpty {
      let count = completions.items.count
      highlighted = (highlighted + (isUp ? count - 1 : 1)) % count
      return .handled
    }
    return isUp ? recallOlder() : recallNewer()
  }

  private func recallOlder() -> KeyPress.Result {
    if draft.isEmpty, !recall.isBrowsing(draft),
      let queued = actions.extras.history.takeLastQueued?()
    {
      draft = queued
      return .handled
    }
    if let prompts = actions.extras.history.prompts?() {
      guard let older = recall.older(draft: draft, prompts: prompts) else { return .ignored }
      draft = older
      return .handled
    }
    guard draft.isEmpty, let previous = actions.extras.recallPrevious?() else { return .ignored }
    draft = previous
    return .handled
  }

  private func recallNewer() -> KeyPress.Result {
    guard let prompts = actions.extras.history.prompts?(),
      let newer = recall.newer(draft: draft, prompts: prompts)
    else { return .ignored }
    draft = newer
    return .handled
  }
}

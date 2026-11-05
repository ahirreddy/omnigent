import SwiftUI

/// What both transcript styles' composers (``ComposerView`` and ``CLIComposer``) share, so the
/// CLI style changes presentation only: completions, command output, picker requests, sending.

extension ComposerCompletions {
  /// The completions offered for `draft`; none once Esc dismissed them for this exact draft.
  static func offered(draft: String, dismissed: String?, state: ComposerViewState) -> Self {
    guard draft != dismissed else { return Self(draft: draft, commands: [], mentions: []) }
    return Self(draft: draft, commands: state.slashCommands, mentions: state.mentionCandidates)
  }

  /// A mention's note under its rows, or the skills note under commands.
  static func note(draft: String, state: ComposerViewState) -> String? {
    isTypingMention(draft) ? state.mentionsNote : state.slashCommandsNote
  }

  /// Why a mention being typed has no rows: the search failed.
  static func failedMentionNote(draft: String, dismissed: String?, state: ComposerViewState)
    -> String?
  {
    guard draft != dismissed, isTypingMention(draft) else { return nil }
    return state.mentionsNote
  }
}

extension ComposerActions {
  /// Sends now (idle or steering) or queues, as `intent` says.
  /// - Returns: Whether anything was sent; `false` while `rules` block the intent.
  @MainActor @discardableResult
  func perform(_ intent: ComposerSendIntent, rules: ComposerSendRules) -> Bool {
    guard rules.blockedReason(for: intent) == nil else { return false }
    if intent == .queue, let queueDraft = extras.queueDraft {
      queueDraft()
    } else {
      send()
    }
    return true
  }
}

/// Over the editor in both styles: a local command's output (`/help`, `/context`), then the
/// `/` and `@` completions, or why a mention search found nothing.
struct ComposerSuggestions: View {
  let state: ComposerViewState
  let actions: ComposerActions
  let draft: String
  let dismissedDraft: String?
  let highlighted: Int
  let apply: (ComposerCompletions.Item) -> Void

  var body: some View {
    let completions = ComposerCompletions.offered(
      draft: draft, dismissed: dismissedDraft, state: state)
    if let notice = state.commandNotice {
      CommandNoticeView(text: notice, dismiss: actions.extras.dismissCommandNotice)
    }
    if !completions.items.isEmpty {
      CompletionList(
        items: completions.items, note: ComposerCompletions.note(draft: draft, state: state),
        highlighted: highlighted, pick: apply)
    } else if let note = ComposerCompletions.failedMentionNote(
      draft: draft, dismissed: dismissedDraft, state: state)
    {
      CompletionList(items: [], note: note) { _ in }
    }
  }
}

/// Opens the pickers a command or menu asks for: `/permissions`'s approval-mode choice and
/// Choose Model (Control-Shift-M), which SwiftUI menus cannot open from code.
private struct ComposerPickerRequests: ViewModifier {
  let state: ComposerViewState
  let actions: ComposerActions
  @State private var showsApprovalPicker = false
  @State private var showsModelPicker = false

  func body(content: Content) -> some View {
    content
      .modifier(
        ApprovalModePicker(
          modes: state.approvalModes, request: state.approvalPickerRequest,
          isPresented: $showsApprovalPicker, select: actions.extras.selectApprovalMode)
      )
      .modifier(
        ModelPicker(
          configuration: state.configuration, request: state.modelPickerRequest,
          isPresented: $showsModelPicker, select: actions.selectModel)
      )
  }
}

extension View {
  /// Answers the composer's picker requests (approval mode, model) in either style.
  func composerPickerRequests(state: ComposerViewState, actions: ComposerActions) -> some View {
    modifier(ComposerPickerRequests(state: state, actions: actions))
  }
}

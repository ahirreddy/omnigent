import PhotosUI
public import SwiftUI
import UniformTypeIdentifiers

/// The composer, laid out like the web's: the queue strip, a context tray (where it runs), then
/// one card with a growing editor and an action row (Add, Host, approval mode; agent, model and
/// effort, Mic, Stop and Send). Return sends and Shift- or Option-Return inserts a newline (or
/// ⌘Return sends with the "Submit with ⌘ + Enter" setting). While the agent works, Send says
/// what it will do ("Send now · steer" or "Queued · after this turn"), ⌥⌘Return does the other,
/// and Stop stays available. ⇧Tab cycles the approval mode with a brief HUD. Esc closes the
/// completions first, then stops the turn; it only acts while the editor has focus. `/` and `@`
/// open completions; Up recalls the previous prompt. Attachments by drop, paste, photo picker or
/// file importer. Disabled and uncertain-delivery states show their reasons.
public struct ComposerView: View {
  @Binding private var draft: String
  private let state: ComposerViewState
  private let actions: ComposerActions
  private let focusRequest: Int
  private let showsContextDetails: Bool

  @State private var isExpanded = false
  @State private var isImporting = false
  @State private var isPickingPhotos = false
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var isDropTargeted = false
  @State private var attachmentError: String?
  @State private var modeHUD: ApprovalModeOption?
  @State private var dismissedCompletionsDraft: String?
  @FocusState private var isFocused: Bool
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.commandReturnOwner) private var commandReturnOwner
  @Environment(\.composerLayoutStyle) private var layout

  /// Creates the composer.
  /// - Parameters:
  ///   - draft: The draft text, owned by the host (drafts survive navigation and fold changes).
  ///   - state: What to render.
  ///   - actions: Host actions.
  ///   - focusRequest: Increment to focus the editor (for example from a menu command).
  ///   - showsContextDetails: Open the execution-context details (playground captures).
  public init(
    draft: Binding<String>, state: ComposerViewState, actions: ComposerActions,
    focusRequest: Int = 0, showsContextDetails: Bool = false
  ) {
    _draft = draft
    self.state = state
    self.actions = actions
    self.focusRequest = focusRequest
    self.showsContextDetails = showsContextDetails
  }

  private var isEditable: Bool {
    if case .unavailable = state.availability { return false }
    return true
  }

  private var rules: ComposerSendRules {
    ComposerSendRules(
      state: state, draft: draft, canQueue: actions.extras.queueDraft != nil, layout: layout)
  }

  /// The touch bar at rest: one row until the user focuses it or there is something to send. A
  /// new session stays open: the agent and model are chosen before the first send.
  private var isCollapsed: Bool {
    layout == .touch && state.purpose == .session && !isFocused && !isExpanded && draft.isEmpty
      && state.attachments.isEmpty
  }

  /// The context tray: whenever the bar is open (always on the Mac and on a new session), or
  /// when it warns that nothing can run there.
  private var showsTray: Bool {
    guard state.tray != nil || state.context != nil else { return false }
    return !isCollapsed || state.context?.unavailableReason != nil
  }

  private var cardPadding: EdgeInsets {
    switch layout {
    case .card:
      EdgeInsets(
        top: Theme.Spacing.medium, leading: Theme.Spacing.medium, bottom: Theme.Spacing.medium,
        trailing: Theme.Spacing.medium)
    case .touch where isCollapsed:
      EdgeInsets(
        top: ComposerBarMetrics.collapsedVerticalPadding,
        leading: ComposerBarMetrics.collapsedHorizontalPadding,
        bottom: ComposerBarMetrics.collapsedVerticalPadding,
        trailing: ComposerBarMetrics.collapsedHorizontalPadding)
    case .touch: ComposerBarMetrics.openPadding
    }
  }

  private var completions: ComposerCompletions {
    guard draft != dismissedCompletionsDraft else {
      return ComposerCompletions(draft: draft, commands: [], mentions: [])
    }
    return ComposerCompletions(
      draft: draft, commands: state.slashCommands, mentions: state.mentionCandidates)
  }

  /// The composer.
  public var body: some View {
    if layout == .touch, state.isReadOnly {
      ReadOnlyComposerBar(reason: state.availability.reason)
    } else {
      composer
    }
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      DeliveryBanner(
        delivery: state.delivery, acknowledge: actions.acknowledgeUncertainDelivery,
        dismiss: actions.dismissDeliveryError)
      if let attachmentError {
        ErrorBanner(
          message: attachmentError, dismiss: { self.attachmentError = nil },
          identifier: "composer-attachment-error")
      }
      if !state.queue.isEmpty {
        QueueStrip(
          queue: state.queue, isRunning: state.isRunning, canSteer: state.canSteer,
          actions: actions.extras)
      }
      if showsTray {
        ComposerTrayView(
          tray: state.tray ?? ComposerTray(), context: state.context, actions: actions.extras,
          showsContextDetails: showsContextDetails
        )
        .tint(.secondary)
      }
      if let notice = state.commandNotice {
        CommandNoticeView(text: notice, dismiss: actions.extras.dismissCommandNotice)
      }
      if !completions.items.isEmpty {
        CompletionList(items: completions.items, note: state.slashCommandsNote) {
          draft = completions.applying($0)
        }
      }
      VStack(alignment: .leading, spacing: isCollapsed ? 0 : Theme.Spacing.small) {
        if let reason = state.availability.reason {
          Label(reason, systemImage: "lock")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.top, Theme.Spacing.extraSmall)
            .accessibilityIdentifier("composer-unavailable")
        }
        if !state.attachments.isEmpty {
          DraftAttachmentStrip(attachments: state.attachments, remove: actions.removeAttachment)
        }
        // The editor keeps one place in the tree whether the bar is collapsed or open, so
        // focusing it (which opens the bar) never recreates it.
        HStack(alignment: .center, spacing: Theme.Spacing.tiny) {
          if isCollapsed { collapsedLeading }
          editor
          if isCollapsed { collapsedTrailing }
        }
        if !isCollapsed { toolbar }
      }
      .padding(cardPadding)
      .composerSurface(isTargeted: isDropTargeted, isFocused: isFocused)
      .overlay(alignment: .top) {
        if let modeHUD {
          ApprovalModeHUD(option: modeHUD)
            .offset(y: -Theme.Spacing.extraLarge)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .allowsHitTesting(false)
        }
      }
      .animation(reduceMotion ? nil : Theme.Motion.feedback, value: modeHUD)
      if let connection = state.connection {
        ConnectionNoticeRow(notice: connection, reconnect: actions.extras.reconnect)
      }
    }
    .padding(.vertical, layout == .touch ? ComposerBarMetrics.outerPadding : Theme.Spacing.medium)
    .readingColumn()
    .dropDestination(for: URL.self, isEnabled: canAttach) { urls, _ in
      add(urls.map { ComposerAttachmentInput.file(url: $0) })
    }
    .modifier(DropTargetTracking(isTargeted: $isDropTargeted))
    .fileImporter(
      isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): add(urls.map { .file(url: $0) })
      case .failure(let error):
        attachmentError = "Could not open the files: \(error.localizedDescription)"
      }
    }
    .photosPicker(
      isPresented: $isPickingPhotos, selection: $photoItems, matching: .any(of: [.images, .videos])
    )
    .onChange(of: photoItems) { _, items in
      guard !items.isEmpty else { return }
      photoItems = []
      Task { await loadPhotos(items) }
    }
    #if os(macOS)
      .onPasteCommand(of: [.fileURL, .image]) { providers in
        Task { await loadProviders(providers) }
      }
    #endif
    .readingPostureFocus($isFocused, focusRequest: focusRequest)
    .task(id: modeHUD) { await clearHUD() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer")
  }

  private var canAttach: Bool {
    isEditable && state.acceptsAttachments && actions.addAttachments != nil
  }

  // MARK: Editor

  private var editor: some View {
    GrowingTextEditor(
      text: $draft, placeholder: rules.placeholder,
      minLines: layout == .touch && !isExpanded ? 1 : (isExpanded ? 10 : 2),
      maxLines: isExpanded ? 28 : (layout == .touch ? ComposerBarMetrics.maxLines : 8),
      identifier: "composer-input"
    )
    .focused($isFocused)
    .disabled(!isEditable)
    .onKeyPress(.return, phases: .down) { press in handleReturn(press) }
    .onKeyPress(.tab, phases: .down) { press in handleTab(press) }
    .onKeyPress(.escape, phases: .down) { _ in handleEscape() }
    .onKeyPress(.upArrow, phases: .down) { _ in handleUpArrow() }
    .accessibilityLabel("Message")
    .accessibilityHint(
      isEditable
        ? (state.submitWithCommandReturn ? "Command-Return sends" : "Return sends")
        : (state.availability.reason ?? "")
    )
  }

  /// Sends now (idle or steering) or queues, as `intent` says.
  private func perform(_ intent: ComposerSendIntent) {
    guard rules.blockedReason(for: intent) == nil else { return }
    dismissedCompletionsDraft = nil
    if intent == .queue, let queueDraft = actions.extras.queueDraft {
      queueDraft()
    } else {
      actions.send()
    }
  }

  // MARK: Attachment loading

  private func add(_ inputs: [ComposerAttachmentInput]) {
    guard !inputs.isEmpty, let addAttachments = actions.addAttachments else { return }
    addAttachments(inputs)
  }

  private func loadPhotos(_ items: [PhotosPickerItem]) async {
    let result = await AttachmentLoading.photos(items)
    add(result.inputs)
    if !result.failures.isEmpty { attachmentError = result.failures.joined(separator: "\n") }
  }

  private func loadProviders(_ providers: [NSItemProvider]) async {
    guard canAttach else { return }
    let result = await AttachmentLoading.providers(providers)
    add(result.inputs)
    if !result.failures.isEmpty { attachmentError = result.failures.joined(separator: "\n") }
  }
}

extension ComposerView {
  // MARK: Keys (the editor's own; they act only while it has focus)

  private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
    if !completions.items.isEmpty, let first = completions.items.first {
      draft = completions.applying(first)
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
    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
    if state.submitWithCommandReturn, !press.modifiers.contains(.command) { return .ignored }
    perform(rules.intent)
    return .handled
  }

  private func handleTab(_ press: KeyPress) -> KeyPress.Result {
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
    if !press.modifiers.contains(.shift), let first = completions.items.first {
      draft = completions.applying(first)
      return .handled
    }
    return .ignored
  }

  /// Esc closes the completions first; only then does it stop the turn.
  private func handleEscape() -> KeyPress.Result {
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

  private func handleUpArrow() -> KeyPress.Result {
    guard draft.isEmpty, let recall = actions.extras.recallPrevious, let previous = recall() else {
      return .ignored
    }
    draft = previous
    return .handled
  }

  /// Hides the ⇧Tab HUD after a moment; a newer switch restarts the wait.
  private func clearHUD() async {
    guard modeHUD != nil else { return }
    do {
      try await Task.sleep(for: .seconds(1.6))
    } catch {
      // Cancelled by a newer switch, which shows its own HUD.
      return
    }
    modeHUD = nil
  }
}

extension ComposerView {
  // MARK: Toolbar

  /// The controls around the editor, for the open row and the collapsed bar.
  private var parts: ComposerControlParts {
    ComposerControlParts(
      state: state, actions: actions, rules: rules,
      hasDraft: !draft.isEmpty || !state.attachments.isEmpty, isEditable: isEditable,
      canAttach: canAttach, layoutWidth: layoutWidth, layout: layout,
      isImporting: $isImporting, isPickingPhotos: $isPickingPhotos, isExpanded: $isExpanded,
      loadProviders: { providers in Task { await loadProviders(providers) } }, perform: perform)
  }

  private var toolbar: some View { parts.toolbar }
  private var collapsedLeading: some View { parts.collapsedLeading }
  private var collapsedTrailing: some View { parts.collapsedTrailing }
}

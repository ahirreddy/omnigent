import PhotosUI
public import SwiftUI
import UniformTypeIdentifiers

/// The composer. On the Mac: the queue strip, then one pill (Add, a growing editor, Stop or
/// Send, Mic) over a row of plain controls (where it runs; model and effort, approval mode,
/// context ring). Touch keeps a context tray over a bar that opens into an action row. Return sends and Shift- or Option-Return inserts a newline (or
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
  @State private var highlightedCompletion = 0
  @State private var recall = PromptRecall()
  @State private var showsApprovalPicker = false
  @State private var showsModelPicker = false
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
      if showsTray, layout == .touch {
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
        CompletionList(
          items: completions.items, note: completionsNote, highlighted: highlightedCompletion,
          mentionFolder: completions.mentionFolder, attachFolder: { keyboard.attach($0) },
          pick: { keyboard.apply($0) })
      } else if let note = failedMentionNote {
        CompletionList(items: [], note: note) { _ in }
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
        if !state.mentions.isEmpty {
          MentionChips(paths: state.mentions, remove: actions.extras.removeMention)
        }
        if layout == .card {
          // One row; the controls stay at the bottom as the text grows.
          HStack(alignment: .bottom, spacing: Theme.Spacing.extraSmall) {
            parts.pillLeading.frame(height: ComposerPillMetrics.row)
            editor
              .padding(.vertical, Theme.Spacing.small - Theme.Spacing.tiny)
              .frame(minHeight: ComposerPillMetrics.row)
            parts.pillTrailing.frame(height: ComposerPillMetrics.row)
          }
        } else {
          // The editor keeps one place in the tree whether the bar is collapsed or open, so
          // focusing it (which opens the bar) never recreates it.
          HStack(alignment: .center, spacing: Theme.Spacing.tiny) {
            if isCollapsed { collapsedLeading }
            editor
            if isCollapsed { collapsedTrailing }
          }
          if !isCollapsed { toolbar }
        }
      }
      .padding(cardPadding)
      .modifier(
        ComposerCardSurface(layout: layout, isTargeted: isDropTargeted, isFocused: isFocused)
      )
      .overlay(alignment: .top) {
        if let modeHUD {
          ApprovalModeHUD(option: modeHUD)
            .offset(y: -Theme.Spacing.extraLarge)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .allowsHitTesting(false)
        }
      }
      .animation(reduceMotion ? nil : Theme.Motion.feedback, value: modeHUD)
      if layout == .card {
        ComposerFooter(
          state: state, actions: actions, isEditable: isEditable,
          showsContextDetails: showsContextDetails)
      }
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
      minLines: isExpanded ? 10 : 1,
      maxLines: isExpanded ? 28 : (layout == .touch ? ComposerBarMetrics.maxLines : 8),
      identifier: "composer-input"
    )
    .focused($isFocused)
    .disabled(!isEditable)
    .onKeyPress(.return, phases: .down) { press in keyboard.handleReturn(press) }
    .onKeyPress(.tab, phases: .down) { press in keyboard.handleTab(press) }
    .onKeyPress(.escape, phases: .down) { _ in keyboard.handleEscape() }
    .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
      keyboard.handleArrow(press)
    }
    .onChange(of: draft) { highlightedCompletion = 0 }
    .accessibilityLabel("Message")
    .accessibilityAction(named: isExpanded ? "Collapse Editor" : "Expand Editor") {
      isExpanded.toggle()
    }
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
  // MARK: Keys

  /// The editor's keys over the current draft, completions and send rules.
  private var keyboard: ComposerKeyboard {
    ComposerKeyboard(
      state: state, actions: actions, rules: rules, completions: completions,
      commandReturnOwner: commandReturnOwner, draft: $draft,
      dismissedCompletionsDraft: $dismissedCompletionsDraft, highlighted: $highlightedCompletion,
      recall: $recall, modeHUD: $modeHUD, perform: perform)
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
      hasDraft: !draft.isEmpty || !state.attachments.isEmpty || !state.mentions.isEmpty,
      isEditable: isEditable,
      canAttach: canAttach, layoutWidth: layoutWidth, layout: layout,
      isImporting: $isImporting, isPickingPhotos: $isPickingPhotos, isExpanded: $isExpanded,
      loadProviders: { providers in Task { await loadProviders(providers) } }, perform: perform,
      pillDictate: actions.extras.dictate ?? startSystemDictation)
  }

  /// Focuses the editor, then starts the Mac's dictation in it; touch dictates through speech
  /// recognition into the draft.
  private func startSystemDictation() {
    #if os(iOS)
      let base = draft
      Task {
        let problem = await SpeechDictation.shared.toggle { words in
          draft = SpeechDictation.appending(words, to: base)
        }
        if let problem { attachmentError = problem }
      }
    #else
      isFocused = true
      Task { @MainActor in
        await Task.yield()
        if !SystemDictation.start() {
          attachmentError =
            "Dictation is unavailable. Turn it on in System Settings \u{203A} Keyboard."
        }
      }
    #endif
  }

  private var toolbar: some View { parts.toolbar }
  private var collapsedLeading: some View { parts.collapsedLeading }
  private var collapsedTrailing: some View { parts.collapsedTrailing }
}

extension ComposerView {
  // MARK: Layout and completions

  private var cardPadding: EdgeInsets {
    switch layout {
    case .card:
      EdgeInsets(
        top: ComposerPillMetrics.padding, leading: ComposerPillMetrics.padding,
        bottom: ComposerPillMetrics.padding, trailing: ComposerPillMetrics.padding)
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

  /// A mention's note under its rows, or the skills note under commands.
  private var completionsNote: String? {
    ComposerCompletions.isTypingMention(draft) ? state.mentionsNote : state.slashCommandsNote
  }

  /// Why a mention being typed has no rows: the search failed.
  private var failedMentionNote: String? {
    guard draft != dismissedCompletionsDraft, ComposerCompletions.isTypingMention(draft) else {
      return nil
    }
    return state.mentionsNote
  }
}

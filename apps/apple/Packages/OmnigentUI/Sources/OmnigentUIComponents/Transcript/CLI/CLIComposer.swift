import PhotosUI
public import SwiftUI
import UniformTypeIdentifiers

/// The composer for the window's transcript style: ``CLIComposer`` or ``ComposerView``.
struct TranscriptComposer: View {
  @Binding var draft: String
  let state: ComposerViewState
  let actions: ComposerActions
  let focusRequest: Int
  @Environment(\.transcriptAppearance) private var appearance

  var body: some View {
    if appearance.isCLI {
      CLIComposer(draft: $draft, state: state, actions: actions, focusRequest: focusRequest)
    } else {
      ComposerView(draft: $draft, state: state, actions: actions, focusRequest: focusRequest)
    }
  }
}

/// The CLI composer: a full-width band with a `›` prompt and a dim placeholder, then a status
/// line (model and effort · directory · branch, warnings on the right). It keeps the composer's
/// rules (``ComposerSendRules``): Return sends or steers or queues, Shift- or Option-Return adds
/// a line, Esc closes completions then stops the turn, Up recalls, ⇧Tab cycles the approval mode.
/// Queued messages, delivery problems, completions and attachments keep their native views.
/// The touch bar's controls (``ComposerControlParts``: Add with photos, files and paste, Mic,
/// Stop and Send) sit at the band's trailing edge: always on touch, in the thumb zone, and on
/// hover or focus on the Mac. Touch never mentions Esc.
public struct CLIComposer: View {
  @Binding private var draft: String
  private let state: ComposerViewState
  private let actions: ComposerActions
  private let focusRequest: Int

  @State private var isImporting = false
  @State private var isPickingPhotos = false
  @State private var isExpanded = false
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var isHovered = false
  @State private var attachmentError: String?
  @State private var dismissedCompletionsDraft: String?
  @State private var showsWarnings = false
  @FocusState private var isFocused: Bool
  @Environment(\.cliPalette) private var palette
  @Environment(\.commandReturnOwner) private var commandReturnOwner
  @Environment(\.composerLayoutStyle) private var layout
  @Environment(\.layoutWidth) private var layoutWidth
  private let size = CLIFontSize()

  /// Creates the composer.
  /// - Parameters:
  ///   - draft: The draft, owned by the host.
  ///   - state: What to render.
  ///   - actions: Host actions.
  ///   - focusRequest: Increment to focus the editor.
  public init(
    draft: Binding<String>, state: ComposerViewState, actions: ComposerActions,
    focusRequest: Int = 0
  ) {
    _draft = draft
    self.state = state
    self.actions = actions
    self.focusRequest = focusRequest
  }

  private var rules: ComposerSendRules {
    ComposerSendRules(
      state: state, draft: draft, canQueue: actions.extras.queueDraft != nil, layout: layout)
  }

  private var isEditable: Bool { state.availability.reason == nil }

  private var completions: ComposerCompletions {
    guard draft != dismissedCompletionsDraft else {
      return ComposerCompletions(draft: draft, commands: [], mentions: [])
    }
    return ComposerCompletions(
      draft: draft, commands: state.slashCommands, mentions: state.mentionCandidates)
  }

  private var showsControls: Bool {
    layout == .touch || isHovered || isFocused
  }

  /// The composer.
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
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
        if !completions.items.isEmpty {
          CompletionList(items: completions.items) { draft = completions.applying($0) }
        }
        if !state.attachments.isEmpty {
          DraftAttachmentStrip(attachments: state.attachments, remove: actions.removeAttachment)
        }
      }
      .transcriptColumn()
      .padding(.bottom, Theme.Spacing.small)
      band
      CLIStatusLine(
        state: state, actions: actions, warnings: warnings, showsWarnings: $showsWarnings
      )
      .transcriptColumn()
      .padding(.vertical, layout == .touch ? Theme.Spacing.extraSmall : Theme.Spacing.small)
    }
    .dropDestination(for: URL.self, isEnabled: canAttach) { urls, _ in
      add(urls.map { ComposerAttachmentInput.file(url: $0) })
    }
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer")
  }

  private var band: some View {
    // Touch centers the text on the 44 pt control row; the Mac keeps the terminal's baseline.
    HStack(
      alignment: layout == .touch ? .center : .firstTextBaseline, spacing: Theme.Spacing.small
    ) {
      editor
      if showsControls { controls }
    }
    .transcriptColumn()
    .padding(
      .vertical, layout == .touch ? ComposerBarMetrics.outerPadding : CLIMetrics.bandPadding
    )
    .background(palette.composerBand.color)
    .onHover { isHovered = $0 }
  }

  /// The text view's own insets, so the measuring copy and the placeholder line up with it.
  #if os(macOS)
    private static let inset = EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5)
  #else
    private static let inset = EdgeInsets(top: 8, leading: 5, bottom: 8, trailing: 5)
  #endif

  private var editor: some View {
    let inset = Self.inset
    let lines = CGFloat(layout == .touch ? ComposerBarMetrics.maxLines : 8)
    return EditorHeightLayout(
      minHeight: size.line + inset.top + inset.bottom,
      maxHeight: size.line * lines + inset.top + inset.bottom
    ) {
      Text(verbatim: draft.isEmpty ? " " : draft + (draft.hasSuffix("\n") ? " " : ""))
        .cliFont()
        .padding(inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hidden()
      TextEditor(text: $draft)
        .cliFont()
        .foregroundStyle(palette.userText.color)
        .scrollContentBackground(.hidden)
        .textEditorStyle(.plain)
        .accessibilityIdentifier("composer-input")
    }
    .overlay(alignment: .topLeading) {
      if draft.isEmpty {
        Text(rules.placeholder)
          .cliFont()
          .foregroundStyle(palette.placeholder.color)
          .padding(inset)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    // The text, not the text view's inset, sits on the column, with the prompt before it.
    .cliMarker(
      Text(verbatim: "\u{203A}").foregroundStyle(palette.prompt.color)
        .padding(.top, inset.top).padding(.leading, inset.leading)
    )
    .padding(.leading, -inset.leading)
    .focused($isFocused)
    .disabled(!isEditable)
    .onKeyPress(.return, phases: .down) { press in handleReturn(press) }
    .onKeyPress(.tab, phases: .down) { press in handleTab(press) }
    .onKeyPress(.escape, phases: .down) { _ in handleEscape() }
    .onKeyPress(.upArrow, phases: .down) { _ in handleUpArrow() }
    .accessibilityLabel("Message")
    .accessibilityHint(
      isEditable
        ? (layout == .touch ? "Send sends" : "Return sends") : (state.availability.reason ?? ""))
  }

  /// The touch bar's controls: Add (files, photos, paste), the Full access warning, Mic, then
  /// Send or Stop.
  private var controls: some View {
    let parts = ComposerControlParts(
      state: state, actions: actions, rules: rules,
      hasDraft: !draft.isEmpty || !state.attachments.isEmpty, isEditable: isEditable,
      canAttach: canAttach, layoutWidth: layoutWidth, layout: layout,
      isImporting: $isImporting, isPickingPhotos: $isPickingPhotos, isExpanded: $isExpanded,
      loadProviders: { providers in Task { await loadProviders(providers) } }, perform: perform)
    return HStack(spacing: Theme.Spacing.tiny) {
      parts.collapsedLeading
      parts.collapsedTrailing
    }
    .foregroundStyle(palette.userText.color)
    .transition(.opacity)
  }

  private var canAttach: Bool {
    isEditable && state.acceptsAttachments && actions.addAttachments != nil
  }

  /// Problems the status line counts, for its warnings popover.
  private var warnings: [String] {
    var warnings: [String] = []
    if let reason = state.availability.reason { warnings.append(reason) }
    if let reason = state.context?.unavailableReason { warnings.append(reason) }
    if let error = state.configuration?.errorMessage { warnings.append(error) }
    if case .failed(let message) = state.delivery { warnings.append(message) }
    for attachment in state.attachments {
      if case .failed(let message) = attachment.state {
        warnings.append("\(attachment.title): \(message)")
      }
    }
    if let attachmentError { warnings.append(attachmentError) }
    return warnings
  }

  private func perform(_ intent: ComposerSendIntent) {
    guard rules.blockedReason(for: intent) == nil else { return }
    dismissedCompletionsDraft = nil
    if intent == .queue, let queueDraft = actions.extras.queueDraft {
      queueDraft()
    } else {
      actions.send()
    }
  }

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

extension CLIComposer {
  // MARK: Keys (the editor's own; they act only while it has focus)

  private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
    if let first = completions.items.first {
      draft = completions.applying(first)
      return .handled
    }
    #if os(iOS)
      if !press.modifiers.contains(.command) { return .ignored }
    #endif
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
    if press.modifiers.contains(.shift), let next = state.approvalModes?.next,
      let select = actions.extras.selectApprovalMode
    {
      select(next)
      AccessibilityNotification.Announcement("Approval mode \(next.label)").post()
      return .handled
    }
    if !press.modifiers.contains(.shift), let first = completions.items.first {
      draft = completions.applying(first)
      return .handled
    }
    return .ignored
  }

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
}

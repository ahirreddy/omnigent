import PhotosUI
public import SwiftUI
import UniformTypeIdentifiers

/// The composer, laid out like the web's: a context tray, the queue strip, then one card with
/// a growing editor and an action row (Add, Host, Permission; model and effort, Mic, Send or
/// Stop). Return sends and Shift- or Option-Return inserts a newline (or ⌘Return sends with the
/// "Submit with ⌘ + Enter" setting); ⇧Tab cycles the approval mode; Esc stops; `/` and `@`
/// open completions; Up recalls the previous prompt. Attachments by drop, paste, photo picker
/// or file importer. Disabled and uncertain-delivery states show their reasons.
public struct ComposerView: View {
  @Binding private var draft: String
  private let state: ComposerViewState
  private let actions: ComposerActions
  private let focusRequest: Int

  @State private var isExpanded = false
  @State private var isImporting = false
  @State private var isPickingPhotos = false
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var isDropTargeted = false
  @State private var attachmentError: String?
  @FocusState private var isFocused: Bool
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Creates the composer.
  /// - Parameters:
  ///   - draft: The draft text, owned by the host (drafts survive navigation and fold changes).
  ///   - state: What to render.
  ///   - actions: Host actions.
  ///   - focusRequest: Increment to focus the editor (for example from a menu command).
  public init(
    draft: Binding<String>, state: ComposerViewState, actions: ComposerActions,
    focusRequest: Int = 0
  ) {
    _draft = draft
    self.state = state
    self.actions = actions
    self.focusRequest = focusRequest
  }

  private var isEditable: Bool {
    if case .unavailable = state.availability { return false }
    return true
  }

  private var sendBlockedReason: String? {
    if let reason = state.availability.reason { return reason }
    switch state.delivery {
    case .sending: return state.purpose == .start ? "Starting session" : "Sending"
    case .uncertain: return "Check the conversation before sending again."
    case .idle, .failed: break
    }
    if state.attachments.contains(where: { if case .failed = $0.state { true } else { false } }) {
      return "Remove the attachments that failed."
    }
    if state.attachments.contains(where: { if case .uploading = $0.state { true } else { false } })
    {
      return "Waiting for attachments to upload."
    }
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state.attachments.isEmpty {
      return state.purpose == .start ? "Enter a message to get started" : "Type a message."
    }
    return nil
  }

  private var completions: ComposerCompletions {
    ComposerCompletions(
      draft: draft, commands: state.slashCommands, mentions: state.mentionCandidates)
  }

  /// The composer.
  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      DeliveryBanner(
        delivery: state.delivery, acknowledge: actions.acknowledgeUncertainDelivery,
        dismiss: actions.dismissDeliveryError)
      if let attachmentError {
        ErrorBanner(
          message: attachmentError, dismiss: { self.attachmentError = nil },
          identifier: "composer-attachment-error")
      }
      if !state.queue.isEmpty {
        QueueStrip(queue: state.queue, actions: actions.extras)
      }
      if let tray = state.tray {
        ComposerTrayView(tray: tray, actions: actions.extras)
          .tint(.secondary)
      }
      if !completions.items.isEmpty {
        CompletionList(items: completions.items) { draft = completions.applying($0) }
      }
      VStack(alignment: .leading, spacing: 6) {
        if let reason = state.availability.reason {
          Label(reason, systemImage: "lock")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .accessibilityIdentifier("composer-unavailable")
        }
        if !state.attachments.isEmpty {
          DraftAttachmentStrip(attachments: state.attachments, remove: actions.removeAttachment)
        }
        editor
        toolbar
      }
      .padding(8)
      .composerSurface(isTargeted: isDropTargeted)
    }
    .padding(.horizontal, layoutWidth == .compact ? 10 : 16)
    .padding(.vertical, 10)
    .frame(minWidth: 0, maxWidth: Theme.transcriptWidth)
    .frame(minWidth: 0, maxWidth: .infinity)
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
    .onChange(of: focusRequest) { _, _ in isFocused = true }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer")
  }

  private var canAttach: Bool {
    isEditable && state.acceptsAttachments && actions.addAttachments != nil
  }

  // MARK: Editor

  private var editor: some View {
    GrowingTextEditor(
      text: $draft, placeholder: state.placeholder, minLines: isExpanded ? 10 : 2,
      maxLines: isExpanded ? 28 : 8, identifier: "composer-input"
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

  private func send() {
    guard sendBlockedReason == nil else { return }
    actions.send()
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
  private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
    if !completions.items.isEmpty, let first = completions.items.first {
      draft = completions.applying(first)
      return .handled
    }
    #if os(iOS)
      // Touch keyboards always insert a newline, as on the web; hardware keyboards use ⌘Return.
      if !press.modifiers.contains(.command) { return .ignored }
    #endif
    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
    if state.submitWithCommandReturn, !press.modifiers.contains(.command) { return .ignored }
    send()
    return .handled
  }

  private func handleTab(_ press: KeyPress) -> KeyPress.Result {
    if press.modifiers.contains(.shift), let modes = state.approvalModes, let next = modes.next,
      let select = actions.extras.selectApprovalMode
    {
      select(next)
      return .handled
    }
    if !press.modifiers.contains(.shift), let first = completions.items.first {
      draft = completions.applying(first)
      return .handled
    }
    return .ignored
  }

  private func handleEscape() -> KeyPress.Result {
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

extension ComposerView {
  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 4) {
      if state.acceptsAttachments, actions.addAttachments != nil {
        AddMenu(
          canAttach: canAttach, extras: actions.extras, chooseFiles: { isImporting = true },
          choosePhotos: { isPickingPhotos = true },
          paste: { providers in Task { await loadProviders(providers) } }
        )
        .tint(.secondary)
      }
      if let hosts = state.hosts {
        HostChip(hosts: hosts, actions: actions.extras)
          .tint(.secondary)
      }
      if let modes = state.approvalModes {
        ApprovalModeChip(
          modes: modes, select: actions.extras.selectApprovalMode,
          isCompact: layoutWidth == .compact
        )
        .disabled(!isEditable)
        .tint(.primary)
      }
      Spacer(minLength: 4)
      if let configuration = state.configuration {
        ConfigurationMenu(
          configuration: configuration, actions: actions, isCompact: layoutWidth == .compact
        )
        .disabled(!isEditable)
        .tint(.primary)
      }
      if let dictate = actions.extras.dictate {
        Button("Dictate", systemImage: "mic", action: dictate)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .keyboardShortcut("v", modifiers: [.command, .option])
          .help("Dictate (Option-Command-V)")
          .disabled(!isEditable)
          .accessibilityIdentifier("composer-mic")
      }
      if layoutWidth == .regular {
        Button {
          withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
        } label: {
          Label(
            isExpanded ? "Collapse Editor" : "Expand Editor",
            systemImage: isExpanded
              ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(isExpanded ? "Collapse the editor" : "Expand the editor")
        .accessibilityIdentifier("composer-expand")
      }
      sendOrStop
    }
  }

  @ViewBuilder private var sendOrStop: some View {
    if state.isRunning, draft.isEmpty {
      Button {
        actions.interrupt?()
      } label: {
        Group {
          if state.isStopping {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
              .accessibilityHidden(true)
          }
        }
        .frame(width: 28, height: 28)
        .background(.primary.opacity(0.12), in: Circle())
        .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut(".", modifiers: .command)
      .disabled(actions.interrupt == nil || state.isStopping)
      .help("Interrupt (Esc)")
      .accessibilityLabel("Interrupt")
      .accessibilityIdentifier("composer-stop")
    } else {
      let blocked = sendBlockedReason
      Button(action: send) {
        Group {
          if state.delivery == .sending {
            ProgressView().controlSize(.small).tint(.white)
          } else {
            Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
              .accessibilityHidden(true)
          }
        }
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(blocked == nil ? Theme.accent : ThemeColor.secondary.opacity(0.4), in: Circle())
        .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(blocked != nil)
      .help(blocked ?? (state.purpose == .start ? "Start session" : "Send"))
      .accessibilityLabel(state.purpose == .start ? "Start session" : "Send")
      .accessibilityValue(blocked ?? "")
      .accessibilityIdentifier("composer-send")
    }
  }
}

import PhotosUI
public import SwiftUI
import UniformTypeIdentifiers

/// The message composer: a growing multi-line editor (Command-Return sends on Mac and with a
/// hardware keyboard), attachments by drop, paste, photo picker or file importer, the model and
/// reasoning picker, Stop while a turn runs, and the disabled and delivery states with their
/// reasons.
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
    case .sending: return "Sending"
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
      return "Type a message."
    }
    return nil
  }

  /// The composer.
  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DeliveryBanner(
        delivery: state.delivery, acknowledge: actions.acknowledgeUncertainDelivery,
        dismiss: actions.dismissDeliveryError)
      if let attachmentError {
        ErrorBanner(message: attachmentError, dismiss: { self.attachmentError = nil })
      }
      VStack(alignment: .leading, spacing: 6) {
        if let reason = state.availability.reason {
          Label(reason, systemImage: "lock")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
    .frame(maxWidth: Theme.transcriptWidth)
    .frame(maxWidth: .infinity)
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
      text: $draft, placeholder: state.placeholder, minLines: isExpanded ? 10 : 1,
      maxLines: isExpanded ? 28 : 10
    )
    .focused($isFocused)
    .disabled(!isEditable)
    .accessibilityLabel("Message")
    .accessibilityHint(isEditable ? "Command-Return sends" : (state.availability.reason ?? ""))
    .accessibilityIdentifier("composer-input")
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 6) {
      if state.acceptsAttachments, actions.addAttachments != nil {
        attachMenu
      }
      if let configuration = state.configuration {
        ConfigurationMenu(configuration: configuration, actions: actions)
          .disabled(!isEditable)
      }
      Spacer(minLength: 4)
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
      sendOrStop
    }
  }

  private var attachMenu: some View {
    Menu {
      Button("Choose Files\u{2026}", systemImage: "doc") { isImporting = true }
      Button("Photos\u{2026}", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
      PasteButton(supportedContentTypes: [.fileURL, .image]) { providers in
        Task { await loadProviders(providers) }
      }
    } label: {
      Label("Add Attachments", systemImage: "paperclip")
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .labelStyle(.iconOnly)
    .fixedSize()
    .disabled(!canAttach)
    .help("Add files or photos")
    .accessibilityIdentifier("composer-attach")
  }

  @ViewBuilder private var sendOrStop: some View {
    if state.isRunning {
      Button {
        actions.interrupt?()
      } label: {
        Group {
          if state.isStopping {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
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
      .help("Stop the agent (Command-Period)")
      .accessibilityLabel("Stop")
      .accessibilityIdentifier("composer-stop")
    }
    let blocked = sendBlockedReason
    Button {
      guard sendBlockedReason == nil else { return }
      actions.send()
    } label: {
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
    .help(blocked ?? "Send (Command-Return)")
    .accessibilityLabel("Send")
    .accessibilityValue(blocked ?? "")
    .accessibilityIdentifier("composer-send")
  }

  // MARK: Delivery

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

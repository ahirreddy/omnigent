import NativeLabCore
import SwiftUI

struct GlassSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var cornerRadius: CGFloat = 26

  @ViewBuilder func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(
        Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: cornerRadius))
    } else if #available(iOS 26.0, *) {
      content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    } else {
      content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
  }
}

struct SessionStatusLabel: View {
  let session: SessionSummary
  let pendingCount: Int

  var body: some View {
    Group {
      if session.isReadOnly {
        Label("Read only", systemImage: "eye").foregroundStyle(.secondary)
      } else if pendingCount > 0 || session.status == .needsResponse {
        Label("Needs response", systemImage: "hand.raised.fill").foregroundStyle(.orange)
      } else if session.status == .running {
        Label("Replying", systemImage: "circle.dotted").foregroundStyle(.green)
      } else if session.configuration?.executionUnavailableReason != nil {
        Label("Not connected", systemImage: "network.slash").foregroundStyle(.secondary)
      } else if session.failureMessage != nil {
        Label("Agent needs attention", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      } else {
        Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.secondary)
      }
    }
    .font(.caption)
  }
}

struct NativeComposer: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var isExpanded = false
  @FocusState private var isFocused: Bool
  let sessionID: String

  private var draft: Binding<String> {
    Binding(
      get: { model.drafts[sessionID] ?? "" },
      set: { model.setDraft($0, for: sessionID) })
  }

  private var isEditable: Bool {
    guard let session = model.snapshot(for: sessionID)?.session else { return false }
    return !session.isReadOnly && !session.isArchived
      && !model.sendingSessionIDs.contains(sessionID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !dynamicTypeSize.isAccessibilitySize,
        let reason = model.composerUnavailableReason(for: sessionID)
      {
        Text(reason)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            Color(uiColor: .systemBackground),
            in: RoundedRectangle(cornerRadius: 12)
          )
          .accessibilityIdentifier("composer-unavailable-\(sessionID)")
      }
      VStack(alignment: .leading, spacing: 4) {
        ConfigurationButton(sessionID: sessionID)
          .padding(.horizontal, 8)
        TextField("Message Omni", text: draft, axis: .vertical)
          .lineLimit(1...5)
          .padding(.horizontal, 8)
          .padding(.top, 8)
          .focused($isFocused)
          .disabled(!isEditable)
          .accessibilityLabel("Message the agent")
          .accessibilityIdentifier("composer-input")
        HStack(spacing: 8) {
          if model.isLive { ComposerAttachmentButton(sessionID: sessionID, enabled: isEditable) }
          Button("Expand composer", systemImage: "arrow.up.left.and.arrow.down.right") {
            isFocused = false
            isExpanded = true
          }
          .labelStyle(.iconOnly)
          .font(.system(size: 18, weight: .medium))
          .frame(width: 44, height: 44)
          .disabled(model.snapshot(for: sessionID)?.session.isReadOnly != false)
          .accessibilityIdentifier("expand-composer")
          Text(
            model.isLive ? (model.streamStatus(for: sessionID) ?? "Connecting…") : "Offline preview"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityIdentifier("conversation-connection-status")
          Spacer(minLength: 0)
          if isFocused {
            Button("Dismiss keyboard", systemImage: "keyboard.chevron.compact.down") {
              isFocused = false
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .medium))
            .frame(width: 44, height: 44)
            .accessibilityIdentifier("dismiss-keyboard")
          }
          ComposerAction(sessionID: sessionID) { isFocused = false }
        }
      }
      .padding(8)
      .modifier(GlassSurface())
    }
    .frame(maxWidth: 720)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
    .accessibilityHidden(isExpanded)
    .fullScreenCover(isPresented: $isExpanded) {
      ExpandedComposer(sessionID: sessionID)
        .environmentObject(model)
    }
  }
}

private struct ComposerAction: View {
  @EnvironmentObject private var model: AppModel
  let sessionID: String
  var identifierPrefix = ""
  var onSent: () -> Void = {}

  private var appearance: HarnessAppearance {
    HarnessAppearance(harness: model.snapshot(for: sessionID)?.session.configuration?.harness)
  }

  var body: some View {
    if model.snapshot(for: sessionID)?.session.status == .running {
      Button {
        Task { await model.stopResponse(in: sessionID) }
      } label: {
        Image(systemName: "stop.fill")
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 44, height: 44)
      }
      .background(.primary.opacity(0.09), in: Circle())
      .disabled(
        model.stoppingSessionIDs.contains(sessionID)
          || model.snapshot(for: sessionID)?.session.isReadOnly == true
      )
      .accessibilityLabel("Stop reply")
      .accessibilityIdentifier("\(identifierPrefix)stop-response")
    } else {
      Button {
        Task {
          await model.sendMessage(in: sessionID)
          if model.errors[sessionID] == nil && (model.drafts[sessionID] ?? "").isEmpty
            && !model.hasAttachments(in: sessionID)
          {
            onSent()
          }
        }
      } label: {
        Group {
          if model.sendingSessionIDs.contains(sessionID) {
            ProgressView().tint(appearance.sendForegroundColor)
          } else {
            Image(systemName: "arrow.up")
              .font(.system(size: 18, weight: .semibold))
          }
        }
        .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .foregroundStyle(appearance.sendForegroundColor)
      .background(appearance.color, in: Circle())
      .opacity(canSend ? 1 : 0.3)
      .disabled(!canSend)
      .accessibilityLabel("Send message")
      .accessibilityValue(appearance.identifier)
      .accessibilityIdentifier("\(identifierPrefix)send-message")
    }
  }

  private var canSend: Bool {
    model.composerUnavailableReason(for: sessionID) == nil
      && (!(model.drafts[sessionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || model.hasAttachments(in: sessionID))
  }
}

private struct ComposerAttachmentButton: View {
  @EnvironmentObject private var model: AppModel
  @State private var isPresented = false
  let sessionID: String
  let enabled: Bool

  private var key: AttachmentDraftKey { model.attachmentKey(for: sessionID) }
  private var count: Int { model.attachmentDrafts.draft(for: key).items.count }

  var body: some View {
    Button {
      isPresented = true
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "paperclip")
        if count > 0 { Text("\(count)").font(.caption.bold()) }
      }
      .frame(minWidth: 44, minHeight: 44)
    }
    .disabled(!enabled)
    .accessibilityLabel(count == 0 ? "Add attachments" : "Review \(count) attachments")
    .accessibilityIdentifier("composer-attachments")
    .sheet(isPresented: $isPresented) {
      NavigationStack {
        ScrollView {
          AttachmentComposerView(
            store: model.attachmentDrafts, key: key, client: model.attachmentClient,
            enabled: enabled
          )
          .padding()
        }
        .navigationTitle("Attachments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { isPresented = false }
          }
        }
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
    .onChange(of: model.connectionGeneration) { _, _ in isPresented = false }
  }
}

private struct ExpandedComposer: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @FocusState private var isFocused: Bool
  @State private var showsDetails = false
  @State private var showsConfiguration = false
  let sessionID: String

  private var isCompact: Bool { verticalSizeClass == .compact }

  private var isEditable: Bool {
    guard let session = model.snapshot(for: sessionID)?.session else { return false }
    return !session.isReadOnly && !session.isArchived
      && !model.sendingSessionIDs.contains(sessionID)
  }

  private var statusSummary: String {
    if model.errors[sessionID] != nil || (!model.isLive && model.storageError != nil) {
      return "Needs attention"
    }
    if model.composerUnavailableReason(for: sessionID) != nil { return "Sending unavailable" }
    return model.isLive ? "Draft kept while app is open" : "Draft on this device"
  }

  private var statusDetails: String {
    [
      model.composerUnavailableReason(for: sessionID), model.errors[sessionID],
      draftStorageDetail,
    ].compactMap { $0 }.joined(separator: " ")
  }

  var body: some View {
    NavigationStack {
      TextEditor(
        text: Binding(
          get: { model.drafts[sessionID] ?? "" },
          set: { model.setDraft($0, for: sessionID) }
        )
      )
      .font(.body)
      .scrollContentBackground(.hidden)
      .background(Color(uiColor: .systemBackground))
      .overlay(alignment: .topLeading) {
        if (model.drafts[sessionID] ?? "").isEmpty {
          Text("Give your idea a little room…")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.top, 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      .focused($isFocused)
      .disabled(!isEditable)
      .accessibilityLabel("Message draft")
      .accessibilityIdentifier("expanded-composer-input")
      .padding(.horizontal, 16)
      .padding(.top, isCompact ? 0 : 8)
      .background(Color(uiColor: .systemBackground))
      .safeAreaInset(edge: .top, spacing: 0) {
        ConfigurationButton(sessionID: sessionID, expanded: true) {
          isFocused = false
          showsConfiguration = true
        }
        .padding(.horizontal, 20)
        .background(Color(uiColor: .systemBackground))
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if !isCompact {
          HStack(spacing: 8) {
            if model.isLive { ComposerAttachmentButton(sessionID: sessionID, enabled: isEditable) }
            detailsButton
            if !dynamicTypeSize.isAccessibilitySize {
              Text(statusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            keyboardButton
            ComposerAction(sessionID: sessionID, identifierPrefix: "expanded-") { dismiss() }
          }
          .padding(8)
          .modifier(GlassSurface())
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
          .background(Color(uiColor: .systemBackground))
        }
      }
      .navigationTitle(isCompact ? "" : "Message")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if isCompact {
          ToolbarItemGroup(placement: .topBarLeading) {
            if model.isLive { ComposerAttachmentButton(sessionID: sessionID, enabled: isEditable) }
            detailsButton
            keyboardButton
            ComposerAction(sessionID: sessionID, identifierPrefix: "expanded-") { dismiss() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("composer-done")
        }
      }
      .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .task { isFocused = isEditable }
      .onChange(of: model.errors[sessionID]) { _, error in
        if error != nil && !showsConfiguration {
          isFocused = false
          showsDetails = true
        }
      }
      .onDisappear { model.flushPersistence() }
    }
    // The draft must never share a translucent backing with the conversation beneath it.
    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    .presentationBackground(Color(uiColor: .systemBackground))
    .sheet(isPresented: $showsConfiguration) {
      SessionConfigurationView(
        sessionID: sessionID,
        generation: model.connectionGeneration,
        configuration: model.snapshot(for: sessionID)?.session.configuration
          ?? SessionConfiguration()
      )
      .environmentObject(model)
    }
    .sheet(isPresented: $showsDetails) {
      NavigationStack {
        Form {
          Section("Conversation") {
            Text(model.snapshot(for: sessionID)?.session.title ?? "Conversation")
          }
          if let reason = model.composerUnavailableReason(for: sessionID) {
            Section("Sending") {
              Text(reason)
                .accessibilityIdentifier("expanded-composer-unavailable")
            }
          }
          if let error = model.errors[sessionID] {
            Section("Error") {
              Text(error).foregroundStyle(.red)
              if model.uncertainDeliverySessionIDs.contains(sessionID) {
                Button("I've checked the conversation — allow another send") {
                  model.allowRetryAfterReview(in: sessionID)
                  showsDetails = false
                }
                .accessibilityIdentifier("expanded-review-uncertain-send")
              }
            }
          }
          Section("Draft storage") {
            Text(draftStorageDetail)
          }
        }
        .navigationTitle("Composer details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { showsDetails = false }
              .accessibilityIdentifier("composer-details-done")
          }
        }
      }
      .presentationBackground(Color(uiColor: .systemBackground))
    }
  }

  private var detailsButton: some View {
    Button {
      isFocused = false
      showsDetails = true
    } label: {
      Image(
        systemName: model.errors[sessionID] != nil || (!model.isLive && model.storageError != nil)
          ? "exclamationmark.triangle" : "info.circle"
      )
      .font(.system(size: 18, weight: .medium))
      .frame(width: 44, height: 44)
    }
    .accessibilityLabel("Composer details")
    .accessibilityValue(statusDetails)
    .accessibilityIdentifier("expanded-composer-details")
  }

  private var draftStorageDetail: String {
    if model.isLive {
      return
        "Your draft is kept separately for this server while the app stays open, including when you close this editor or switch to the sample workspace."
    }
    return model.storageError
      ?? "Your draft stays on this device, including when you close this editor."
  }

  private var keyboardButton: some View {
    Button("Dismiss keyboard", systemImage: "keyboard.chevron.compact.down") {
      isFocused = false
    }
    .labelStyle(.iconOnly)
    .font(.system(size: 18, weight: .medium))
    .frame(width: 44, height: 44)
    .accessibilityIdentifier("expanded-dismiss-keyboard")
  }
}

struct RenameSessionView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @FocusState private var isFocused: Bool
  let session: SessionSummary

  init(session: SessionSummary) {
    self.session = session
    _title = State(initialValue: session.title)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Session name") {
          TextField("Name", text: $title)
            .focused($isFocused)
            .accessibilityIdentifier("rename-input")
        }
        if let error = model.errors[session.id] {
          Text(error).foregroundStyle(.red)
        }
      }
      .navigationTitle("Rename session")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task {
              await model.editSession(session.id, change: .title(title))
              if model.errors[session.id] == nil { dismiss() }
            }
          }
          .disabled(
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || title.count > 120 || model.editingSessionIDs.contains(session.id)
          )
          .accessibilityIdentifier("rename-save")
        }
      }
      .task { isFocused = true }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

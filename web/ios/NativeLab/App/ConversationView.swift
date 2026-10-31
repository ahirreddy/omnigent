import NativeLabCore
import SwiftUI

struct ConversationView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var followsLatest = true
  @State private var isUserScrolling = false
  @State private var showsRename = false
  @State private var showsSessionActivity = false
  @State private var activityConnectionGeneration: UUID?
  @State private var requestFormDrafts: [String: RequestFormDraft] = [:]
  let sessionID: String

  private var snapshot: ConversationSnapshot? {
    model.snapshot(for: sessionID)
  }

  private var failureActivityID: String? {
    guard let snapshot, let failure = snapshot.session.failureMessage else { return nil }
    return snapshot.transcriptMessages.last {
      $0.activity?.isFailure == true && $0.activity?.summary == failure
    }?.id
  }

  private func reviewSessionActivity() {
    activityConnectionGeneration = model.connectionGeneration
    showsSessionActivity = true
  }

  var body: some View {
    Group {
      if let snapshot {
        ScrollViewReader { scroll in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
              if model.isLive && model.hasMoreHistory(for: sessionID) {
                Button {
                  let previousFirstID = snapshot.transcriptMessages.first?.id
                  followsLatest = false
                  Task {
                    await model.loadOlderMessages(sessionID)
                    if let previousFirstID {
                      scroll.scrollTo(previousFirstID, anchor: .top)
                    }
                  }
                } label: {
                  Label("Load older messages", systemImage: "clock.arrow.circlepath")
                }
                .disabled(model.isLoadingHistory(for: sessionID))
                .accessibilityIdentifier("load-older-messages")
              }
              if model.isLive && model.isLoadingHistory(for: sessionID) {
                ProgressView("Loading history…")
                  .accessibilityIdentifier("history-loading")
              }
              HStack {
                Text(snapshot.session.workspace)
                  .font(.caption).foregroundStyle(.secondary)
                Spacer()
                SessionStatusLabel(
                  session: snapshot.session, pendingCount: snapshot.pendingDecisions.count
                )
              }
              if let target = snapshot.eventState?.supersededSessionID, target != sessionID {
                VStack(alignment: .leading, spacing: 8) {
                  Text("This session continued in a new conversation.").font(.callout)
                  Text("Your draft stays here until you choose to copy it.")
                    .font(.caption).foregroundStyle(.secondary)
                  NavigationLink("Open continued session", value: target)
                    .accessibilityIdentifier("session-open-successor")
                }
                .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
              }
              if snapshot.transcriptMessages.isEmpty && snapshot.decisions.isEmpty {
                Text(
                  !snapshot.lifecycleMessages.isEmpty
                    ? "No messages yet. Lifecycle details are in Session activity."
                    : model.isLive
                      ? (model.hasMoreHistory(for: sessionID)
                        ? "No visible messages in this page. Load older messages to continue."
                        : "No visible stored messages.")
                      : "Your conversation starts here."
                )
                .foregroundStyle(.secondary)
              }
              ForEach(snapshot.transcriptMessages) { message in
                MessageView(
                  message: message, sessionID: sessionID,
                  onReviewFailure: message.id == failureActivityID ? reviewSessionActivity : nil
                )
                .id(message.id)
              }
              ForEach(snapshot.decisions) { decision in
                DecisionCard(
                  decision: decision, sessionID: sessionID,
                  isReadOnly: snapshot.session.isReadOnly,
                  formDraft: Binding(
                    get: { requestFormDrafts[decision.id, default: RequestFormDraft()] },
                    set: { requestFormDrafts[decision.id] = $0 })
                )
              }
              if dynamicTypeSize.isAccessibilitySize,
                let reason = model.composerUnavailableReason(for: sessionID)
              {
                Text(reason)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("composer-unavailable-\(sessionID)")
              }
              if let failure = snapshot.session.failureMessage, failureActivityID == nil,
                snapshot.session.configuration?.executionUnavailableReason == nil
              {
                providerFailureView(failure)
              }
              if let error = model.errors[sessionID], error != snapshot.session.failureMessage {
                errorView(error)
              }
              if let notice = model.deliveryNotices[sessionID] {
                Text(notice)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .accessibilityIdentifier("message-delivery-status")
              }
              Color.clear.frame(height: 1).id("conversation-bottom")
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
          }
          // A Group-level identifier also overrides the composer's child identifiers.
          .accessibilityIdentifier("conversation-\(sessionID)")
          .scrollDismissesKeyboard(.interactively)
          .defaultScrollAnchor(.bottom, for: .initialOffset)
          .task(id: snapshot.id) {
            // Live history arrives after navigation; anchor after its first layout.
            await Task.yield()
            scroll.scrollTo("conversation-bottom", anchor: .bottom)
          }
          .onScrollPhaseChange { _, phase in
            isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
          }
          .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 80
          } action: { _, isNearBottom in
            if isUserScrolling {
              followsLatest = isNearBottom
            }
          }
          .onChange(of: snapshot.revision) { _, _ in
            if followsLatest {
              scroll.scrollTo("conversation-bottom", anchor: .bottom)
            }
          }
          .overlay(alignment: .bottomTrailing) {
            if !followsLatest {
              Button("Latest", systemImage: "arrow.down") {
                followsLatest = true
                withAnimation {
                  scroll.scrollTo("conversation-bottom", anchor: .bottom)
                }
              }
              .buttonStyle(.borderedProminent)
              .padding()
              .accessibilityLabel("Jump to latest message")
              .accessibilityIdentifier("jump-to-latest")
            }
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          NativeComposer(sessionID: sessionID)
        }
      } else if let error = model.errors[sessionID] {
        ContentUnavailableView {
          Label("Conversation unavailable", systemImage: "exclamationmark.bubble")
        } description: {
          Text(error)
        } actions: {
          Button("Try again") {
            Task { await model.loadConversation(sessionID) }
          }
        }
      } else {
        ProgressView("Loading conversation…")
      }
    }
    .navigationTitle(snapshot?.session.title ?? "Conversation")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        if let session = snapshot?.session {
          Menu {
            Button("Session activity", systemImage: "list.bullet.rectangle") {
              reviewSessionActivity()
            }
            .accessibilityIdentifier("session-activity")
            if session.canRename {
              Button("Rename", systemImage: "pencil") { showsRename = true }
                .accessibilityIdentifier("session-rename")
            }
            if session.canPin {
              Button(session.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                Task { await model.editSession(sessionID, change: .pinned(!session.isPinned)) }
              }
              .accessibilityIdentifier("session-pin")
            }
            if session.canArchive {
              Button(session.isArchived ? "Restore" : "Archive", systemImage: "archivebox") {
                Task { await model.editSession(sessionID, change: .archived(!session.isArchived)) }
              }
              .accessibilityIdentifier("session-archive")
            }
            ShareLink(
              item: snapshot?.transcriptMessages.map { "\($0.role.rawValue): \($0.text)" }.joined(
                separator: "\n\n") ?? ""
            ) {
              Label("Share transcript", systemImage: "square.and.arrow.up")
            }
          } label: {
            Label("Session options", systemImage: "ellipsis")
          }
          .disabled(model.editingSessionIDs.contains(sessionID))
          .accessibilityIdentifier("session-options")
        }
      }
    }
    .sheet(isPresented: $showsRename) {
      if let session = snapshot?.session {
        RenameSessionView(session: session).environmentObject(model)
      }
    }
    .sheet(
      isPresented: $showsSessionActivity,
      onDismiss: {
        let generation = activityConnectionGeneration
        Task {
          guard generation == model.connectionGeneration else { return }
          await model.loadConversation(sessionID)
        }
      }
    ) {
      NativeSessionActivityView(sessionID: sessionID).environmentObject(model)
    }
    .onDisappear { model.flushPersistence() }
    .task(id: sessionID) { await model.loadConversation(sessionID) }
  }

  private func errorView(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(error, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
      Button("Dismiss") {
        model.clearError(for: sessionID)
      }
      if model.uncertainDeliverySessionIDs.contains(sessionID) {
        Button("I've checked the conversation — allow another send") {
          model.allowRetryAfterReview(in: sessionID)
        }
        .accessibilityIdentifier("review-uncertain-send")
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("session-error-\(sessionID)")
  }

  private func providerFailureView(_ message: String) -> some View {
    NativeFailureNotice(
      message: message, sessionID: sessionID, reviewSession: reviewSessionActivity)
  }
}

private struct MessageView: View {
  let message: ConversationMessage
  let sessionID: String
  var onReviewFailure: (() -> Void)? = nil

  private var author: String {
    if let author = message.author, !author.isEmpty { return author }
    switch message.role {
    case .user: return "You"
    case .assistant: return "Omnigent"
    case .tool: return "Activity"
    }
  }

  var body: some View {
    if let activity = message.activity {
      NativeActivityCard(
        activity: activity, messageID: message.id, isStreaming: message.isStreaming,
        onReviewSession: onReviewFailure,
        failureIdentifier: onReviewFailure == nil ? nil : "provider-failure-\(sessionID)")
      if let agent = message.agent, !agent.isEmpty {
        Text(agent).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("message-agent-\(message.id)")
      }
      ForEach(message.attachments ?? []) { attachment in
        NativeAttachmentView(attachment: attachment, sessionID: sessionID)
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text(author)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        if let agent = message.agent, !agent.isEmpty {
          Text(agent).font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("message-agent-\(message.id)")
        }
        if message.text.isEmpty && message.isStreaming {
          ProgressView("Preparing a reply…")
        } else {
          TranscriptText(text: message.text)
            .accessibilityIdentifier("message-text-\(message.id)")
        }
        if message.isStreaming {
          Label("Replying…", systemImage: "ellipsis")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if message.interrupted == true {
          Label("Stopped", systemImage: "stop.circle")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("message-stopped-\(message.id)")
        }
        ForEach(message.attachments ?? []) { attachment in
          NativeAttachmentView(attachment: attachment, sessionID: sessionID)
        }
      }
      .padding(message.role == .user ? 16 : 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        message.role == .user ? Color.secondary.opacity(0.08) : Color.clear,
        in: RoundedRectangle(cornerRadius: 16)
      )
      .contextMenu {
        Button("Copy message", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = message.text
        }
        ShareLink(item: message.text) { Label("Share message", systemImage: "square.and.arrow.up") }
      }
    }
  }
}

private struct TranscriptText: View {
  let text: String

  private var parts: [String] {
    text.components(separatedBy: "```")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(parts.indices, id: \.self) { index in
        if index.isMultiple(of: 2) {
          Text(markdown(parts[index]))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          ScrollView(.horizontal) {
            Text(parts[index].trimmingCharacters(in: .whitespacesAndNewlines))
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .padding(12)
          }
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }

  private func markdown(_ value: String) -> AttributedString {
    (try? AttributedString(
      markdown: value,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(value)
  }
}

private struct DecisionCard: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsForm = false
  @State private var feedback = ""
  @State private var permissionResponse: DecisionResponse?
  let decision: DecisionRequest
  let sessionID: String
  let isReadOnly: Bool
  @Binding var formDraft: RequestFormDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(decision.title, systemImage: "hand.raised")
        .font(.headline)
      Text(decision.detail)
        .textSelection(.enabled)

      if let response = decision.response {
        Label(responseLabel(response), systemImage: "checkmark.circle")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(responseLabel(response))
          .accessibilityIdentifier("decision-status-\(decision.id)")
      } else if let reason = decision.unsupportedReason {
        Text(reason).font(.callout).foregroundStyle(.secondary)
        if let address = decision.externalURL, let url = URL(string: address),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        {
          Link("Open confirmation page", destination: url)
            .accessibilityIdentifier("request-external-\(decision.id)")
          Text(url.host ?? "").font(.caption).foregroundStyle(.secondary)
        } else {
          Text("Continue this request in the web app.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      } else {
        if decision.form != nil {
          Button("Answer questions", systemImage: "list.bullet.rectangle") { showsForm = true }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("request-form-open-\(decision.id)")
          Button("Decline request") { respond(.decline) }
            .accessibilityIdentifier("request-decline-\(decision.id)")
        } else if decision.options.isEmpty {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { approvalButtons }
            VStack(alignment: .leading, spacing: 12) { approvalButtons }
          }
          if decision.allowAllEdits == true {
            Button(
              decision.isPlanReview == true
                ? "Approve and use auto mode…" : "Approve and allow all edits…"
            ) {
              permissionResponse = .approveAllEdits
            }
            .accessibilityIdentifier("request-allow-all-edits-\(decision.id)")
          }
          if let label = decision.rememberLabel {
            Button("Approve and remember for \(label)…") {
              permissionResponse = .approveRemembering
            }
            .accessibilityIdentifier("request-remember-\(decision.id)")
          }
          if let amendment = decision.execPolicyAmendment, !amendment.isEmpty {
            Button("Approve and allow this command policy…") {
              permissionResponse = .approveCommandPolicy(amendment)
            }
            .accessibilityIdentifier("request-command-policy-\(decision.id)")
          }
          if decision.isPlanReview == true {
            TextField("Feedback for a revised plan", text: $feedback, axis: .vertical)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("request-plan-feedback-\(decision.id)")
            Button("Reject with feedback") { respond(.declineWithFeedback(feedback)) }
              .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("request-plan-reject-\(decision.id)")
          }
        } else {
          ForEach(decision.options.indices, id: \.self) { index in
            Button {
              respond(.answer(decision.options[index]))
            } label: {
              Text(decision.options[index])
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("question-option-\(decision.id)-\(index)")
          }
        }
        if model.isResolving(decision) {
          ProgressView("Sending response…")
        } else if isReadOnly {
          Text("Read-only access does not allow responding to this request.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    .disabled(isReadOnly || model.isResolving(decision))
    .sheet(isPresented: $showsForm) {
      if let form = decision.form {
        RequestFormView(
          form: form, title: decision.title, requestID: decision.id, draft: $formDraft,
          isSubmitting: model.isResolving(decision), errorMessage: model.errors[sessionID]
        ) { respond(.form($0)) }
        .disabled(isReadOnly || decision.response != nil)
      }
    }
    .onChange(of: decision.response) { _, response in
      if response != nil { showsForm = false }
    }
    .alert(
      "Change approval behavior for this session?",
      isPresented: Binding(
        get: { permissionResponse != nil }, set: { if !$0 { permissionResponse = nil } }
      )
    ) {
      Button("Approve and apply this change") {
        if let response = permissionResponse { respond(response) }
        permissionResponse = nil
      }
      Button("Cancel", role: .cancel) { permissionResponse = nil }
    } message: {
      Text(
        "This can allow future actions without asking again. The change applies on the server, not just this device."
      )
    }
  }

  @ViewBuilder
  private var approvalButtons: some View {
    Button("Approve") { respond(.approve) }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("approval-approve-\(decision.id)")
    Button("Decline") { respond(.decline) }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("approval-decline-\(decision.id)")
  }

  private func respond(_ response: DecisionResponse) {
    Task {
      await model.resolve(decision, response: response, displayedIn: sessionID)
    }
  }

  private func responseLabel(_ response: DecisionResponse) -> String {
    switch response {
    case .approve: return "Approved"
    case .decline: return "Declined"
    case .answer(let answer): return "Answered: \(answer)"
    case .form: return "Answers submitted"
    case .approveAllEdits: return "Approved with updated permission mode"
    case .approveRemembering: return "Approved with remembered permission"
    case .approveCommandPolicy: return "Approved with command policy amendment"
    case .declineWithFeedback: return "Rejected with feedback"
    }
  }
}

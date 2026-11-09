import SwiftUI

/// What will actually happen, first: the command with its directory, the files with their line
/// counts, the plan, Antigravity's action, or the request's own text.
struct DecisionPayloadView: View {
  let card: DecisionCard
  @Environment(\.layoutWidth) private var layoutWidth

  private var permissions: PermissionOptions { card.permissions }
  private var paragraphs: [String] { DecisionSummary.paragraphs(card.detail) }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      if let plan = permissions.plan {
        BoundedScrollView(maxHeight: 320) {
          MarkdownView(plan)
            .padding(Theme.Spacing.medium)
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .accessibilityLabel("Proposed plan")
      } else {
        if let lede { InlineMarkdownText(lede).font(.callout) }
        if let command = permissions.command { CommandPayload(command: command) }
        if !permissions.files.isEmpty { FileChangeList(files: permissions.files) }
        if let agy = permissions.antigravity { AntigravityPayload(permission: agy) }
        if let preview { PreviewBlock(text: preview) }
      }
      if !permissions.permissionDirectories.isEmpty {
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          Text("Directories offered for this session").font(.caption).foregroundStyle(.secondary)
          ForEach(permissions.permissionDirectories, id: \.self) { directory in
            Text(directory).font(DecisionCode.font(layoutWidth)).textSelection(.enabled)
          }
        }
      }
    }
  }

  /// The request's message. Structured payloads show their own fields, so the core's joined
  /// detail is reduced to the message the agent wrote, when it has one.
  private var lede: String? {
    if case .approval = card.kind, let message = card.message { return message }
    guard let first = paragraphs.first else { return nil }
    if let command = permissions.command { return first == command.command ? nil : first }
    if let action = permissions.antigravity?.actionDescription {
      return first == action ? nil : first
    }
    switch card.kind {
    case .approval: return first
    case .choice, .form, .unsupported: return card.detail
    }
  }

  /// The rest of a plain approval's detail (for example the gated tool's input), monospaced.
  private var preview: String? {
    guard case .approval = card.kind, permissions.command == nil, permissions.antigravity == nil
    else { return nil }
    if card.message != nil || card.toolInput != nil { return card.toolInput }
    let rest = paragraphs.dropFirst()
    return rest.isEmpty ? nil : rest.joined(separator: "\n\n")
  }
}

/// Inline Markdown (bold tool names, code spans) on one text run.
struct InlineMarkdownText: View {
  let markdown: String

  init(_ markdown: String) { self.markdown = markdown }

  var body: some View {
    Text(attributed)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var attributed: AttributedString { Self.attributed(markdown) }

  /// The text with its inline Markdown applied.
  static func attributed(
    _ markdown: String,
    parse: (String) throws -> AttributedString = {
      try AttributedString(
        markdown: $0, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
  ) -> AttributedString {
    do {
      return try parse(markdown)
    } catch {
      // Text that is not valid Markdown is shown exactly as the agent wrote it.
      return AttributedString(markdown)
    }
  }
}

/// `$ command`, monospaced and selectable, with the working directory and reason below.
struct CommandPayload: View {
  let command: CommandApproval
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    let code = DecisionCode.font(layoutWidth)
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
        Text(verbatim: "$ \(command.command)")
          .font(code)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        CopyButton(text: command.command, label: "Copy command")
      }
      .padding(.leading, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.extraSmall)
      .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Command: \(command.command)")
      if let cwd = command.cwd {
        Label {
          Text(verbatim: cwd).font(code).textSelection(.enabled)
        } icon: {
          Image(systemName: "folder")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("In \(cwd)")
      }
      if let reason = command.reason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// The files an edit would change, basename first with the directory under it, what happens to
/// it ("new file", "deleted", "rewritten") and "+N −M" when known, leaving zero counts out.
struct FileChangeList: View {
  let files: [DecisionFileChange]
  @Environment(\.layoutWidth) private var layoutWidth

  static func symbol(_ kind: DecisionFileChange.Kind?) -> String {
    switch kind {
    case .create: "doc.badge.plus"
    case .delete: "trash"
    case .modify, .write, nil: "doc.text"
    }
  }

  static func kindLabel(_ kind: DecisionFileChange.Kind?) -> String? {
    switch kind {
    case .create: "new file"
    case .delete: "deleted"
    case .write: "rewritten"
    case .modify, nil: nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
        if index > 0 { Divider() }
        let path = DecisionPath(file.path)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
          Image(systemName: Self.symbol(file.kind))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            Text(verbatim: path.name)
              .font(DecisionCode.font(layoutWidth))
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.middle)
            if let directory = path.directory {
              Text(verbatim: directory)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(file.path)
          if let kind = Self.kindLabel(file.kind) {
            Text(kind).foregroundStyle(.secondary)
          }
          if let added = file.shownAdded {
            Text(verbatim: "+\(added)").foregroundStyle(ThemeColor.diffAdded)
          }
          if let removed = file.shownRemoved {
            Text(verbatim: "\u{2212}\(removed)").foregroundStyle(ThemeColor.diffRemoved)
          }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          [
            file.path, Self.kindLabel(file.kind), file.shownAdded.map { "\($0) lines added" },
            file.shownRemoved.map { "\($0) removed" },
          ]
          .compactMap(\.self).joined(separator: ", "))
      }
    }
    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
  }
}

/// Antigravity's action and the command prefix it offers to always allow.
struct AntigravityPayload: View {
  let permission: AntigravityPermission
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if let action = permission.actionDescription {
        Text(action).font(.callout).textSelection(.enabled)
      }
      if let pattern = permission.alwaysAllowPattern {
        LabeledContent("Always-allow pattern") {
          Text(verbatim: pattern).font(DecisionCode.font(layoutWidth)).textSelection(.enabled)
        }
        .font(.caption)
      }
    }
  }
}

/// A plain approval's raw payload (for example `Edit({...})`), bounded and monospaced.
/// Approve (the one pink button, with the Command-Return hint when it owns the shortcut), Reject,
/// "Tell the agent instead", and "More approval options…" for the widening choices.
struct ApprovalControls: View {
  let card: DecisionCard
  let availability: DecisionAvailability
  let canRespond: Bool
  @Binding var draft: FormDraft
  let act: (DecisionResponse) -> Void
  @Environment(\.decisionIDPrefix) private var idPrefix
  @Environment(\.decisionShortcutCardID) private var shortcutCardID
  @Environment(\.decisionShortcutIsLive) private var shortcutIsLive
  @FocusState private var feedbackFocused: Bool

  private var isPlan: Bool { card.permissions.plan != nil }
  /// Plan cards keep the identifiers they had before v2.
  private func id(_ approval: String, plan: String) -> String {
    "\(idPrefix)\(isPlan ? "decision-plan-\(plan)" : "approval-\(approval)")-\(card.id)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Theme.Spacing.small) {
          buttons
          Spacer(minLength: 0)
          moreMenu
        }
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          HStack(spacing: Theme.Spacing.small) { buttons }
          moreMenu
        }
      }
      if draft.isComposingFeedback { feedbackComposer }
    }
  }

  @ViewBuilder private var buttons: some View {
    if let title = availability.approveTitle {
      ApproveButton(
        title: title, cardID: card.id, isEnabled: canRespond,
        ownsShortcut: shortcutIsLive && shortcutCardID == card.id && !draft.isComposingFeedback,
        identifier: id("approve", plan: "approve"),
        isProminent: shortcutCardID == nil || shortcutCardID == card.id
      ) { act(.approve) }
    }
    if availability.canReject {
      Button {
        act(.decline)
      } label: {
        Text("Reject").frame(minWidth: 64)
      }
      .buttonStyle(.bordered)
      .tint(.primary)
      .controlSize(.large)
      .disabled(!canRespond)
      .accessibilityIdentifier(id("decline", plan: "decline"))
    }
    if availability.canTellAgent, !draft.isComposingFeedback {
      Button("Tell the agent instead") {
        draft.isComposingFeedback = true
        feedbackFocused = true
      }
      .buttonStyle(.borderless)
      .tint(.primary)
      .controlSize(.large)
      .disabled(!canRespond)
      .accessibilityHint("Rejects this request and sends your reply to the agent")
      .accessibilityIdentifier(id("tell-agent", plan: "tell-agent"))
    }
  }

  @ViewBuilder private var moreMenu: some View {
    if !availability.widening.isEmpty {
      Menu {
        ForEach(Array(availability.widening.enumerated()), id: \.element) { index, choice in
          Button {
            act(choice.response)
          } label: {
            Label(choice.label, systemImage: choice.systemImage)
          }
          .accessibilityIdentifier("\(idPrefix)approval-permission-\(card.id)-\(index)")
        }
      } label: {
        Text("More approval options\u{2026}")
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .tint(.secondary)
      .fixedSize()
      .disabled(!canRespond)
      .accessibilityHint("Approves and changes approval behavior; asks for confirmation first")
      .accessibilityIdentifier("\(idPrefix)approval-more-\(card.id)")
    }
  }

  private var feedbackComposer: some View {
    let response = DecisionAvailability.feedbackResponse(for: card, text: draft.feedback)
    return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      TextField(
        isPlan ? "What should change about the plan?" : "What should the agent do instead?",
        text: $draft.feedback, axis: .vertical
      )
      .lineLimit(1...5)
      .textFieldStyle(.roundedBorder)
      .focused($feedbackFocused)
      .disabled(!canRespond)
      .onSubmit {
        if let response { act(response) }
      }
      .accessibilityIdentifier(id("feedback", plan: "feedback"))
      HStack(spacing: Theme.Spacing.small) {
        Button("Reject and send") {
          if let response { act(response) }
        }
        .buttonStyle(.bordered)
        .tint(.primary)
        .disabled(!canRespond || response == nil)
        .accessibilityHint("Rejects this request and sends your reply to the agent")
        .accessibilityIdentifier(id("feedback-send", plan: "reject"))
        Button("Cancel") {
          draft.isComposingFeedback = false
          feedbackFocused = false
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
        .accessibilityIdentifier(id("feedback-cancel", plan: "feedback-cancel"))
      }
    }
  }
}

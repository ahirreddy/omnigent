import SwiftUI

/// Composer: the card and touch bar, the queue, approval modes, execution context, delivery,
/// attachments and completions.
enum ComposerCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .composer, "composer", "Composer",
        summary: "The message composer in every state the session page can put it in.",
        systemImage: "text.cursor", canvas: .column(width: 760),
        keywords: ["send", "draft", "attachments", "unavailable", "uncertain"],
        states: PreviewData.composerStates.map { sample in
          CatalogState(slug(sample.title), sample.title) {
            CatalogStack {
              ComposerView(
                draft: .constant(sample.draft), state: sample.state,
                actions: GalleryActions.composer)
            }
          }
        } + [
          CatalogState("disabled", "Read only", note: "A shared session the user cannot write to.")
          {
            CatalogStack {
              ComposerView(
                draft: .constant(""), state: ComposerSamples.readOnly,
                actions: GalleryActions.composer)
            }
          }
        ],
        live: { _ in AnyView(NavigationStack { ComposerPlayground() }) }),
      .component(
        .composer, "touch-bar", "Touch Bar",
        summary: "The iPhone composer: a 48 pt bar that opens into the editor.",
        systemImage: "iphone", canvas: .column(width: 390),
        keywords: ["iphone", "compact", "stop"],
        states: [
          touch("idle", "Idle", draft: "", state: ComposerSamples.idle),
          touch(
            "running", "Running: Stop in reach", draft: "", state: ComposerSamples.runningEmpty),
          touch(
            "steer", "Running with a draft: Send steers", draft: "List risks",
            state: ComposerSamples.runningEmpty),
          touch(
            "open", "Open with a draft", draft: "Summarize the questions",
            state: ComposerSamples.idle),
        ]),
      .component(
        .composer, "queue", "Queue Strip",
        summary: "Follow-ups queued behind the running turn: queued, sending, waiting and failed.",
        systemImage: "list.number", canvas: .column(width: 720),
        keywords: ["queue", "steer", "follow-up"],
        states: [
          CatalogState("queued", "Queued") { queue(ComposerSamples.running.queue) },
          CatalogState("states", "Every message state") { queue(ComposerSamples.queueStates) },
          CatalogState("idle", "After the turn", note: "The turn ended; queued items send next.") {
            queue(ComposerSamples.running.queue, isRunning: false)
          },
        ]),
      .component(
        .composer, "approval-mode", "Approval Mode",
        summary: "The approval-mode chip and the Shift-Tab HUD for Codex and Claude Code.",
        systemImage: "shield.lefthalf.filled", canvas: .column(width: 520),
        keywords: ["permissions", "auto", "hud"],
        states: [
          CatalogState("codex", "Codex chip") {
            CatalogStack { ApprovalModeChip(modes: ComposerSamples.codexModes(), select: { _ in }) }
          },
          CatalogState("claude", "Claude Code chip") {
            CatalogStack {
              ApprovalModeChip(modes: ComposerSamples.claudeModes(), select: { _ in })
            }
          },
          CatalogState("full-access", "Full access", note: "The riskiest mode is never pink.") {
            CatalogStack {
              ApprovalModeChip(
                modes: ComposerSamples.codexModes(selected: "full-access"), select: { _ in })
            }
          },
          CatalogState("hud", "Shift-Tab HUD") {
            CatalogStack { ApprovalModeHUD(option: ComposerSamples.codexModes().options[2]) }
          },
        ]),
      .component(
        .composer, "context", "Execution Context",
        summary: "Where the agent runs: host, workspace and branch, online or offline.",
        systemImage: "desktopcomputer", canvas: .column(width: 560),
        keywords: ["host", "branch", "offline"],
        states: [
          CatalogState("row", "Row") {
            CatalogStack { ExecutionContextRow(context: ComposerSamples.context) }
          },
          CatalogState("details", "Details") {
            CatalogStack {
              ExecutionContextDetails(context: ComposerSamples.context)
                .cardSurface(cornerRadius: Theme.Radius.large)
            }
          },
          CatalogState("offline", "Offline") {
            CatalogStack {
              ExecutionContextDetails(
                context: ComposerSamples.offline.context ?? ComposerSamples.context
              )
              .cardSurface(cornerRadius: Theme.Radius.large)
            }
          },
        ]),
      .component(
        .composer, "delivery", "Delivery Banner",
        summary: "A send in flight, a send that may not have arrived, and a failed send.",
        systemImage: "paperplane", canvas: .column(width: 640),
        keywords: ["uncertain", "failed", "sending"],
        states: [
          delivery("sending", "Sending", .sending),
          delivery(
            "uncertain", "Uncertain",
            .uncertain(message: "The connection dropped while sending. Check the conversation.")),
          delivery(
            "failed", "Failed", .failed(message: "Could not send: the server returned 503.")),
        ]),
      .component(
        .composer, "attachments", "Draft Attachments",
        summary: "Attachments on the draft: ready, uploading and failed.",
        systemImage: "paperclip", canvas: .column(width: 640),
        keywords: ["upload", "image", "file"],
        states: [
          CatalogState("strip", "Strip") {
            CatalogStack {
              DraftAttachmentStrip(
                attachments: PreviewData.composerAttachments.attachments, remove: { _ in })
            }
          }
        ]),
      .component(
        .composer, "completions", "Completions",
        summary: "Slash commands and @-mentions offered while typing.",
        systemImage: "slash.circle", canvas: .column(width: 520),
        keywords: ["slash", "mention", "autocomplete"],
        states: [
          completion("slash", "Slash commands", draft: "/"),
          completion("mention", "Mentions", draft: "Look at @"),
        ]),
      .component(
        .composer, "chips", "Model and Host Chips",
        summary: "The model, effort and agent menu, and the host chip.",
        systemImage: "cpu", canvas: .column(width: 560),
        keywords: ["model", "effort", "agent", "host"],
        states: [
          CatalogState("chips", "Chips") {
            CatalogStack {
              HStack(spacing: Theme.Spacing.small) {
                ConfigurationMenu(
                  configuration: PreviewData.configuration, actions: GalleryActions.composer)
                if let hosts = PreviewData.startComposer.hosts {
                  HostChip(hosts: hosts, actions: ComposerExtraActions())
                }
              }
            }
          }
        ]),
    ]
  }

  /// A file-name-safe id from a title.
  static func slug(_ title: String) -> String {
    title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
      .reduce(into: "") { result, character in
        if character != "-" || result.last != "-" { result.append(character) }
      }
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private static func touch(
    _ id: String, _ title: String, draft: String, state: ComposerViewState
  ) -> CatalogState {
    CatalogState(id, title) {
      ComposerView(draft: .constant(draft), state: state, actions: GalleryActions.composer)
        .padding(.vertical, Theme.Spacing.large)
        .layoutWidth(.compact)
        .environment(\.composerLayoutStyle, .touch)
    }
  }

  private static func queue(_ messages: [QueuedMessage], isRunning: Bool = true) -> some View {
    CatalogStack {
      QueueStrip(
        queue: messages, isRunning: isRunning, canSteer: true, actions: ComposerExtraActions())
    }
  }

  private static func delivery(_ id: String, _ title: String, _ delivery: DeliveryState)
    -> CatalogState
  {
    CatalogState(id, title) {
      CatalogStack { DeliveryBanner(delivery: delivery, acknowledge: {}, dismiss: {}) }
    }
  }

  private static func completion(_ id: String, _ title: String, draft: String) -> CatalogState {
    CatalogState(id, title) {
      CatalogStack {
        CompletionList(
          items: ComposerCompletions(
            draft: draft, commands: PreviewData.slashCommands, mentions: PreviewData.mentionPaths
          ).items, pick: { _ in }
        )
        .cardSurface(cornerRadius: Theme.Radius.medium)
      }
    }
  }
}

extension ComposerSamples {
  /// Running with nothing queued.
  static var runningEmpty: ComposerViewState {
    var state = running
    state.queue = []
    return state
  }

  /// A queue with one message in each state.
  static var queueStates: [QueuedMessage] {
    [
      QueuedMessage(id: "q-queued", text: "Then update the changelog"),
      QueuedMessage(id: "q-sending", text: "Run the auth tests only", state: .sending),
      QueuedMessage(id: "q-waiting", text: "Push the branch", state: .waitingForHost),
      QueuedMessage(
        id: "q-failed", text: "Open a pull request",
        state: .failed(message: "The host went offline.")),
    ]
  }

  /// A shared session the user can read but not write to.
  static var readOnly: ComposerViewState {
    var state = idle
    state.availability = .unavailable(reason: "This session is shared with you as a viewer.")
    state.isReadOnly = true
    return state
  }
}

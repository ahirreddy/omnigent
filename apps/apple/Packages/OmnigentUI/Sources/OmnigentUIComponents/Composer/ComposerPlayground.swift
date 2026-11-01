import Foundation
import SwiftUI

/// The composer's states side by side, interactive: idle, running with a queue, the approval
/// modes (menu contents and the ⇧Tab HUD), the execution-context details and the new-session
/// page, and the iPhone touch bar. `OMNIGENT_PLAYGROUND_COMPOSER=<idle|running|modes|context|
/// newSession|touch>` picks the page.
struct ComposerPlayground: View {
  enum Page: String, CaseIterable, Identifiable {
    case idle, running, modes, context, newSession, touch
    var id: Self { self }

    var title: String {
      switch self {
      case .idle: "Idle"
      case .running: "Running"
      case .modes: "Approval modes"
      case .context: "Context"
      case .newSession: "New session"
      case .touch: "iPhone bar"
      }
    }
  }

  @State private var page =
    ProcessInfo.processInfo.environment["OMNIGENT_PLAYGROUND_COMPOSER"].flatMap(
      Page.init(rawValue:))
    ?? .running
  @State private var composer = ComposerSamples.running
  @State private var start = ComposerSamples.start
  @State private var draft = "Use the new token cache in the refresh path"
  @State private var startDraft = ""
  @State private var nextID = 3

  var body: some View {
    VStack(spacing: 0) {
      Picker("Page", selection: $page) {
        ForEach(Page.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 560)
      .padding(Theme.Spacing.medium)
      .accessibilityIdentifier("composer-playground-page")
      Divider()
      content
    }
    .themeCanvas()
    .navigationTitle("Composer")
    .onChange(of: page, initial: true) { _, page in load(page) }
  }

  @ViewBuilder private var content: some View {
    switch page {
    case .idle, .running:
      ScrollView {
        VStack(spacing: Theme.Spacing.section) {
          Spacer(minLength: Theme.Spacing.section)
          ComposerView(draft: $draft, state: composer, actions: actions)
        }
      }
    case .modes:
      ScrollView {
        VStack(spacing: Theme.Spacing.extraLarge) {
          ModeMenuSample(title: "Codex", modes: ComposerSamples.codexModes())
          ModeMenuSample(title: "Claude Code", modes: ComposerSamples.claudeModes())
          VStack(spacing: Theme.Spacing.small) {
            Text("After \u{21E7}Tab").font(.caption).foregroundStyle(.secondary)
            ApprovalModeHUD(option: ComposerSamples.codexModes().options[2])
          }
          ComposerView(draft: .constant(""), state: ComposerSamples.fullAccess, actions: actions)
        }
        .padding(.vertical, Theme.Spacing.extraLarge)
      }
    case .context:
      ScrollView {
        VStack(spacing: Theme.Spacing.extraLarge) {
          ExecutionContextDetails(context: ComposerSamples.context)
            .cardSurface(cornerRadius: Theme.Radius.large)
          ExecutionContextDetails(
            context: ComposerSamples.offline.context ?? ComposerSamples.context
          )
          .cardSurface(cornerRadius: Theme.Radius.large)
          ComposerView(draft: $draft, state: ComposerSamples.offline, actions: actions)
        }
        .padding(.vertical, Theme.Spacing.extraLarge)
      }
    case .newSession:
      NewSessionPage(draft: $startDraft, composer: start, actions: startActions)
    case .touch:
      ScrollView { TouchBarSamples(actions: actions) }
    }
  }

  private func load(_ page: Page) {
    switch page {
    case .idle: composer = ComposerSamples.idle
    case .running, .modes, .context, .touch: composer = ComposerSamples.running
    case .newSession: start = ComposerSamples.start
    }
  }

  private var actions: ComposerActions {
    ComposerActions(
      send: {
        guard !draft.isEmpty else { return }
        if !composer.isRunning { composer.isRunning = true }
        draft = ""
      },
      interrupt: { composer.isRunning = false },
      selectModel: { composer.configuration?.selectedModelId = $0 },
      selectEffort: { composer.configuration?.selectedEffort = $0 },
      selectAgent: { composer.configuration?.selectedAgentId = $0 },
      extras: ComposerExtraActions(
        selectApprovalMode: { composer.approvalModes?.selectedID = $0.id },
        editQueued: { message, text in
          guard let index = composer.queue.firstIndex(where: { $0.id == message.id }) else {
            return
          }
          composer.queue[index].text = text
          composer.queue[index].state = .queued
        },
        sendQueuedNow: { message in composer.queue.removeAll { $0.id == message.id } },
        removeQueued: { message in composer.queue.removeAll { $0.id == message.id } },
        queueDraft: {
          composer.queue.append(QueuedMessage(id: "q\(nextID)", text: draft))
          nextID += 1
          draft = ""
        }))
  }

  private var startActions: ComposerActions {
    ComposerActions(
      send: { startDraft = "" },
      selectModel: { start.configuration?.selectedModelId = $0 },
      selectAgent: { start.configuration?.selectedAgentId = $0 },
      extras: ComposerExtraActions(
        selectHost: { host in
          start = host.isOnline ? ComposerSamples.start : ComposerSamples.startUnavailable
          start.hosts?.selectedID = host.id
        },
        selectDirectory: { start.tray?.directory = $0 }, openFolder: {}))
  }
}

/// The touch bar at iPhone width: idle, running with Stop in reach, a draft while running (Send
/// steers, Stop stays), and open with the controls row.
private struct TouchBarSamples: View {
  let actions: ComposerActions

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      sample("Idle", draft: "", state: ComposerSamples.idle)
      sample("Running: Stop in reach", draft: "", state: running)
      sample("Running with a draft: Send steers, Stop stays", draft: "List risks", state: running)
      sample("Open while typing", draft: "Summarize the questions", state: ComposerSamples.idle)
    }
    .padding(.vertical, Theme.Spacing.extraLarge)
    .frame(width: 390)
    .frame(maxWidth: .infinity)
    .layoutWidth(.compact)
    .environment(\.composerLayoutStyle, .touch)
  }

  private var running: ComposerViewState {
    var state = ComposerSamples.running
    state.queue = []
    return state
  }

  private func sample(_ title: String, draft: String, state: ComposerViewState) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
      ComposerView(draft: .constant(draft), state: state, actions: actions)
    }
  }
}

/// The approval-mode menu's contents, drawn in place so captures show them (a real menu only
/// draws while open).
private struct ModeMenuSample: View {
  let title: String
  let modes: ApprovalModes

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(modes.title).font(.caption).foregroundStyle(.secondary)
      ForEach(modes.options) { option in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
          Image(systemName: option.id == modes.selectedID ? "checkmark" : option.risk.systemImage)
            .foregroundStyle(option.risk.tint)
            .frame(width: Theme.Control.icon)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            HStack(spacing: Theme.Spacing.extraSmall) {
              Text(option.label).font(.callout.weight(.medium))
              if let harness = option.harnessLabel, harness != option.label {
                Text("\(title): \(harness)").font(.caption).foregroundStyle(.tertiary)
              }
            }
            if let detail = option.detail {
              Text(detail).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      Divider()
      Text("Shift-Tab switches modes. The sandbox and model are separate.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(Theme.Spacing.medium)
    .frame(width: 420, alignment: .leading)
    .cardSurface(cornerRadius: Theme.Radius.medium)
    .accessibilityElement(children: .contain)
  }
}

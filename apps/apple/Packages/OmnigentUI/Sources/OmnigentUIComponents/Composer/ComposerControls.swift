import SwiftUI
import UniformTypeIdentifiers

/// The web's Add (+) menu: Add (Files and images), Session (side chat, Goal, Plan).
struct AddMenu: View {
  let canAttach: Bool
  let extras: ComposerExtraActions
  let chooseFiles: () -> Void
  let choosePhotos: () -> Void
  let paste: ([NSItemProvider]) -> Void

  var body: some View {
    Menu {
      Section("Add") {
        Button("Files and images\u{2026}", systemImage: "paperclip", action: chooseFiles)
          .disabled(!canAttach)
        Button("Photos\u{2026}", systemImage: "photo.on.rectangle", action: choosePhotos)
          .disabled(!canAttach)
        PasteButton(supportedContentTypes: [.fileURL, .image], payloadAction: paste)
      }
      if extras.newSideChat != nil || extras.setGoal != nil || extras.togglePlan != nil {
        Section("Session") {
          if let newSideChat = extras.newSideChat {
            Button(
              "Start a new side chat", systemImage: "bubble.left.and.bubble.right",
              action: newSideChat)
          }
          if let setGoal = extras.setGoal {
            Button("Goal", systemImage: "target", action: setGoal)
          }
          if let togglePlan = extras.togglePlan {
            Toggle(isOn: Binding(get: { extras.isPlanOn }, set: { _ in togglePlan() })) {
              Label("Plan", systemImage: "checklist")
            }
          }
        }
      }
    } label: {
      Label("Add", systemImage: "plus")
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .labelStyle(.iconOnly)
    .fixedSize()
    .help("Add files, images and more")
    .accessibilityIdentifier("composer-add")
  }
}

/// The Host chip: the selected host with a status dot, and the web's menu sections.
struct HostChip: View {
  let hosts: ComposerHosts
  let actions: ComposerExtraActions

  var body: some View {
    let selected = hosts.selected
    Menu {
      let cloud = hosts.hosts.filter { $0.kind == .cloud && $0.isOnline }
      let machines = hosts.hosts.filter { $0.kind == .machine && $0.isOnline }
      let offline = hosts.hosts.filter { !$0.isOnline }
      if !cloud.isEmpty { Section("Cloud") { hostButtons(cloud) } }
      if !machines.isEmpty { Section("My machines") { hostButtons(machines) } }
      if !offline.isEmpty {
        Menu("Offline hosts (\(offline.count))") { hostButtons(offline) }
      }
      if let connect = actions.connectHost {
        Divider()
        Button("Connect new host\u{2026}", systemImage: "plus", action: connect)
      }
    } label: {
      HStack(spacing: 3) {
        Image(systemName: selected?.kind == .cloud ? "cloud" : "laptopcomputer")
          .accessibilityHidden(true)
        Circle()
          .fill(selected?.isOnline == true ? Theme.success : ThemeColor.secondary.opacity(0))
          .overlay {
            Circle().strokeBorder(.secondary, lineWidth: selected?.isOnline == true ? 0 : 1)
          }
          .frame(width: 6, height: 6)
      }
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(hosts.isLocked || actions.selectHost == nil)
    .help("Host: \(selected?.name ?? "none")")
    .accessibilityLabel(
      "Host, \(selected?.name ?? "none"), \(selected?.isOnline == true ? "online" : "offline")"
    )
    .accessibilityIdentifier("composer-host")
  }

  @ViewBuilder
  private func hostButtons(_ list: [ComposerHost]) -> some View {
    ForEach(list) { host in
      Button {
        actions.selectHost?(host)
      } label: {
        if host.id == hosts.selectedID {
          Label(host.name, systemImage: "checkmark")
        } else {
          Text(host.name)
        }
      }
    }
  }
}

/// The Permission chip: `hand.raised` and the mode, a single-choice menu. ⇧Tab cycles it.
struct ApprovalModeChip: View {
  let modes: ApprovalModes
  let select: (@MainActor (ApprovalModeOption) -> Void)?
  var isCompact = false

  var body: some View {
    Menu {
      Section(modes.title) {
        ForEach(modes.options) { option in
          Button {
            select?(option)
          } label: {
            if option.id == modes.selectedID {
              Label(option.label, systemImage: "checkmark")
            } else {
              Text(option.label)
            }
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "hand.raised").accessibilityHidden(true)
        if !isCompact { Text(modes.selected?.label ?? "Mode") }
        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
          .accessibilityHidden(true)
      }
      .font(.callout)
      .accessibilityElement(children: .combine)
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(select == nil)
    .help("\(modes.title) (Shift-Tab cycles)")
    .accessibilityLabel("\(modes.title), \(modes.selected?.label ?? "")")
    .accessibilityIdentifier("composer-approval-mode")
  }
}

/// The context tray above the card: directory and worktree chips, branch, PR and context use.
struct ComposerTrayView: View {
  let tray: ComposerTray
  let actions: ComposerExtraActions

  var body: some View {
    HStack(spacing: 10) {
      if let directory = tray.directory {
        Menu {
          if !tray.recentDirectories.isEmpty {
            Section("Recents") {
              ForEach(tray.recentDirectories, id: \.self) { path in
                Button(path) { actions.selectDirectory?(path) }
              }
            }
          }
          if let openFolder = actions.openFolder {
            Button("Open folder\u{2026}", systemImage: "folder.badge.plus", action: openFolder)
          }
        } label: {
          Label(URL(filePath: directory).lastPathComponent, systemImage: "folder")
        }
        .disabled(actions.selectDirectory == nil && actions.openFolder == nil)
        .help(directory)
        .accessibilityIdentifier("composer-directory")
      }
      if let worktree = tray.worktree {
        Menu {
          Button("No worktree") { actions.selectWorktree?(nil) }
          ForEach(tray.worktrees, id: \.self) { name in
            Button(name) { actions.selectWorktree?(name) }
          }
        } label: {
          Label(worktree, systemImage: "arrow.triangle.branch")
        }
        .disabled(actions.selectWorktree == nil)
        .accessibilityIdentifier("composer-worktree")
      }
      if let branch = tray.branch {
        Label(branch, systemImage: "arrow.triangle.branch").foregroundStyle(.secondary)
      }
      if let pullRequest = tray.pullRequest {
        Label(pullRequest, systemImage: "arrow.triangle.pull").foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if let fraction = tray.contextFraction {
        ProgressRing(fraction: fraction, size: 13)
          .help("\(Int((fraction * 100).rounded()))% of the context window used")
          .accessibilityElement()
          .accessibilityLabel("Context used")
          .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
      }
    }
    .font(.caption)
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.visible)
    .padding(.horizontal, 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-tray")
  }
}

/// Messages queued or steering while the agent works: edit, send now, reorder, remove.
struct QueueStrip: View {
  let queue: [QueuedMessage]
  let actions: ComposerExtraActions

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(queue) { message in
        HStack(spacing: 8) {
          Image(systemName: "text.line.first.and.arrowtriangle.forward")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(message.text).lineLimit(1).font(.callout)
          Spacer(minLength: 4)
          stateLabel(message.state)
          if let sendNow = actions.sendQueuedNow {
            Button("Send now", systemImage: "arrow.up.circle") { sendNow(message) }
              .labelStyle(.iconOnly)
              .accessibilityIdentifier("queued-send-now-\(message.id)")
          }
          if let remove = actions.removeQueued {
            Button("Remove", systemImage: "xmark.circle") { remove(message) }
              .labelStyle(.iconOnly)
              .accessibilityIdentifier("queued-remove-\(message.id)")
          }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.medium)
        )
        .contextMenu {
          if let sendNow = actions.sendQueuedNow { Button("Send now") { sendNow(message) } }
          if let remove = actions.removeQueued {
            Button("Remove", role: .destructive) { remove(message) }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queued-\(message.id)")
      }
    }
  }

  @ViewBuilder
  private func stateLabel(_ state: QueuedMessage.State) -> some View {
    switch state {
    case .queued:
      Text("Queued").font(.caption).foregroundStyle(.secondary)
    case .sending:
      ProgressView().controlSize(.mini)
    case .waitingForHost:
      Text("Waiting for host").font(.caption).foregroundStyle(.secondary)
    case .failed(let message):
      Label("Send failed", systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(Theme.failure)
        .help(message)
    }
  }
}

/// `/` command and `@` mention completions for the current draft.
struct ComposerCompletions {
  struct Item: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let replacement: String
    let systemImage: String
  }

  let items: [Item]
  private let prefixRange: Range<String.Index>?
  private let draft: String

  init(draft: String, commands: [SlashCommand], mentions: [String]) {
    self.draft = draft
    if draft.hasPrefix("/"), !draft.contains(" "), !commands.isEmpty {
      let query = draft.dropFirst().lowercased()
      items = commands.filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }
        .prefix(8)
        .map {
          Item(
            id: "/\($0.name)", title: "/\($0.name)", detail: $0.description,
            replacement: "/\($0.name) ", systemImage: $0.isSkill ? "wand.and.sparkles" : "command")
        }
      prefixRange = draft.startIndex..<draft.endIndex
      return
    }
    if let mentionStart = draft.lastIndex(of: "@"), !mentions.isEmpty,
      mentionStart == draft.startIndex || draft[draft.index(before: mentionStart)].isWhitespace,
      !draft[mentionStart...].contains(" ")
    {
      let query = draft[draft.index(after: mentionStart)...].lowercased()
      items = mentions.filter { query.isEmpty || $0.lowercased().contains(query) }
        .prefix(8)
        .map {
          Item(id: "@\($0)", title: $0, detail: "", replacement: "@\($0) ", systemImage: "doc")
        }
      prefixRange = mentionStart..<draft.endIndex
      return
    }
    items = []
    prefixRange = nil
  }

  func applying(_ item: Item) -> String {
    guard let prefixRange else { return draft }
    var copy = draft
    copy.replaceSubrange(prefixRange, with: item.replacement)
    return copy
  }
}

struct CompletionList: View {
  let items: [ComposerCompletions.Item]
  let pick: (ComposerCompletions.Item) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(items) { item in
        Button {
          pick(item)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: item.systemImage)
              .foregroundStyle(Theme.brandAccent)
              .frame(width: 16)
              .accessibilityHidden(true)
            Text(item.title).font(.callout.monospaced())
            if !item.detail.isEmpty {
              Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .accessibilityIdentifier("composer-completion-\(item.id)")
      }
      Text("Tab to complete, Esc to dismiss")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
    .padding(.vertical, 4)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
    .overlay { RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(.separator) }
    .padding(.horizontal, 8)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-completions")
  }
}

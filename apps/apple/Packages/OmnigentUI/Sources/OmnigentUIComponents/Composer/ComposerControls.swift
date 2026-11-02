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
    .composerChip()
    .help("Add files, images and more")
    .accessibilityLabel("Add")
    .accessibilityHint("Attaches files or images, or starts a side chat, goal or plan")
    .accessibilityIdentifier("composer-add")
  }
}

/// The Host chip: the selected host's symbol, its name where there is room, a status dot, and
/// the web's menu sections.
struct HostChip: View {
  let hosts: ComposerHosts
  let actions: ComposerExtraActions
  var showsName = true

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
      HStack(spacing: Theme.Spacing.extraSmall) {
        Image(systemName: selected?.kind == .cloud ? "cloud" : "laptopcomputer")
          .accessibilityHidden(true)
        // A locked host is named in the context row above; a choosable one names itself.
        if showsName, !hosts.isLocked, let name = selected?.name {
          Text(name)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: Theme.Control.serverNameWidth)
            .fixedSize()
        }
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
    .composerChip()
    .disabled(hosts.isLocked || actions.selectHost == nil)
    .help(
      "Host: \(selected?.name ?? "none"), \(selected?.isOnline == true ? "online" : "offline")"
        + (hosts.isLocked ? ". The host can't change once the session starts" : "")
    )
    .accessibilityLabel(
      "Host, \(selected?.name ?? "none"), \(selected?.isOnline == true ? "online" : "offline")"
    )
    .accessibilityHint(hosts.isLocked ? "" : "Chooses the machine the session runs on")
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

/// The context tray above the card: where the session runs (agent, host, workspace), the folder
/// and worktree pickers on a new session, the pull request, and context use.
struct ComposerTrayView: View {
  let tray: ComposerTray
  let context: ExecutionContext?
  let actions: ComposerExtraActions
  var showsContextDetails = false

  private var canPickDirectory: Bool {
    actions.selectDirectory != nil || actions.openFolder != nil
  }

  /// Whether anything shows before the context gauge.
  private var hasLeadingItems: Bool {
    context != nil || (tray.directory != nil && (canPickDirectory || context == nil))
      || tray.worktree != nil || (tray.branch != nil && context?.branch == nil)
      || tray.pullRequest != nil
  }

  var body: some View {
    // The tray floats over the transcript, so its items sit on glass chips.
    HStack(spacing: Theme.Spacing.medium) {
      if hasLeadingItems {
        leadingItems.trayChip()
      }
      Spacer(minLength: 0)
      if let fraction = tray.contextFraction {
        contextUsage(fraction).trayChip()
      }
    }
    .font(.caption)
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.visible)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-tray")
  }

  private var leadingItems: some View {
    HStack(spacing: Theme.Spacing.medium) {
      if let context {
        // A folder picker already names the workspace.
        ExecutionContextRow(
          context: context, includesWorkspace: !(canPickDirectory && tray.directory != nil),
          isPresented: showsContextDetails)
      }
      if let directory = tray.directory, canPickDirectory || context == nil {
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
        .disabled(!canPickDirectory)
        .help(directory)
        .accessibilityLabel("Folder, \(URL(filePath: directory).lastPathComponent)")
        .accessibilityHint("Chooses the folder the session works in")
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
        .help("Worktree: \(worktree)")
        .accessibilityLabel("Worktree, \(worktree)")
        .accessibilityHint("Chooses whether the session works in a separate git worktree")
        .accessibilityIdentifier("composer-worktree")
      }
      if let branch = tray.branch, context?.branch == nil {
        Label(branch, systemImage: "arrow.triangle.branch").foregroundStyle(.secondary)
          .help("Branch: \(branch)")
          .accessibilityLabel("Branch, \(branch)")
      }
      if let pullRequest = tray.pullRequest {
        Label(pullRequest, systemImage: "arrow.triangle.pull").foregroundStyle(.secondary)
          .help("Pull request \(pullRequest)")
          .accessibilityLabel("Pull request \(pullRequest)")
      }
    }
  }

  /// A gauge with its number, so it never reads as a spinner and needs no hover.
  private func contextUsage(_ fraction: Double) -> some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      ProgressRing(fraction: fraction, size: 13, warnsNearFull: true)
      Text("\(Int((fraction * 100).rounded()))% context")
        .monospacedDigit()
        .foregroundStyle(
          fraction > 0.85 ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary)
        )
        .lineLimit(1)
        .fixedSize()
    }
    .help("Context used: \(Int((fraction * 100).rounded()))% of the context window")
    .accessibilityElement()
    .accessibilityLabel("Context used")
    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    .accessibilityIdentifier("composer-context-usage")
  }
}

extension View {
  /// A tray item group on a small glass capsule.
  fileprivate func trayChip() -> some View {
    padding(.horizontal, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.extraSmall)
      .glassSurface(in: Capsule())
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
          HStack(spacing: Theme.Spacing.small) {
            Image(systemName: item.systemImage)
              .foregroundStyle(.secondary)
              .frame(width: 16)
              .accessibilityHidden(true)
            Text(item.title).font(.callout.monospaced())
            if !item.detail.isEmpty {
              Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.vertical, Theme.Spacing.extraSmall)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .accessibilityIdentifier("composer-completion-\(item.id)")
      }
      Text("Tab to complete, Esc to dismiss")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.extraSmall)
    }
    .padding(.vertical, Theme.Spacing.extraSmall)
    .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    .padding(.horizontal, Theme.Spacing.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-completions")
  }
}

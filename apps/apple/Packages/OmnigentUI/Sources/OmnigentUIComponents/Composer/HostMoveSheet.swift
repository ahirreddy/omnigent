import SwiftUI

/// Switch Host (move a session whose host is gone to another online machine, or into a new
/// sandbox) and Resume on a Machine (start a session bound to no host), as the web's
/// `SwitchHostDialog` and `ResumeWithDirectoryDialog`: a host and a directory on it (or a
/// sandbox and the repository it clones), and for Resume an optional worktree.
struct HostMoveSheet: View {
  let kind: HostMoveKind
  let actions: HostMoveActions
  let close: @MainActor () -> Void

  /// Empty until the hosts load.
  @State private var hosts: [HostMoveTarget] = []
  @State private var hostsLoaded = false
  @State private var loadError: String?
  @State private var hostID: String?
  @State private var workspace = ""
  @State private var home: String?
  @State private var edited = false
  @State private var branch = ""
  @State private var baseBranch = ""
  @State private var isBrowsing = false
  @State private var isSubmitting = false
  @State private var error: String?
  /// A switch released the old host and did not start on the new one.
  @State private var stranded = false
  /// The sandbox request after the release failed, so the move isn't confirmed.
  @State private var unconfirmed = false
  @State private var repository = ""
  @State private var sandboxBranch = ""

  private var isSwitch: Bool {
    if case .switchHost = kind { return true }
    return false
  }

  private var targets: [HostMoveTarget] {
    HostMoveRules.targets(hosts, kind: kind, stranded: stranded)
  }

  private var resolved: String? { HostMoveRules.resolvedWorkspace(workspace, home: home) }

  /// The chosen new sandbox's provider; `nil` for a host.
  private var sandboxProvider: String? {
    targets.first { $0.id == hostID }?.sandboxProvider
  }

  private var sandboxProblem: HostMoveRepoProblem? {
    actions.sandboxProblem(repository, sandboxBranch)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(
            HostMoveRules.description(
              kind, offersSandbox: targets.contains { $0.sandboxProvider != nil })
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        content
      }
      .formStyle(.grouped)
      .disabled(isSubmitting)
      .navigationTitle(isSwitch ? "Switch Host" : "Resume on a Machine")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar { toolbar }
    }
    #if os(macOS)
      .frame(minWidth: 480, minHeight: 360)
    #endif
    .task { await loadHosts() }
    .onChange(of: hostID) { previous, _ in hostChanged(from: previous) }
    .accessibilityIdentifier(isSwitch ? "switch-host-sheet" : "resume-dir-sheet")
  }

  @ViewBuilder private var content: some View {
    if let loadError {
      Label(loadError, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.failure)
    } else if !hostsLoaded {
      HStack {
        ProgressView().controlSize(.small)
        Text("Loading your machines\u{2026}").foregroundStyle(.secondary)
      }
    } else if targets.isEmpty {
      Text(HostMoveRules.noTargets(kind)).foregroundStyle(.secondary)
        .accessibilityIdentifier(isSwitch ? "switch-host-no-targets" : "resume-dir-no-hosts")
    } else {
      hostPicker
      if sandboxProvider != nil {
        HostMoveSandboxSection(
          repository: $repository, branch: $sandboxBranch, problem: sandboxProblem)
      } else {
        directorySection
      }
      if !isSwitch { HostMoveWorktreeSection(branch: $branch, baseBranch: $baseBranch) }
      if let error {
        HostMoveErrorSection(error: error, stranded: stranded, unconfirmed: unconfirmed)
      }
    }
  }

  /// New sandboxes first, then the hosts, as the web's list.
  private var hostPicker: some View {
    Picker("Host", selection: $hostID) {
      let sandboxes = targets.filter { $0.sandboxProvider != nil }
      if !sandboxes.isEmpty {
        Section {
          ForEach(sandboxes) { sandbox in
            Label(sandbox.name, systemImage: "cloud").tag(Optional(sandbox.id))
          }
        }
      }
      Section {
        ForEach(targets.filter { $0.sandboxProvider == nil }) { host in
          Text(host.name).tag(Optional(host.id))
        }
      }
    }
    .accessibilityIdentifier(isSwitch ? "switch-host-select" : "resume-dir-host-select")
  }

  private var directorySection: some View {
    Section {
      HStack {
        TextField(
          "Working directory",
          text: Binding(
            get: { workspace },
            set: {
              // Focusing the field writes its text back unchanged, which isn't an edit.
              guard $0 != workspace else { return }
              edited = true
              workspace = $0
            }),
          prompt: Text("/path/on/the/host")
        )
        .font(Theme.codeFont)
        .autocorrectionDisabled()
        // The section header names the field.
        .labelsHidden()
        .accessibilityIdentifier("host-move-directory")
        Button("Browse Folders\u{2026}", systemImage: "folder") { isBrowsing = true }
          .labelStyle(.iconOnly)
          .help("Browse the host's folders")
          .disabled(hostID == nil)
          .accessibilityIdentifier("host-move-browse")
      }
      .sheet(isPresented: $isBrowsing) { folderBrowser }
    } header: {
      Text("Working directory")
    } footer: {
      if isSwitch {
        Label(
          "Files don\u{2019}t move across hosts. Anything uncommitted stays on the old machine, "
            + "and the agent picks up in this directory instead.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(Theme.warning)
        .accessibilityIdentifier("switch-host-warning")
      }
    }
  }

  @ViewBuilder private var folderBrowser: some View {
    if let hostID {
      FolderBrowserView(
        initialPath: resolved,
        load: { path in await actions.browse(hostID, path) },
        choose: { path in
          edited = true
          workspace = path
          isBrowsing = false
        },
        cancel: { isBrowsing = false })
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      // A move can't be called back once sent, and the spinner slides this under the pointer.
      Button("Cancel", action: close).disabled(isSubmitting)
    }
    ToolbarItemGroup(placement: .confirmationAction) {
      if isSubmitting { ProgressView().controlSize(.small) }
      confirmButton
    }
  }

  private var confirmButton: some View {
    Button(isSwitch ? "Switch Host" : "Start Session") { Task { await submit() } }
      .primaryActionStyle()
      .disabled(
        hostID == nil || isSubmitting || targets.isEmpty
          || (sandboxProvider == nil ? resolved == nil : sandboxProblem != nil)
      )
      .accessibilityIdentifier(isSwitch ? "switch-host-button" : "resume-dir-bind-button")
  }

  private func loadHosts() async {
    switch await actions.loadHosts() {
    case .success(let loaded):
      hosts = loaded
      hostsLoaded = true
      if case .resume(_, let prefill?) = kind, !prefill.isEmpty, workspace.isEmpty {
        workspace = prefill
        edited = true
      }
      hostID = HostMoveRules.defaultHost(targets, kind: kind)
    case .failure(let failure):
      loadError = failure.message
    }
  }

  /// A path means nothing on another machine: Switch Host clears it and defaults to the new
  /// host's home; Resume keeps the session's own directory.
  private func hostChanged(from previous: String?) {
    home = nil
    if isSwitch, previous != nil {
      workspace = ""
      edited = false
    }
    // A new sandbox has no folders to default to.
    guard let hostID, sandboxProvider == nil else { return }
    Task {
      let found = await actions.home(hostID)
      guard self.hostID == hostID else { return }
      home = found
      if !edited, workspace.isEmpty, let found { workspace = found }
    }
  }

  private func submit() async {
    guard let hostID else { return }
    var choice: HostMoveChoice
    if let sandboxProvider {
      choice = HostMoveChoice(hostID: hostID, workspace: "")
      choice.sandbox = HostMoveSandbox(
        provider: sandboxProvider, repository: repository.trimmingCharacters(in: .whitespaces),
        branch: sandboxBranch.trimmingCharacters(in: .whitespaces))
    } else {
      guard let resolved else { return }
      choice = HostMoveChoice(hostID: hostID, workspace: resolved)
      choice.branch = branch.trimmingCharacters(in: .whitespaces)
      choice.baseBranch = baseBranch.trimmingCharacters(in: .whitespaces)
    }
    isSubmitting = true
    error = nil
    let outcome = await actions.submit(choice)
    isSubmitting = false
    switch outcome {
    case .moved:
      close()
    case .failed(let message):
      error = message
    case .stranded(let message):
      stranded = true
      unconfirmed = false
      error = message
    case .unconfirmed(let message):
      stranded = true
      unconfirmed = true
      error = message
    }
  }
}

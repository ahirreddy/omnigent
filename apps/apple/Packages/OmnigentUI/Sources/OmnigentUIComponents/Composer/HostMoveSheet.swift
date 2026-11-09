import SwiftUI

/// Switch Host (move a session whose host is gone to another online machine) and Resume on a
/// Machine (start a session bound to no host), as the web's `SwitchHostDialog` and
/// `ResumeWithDirectoryDialog`: a host, a directory on it, and for Resume an optional worktree.
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

  private var isSwitch: Bool {
    if case .switchHost = kind { return true }
    return false
  }

  private var targets: [HostMoveTarget] {
    HostMoveRules.targets(hosts, kind: kind, stranded: stranded)
  }

  private var resolved: String? { HostMoveRules.resolvedWorkspace(workspace, home: home) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(description).fixedSize(horizontal: false, vertical: true)
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
      Text(noTargets).foregroundStyle(.secondary)
        .accessibilityIdentifier(isSwitch ? "switch-host-no-targets" : "resume-dir-no-hosts")
    } else {
      Picker("Host", selection: $hostID) {
        ForEach(targets) { host in
          Text(host.name).tag(Optional(host.id))
        }
      }
      .accessibilityIdentifier(isSwitch ? "switch-host-select" : "resume-dir-host-select")
      directorySection
      if !isSwitch { worktreeSection }
      if let error { errorSection(error) }
    }
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

  private var worktreeSection: some View {
    Section {
      TextField("Branch", text: $branch, prompt: Text("feature/my-branch"))
        .font(Theme.codeFont)
        .autocorrectionDisabled()
        .accessibilityIdentifier("resume-dir-branch")
      if !branch.trimmingCharacters(in: .whitespaces).isEmpty {
        TextField(
          "Base branch", text: $baseBranch,
          prompt: Text("Base branch (defaults to the current branch)")
        )
        .font(Theme.codeFont)
        .autocorrectionDisabled()
        .accessibilityIdentifier("resume-dir-base-branch")
      }
    } header: {
      Label("Git worktree (optional)", systemImage: "arrow.triangle.branch")
    } footer: {
      Text(
        "Creates a git worktree for a new branch in an isolated directory. Leave blank to "
          + "start in the picked directory.")
    }
  }

  private func errorSection(_ error: String) -> some View {
    Section {
      if stranded {
        Text(
          "The session left its old host but didn\u{2019}t start on the new one, so it isn\u{2019}t "
            + "running anywhere. Pick a host \u{2014} including the one it came from \u{2014} and "
            + "try again."
        )
        .foregroundStyle(Theme.failure)
        Text(error).font(.callout).foregroundStyle(.secondary)
      } else {
        Text(error).foregroundStyle(Theme.failure)
      }
    }
    .accessibilityIdentifier("host-move-error")
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
      .disabled(hostID == nil || resolved == nil || isSubmitting || targets.isEmpty)
      .accessibilityIdentifier(isSwitch ? "switch-host-button" : "resume-dir-bind-button")
  }

  private var description: String {
    isSwitch
      ? "Move this session to another connected machine."
      : "This session isn\u{2019}t running on any machine. Pick one of your machines and a "
        + "directory to continue the conversation against your files."
  }

  private var noTargets: String {
    isSwitch
      ? "No other hosts are online. Connect one with `omnigent host` and try again."
      : "None of your machines are online. Start one with `omnigent host` from your terminal, "
        + "then reopen this sheet."
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
    guard let hostID else { return }
    Task {
      let found = await actions.home(hostID)
      guard self.hostID == hostID else { return }
      home = found
      if !edited, workspace.isEmpty, let found { workspace = found }
    }
  }

  private func submit() async {
    guard let hostID, let resolved else { return }
    isSubmitting = true
    error = nil
    var choice = HostMoveChoice(hostID: hostID, workspace: resolved)
    choice.branch = branch.trimmingCharacters(in: .whitespaces)
    choice.baseBranch = baseBranch.trimmingCharacters(in: .whitespaces)
    let outcome = await actions.submit(choice)
    isSubmitting = false
    switch outcome {
    case .moved:
      close()
    case .failed(let message):
      error = message
    case .stranded(let message):
      stranded = true
      error = message
    }
  }
}

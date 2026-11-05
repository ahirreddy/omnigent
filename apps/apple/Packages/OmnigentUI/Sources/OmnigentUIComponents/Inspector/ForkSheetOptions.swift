import SwiftUI

/// The fork dialog's Host, Model, Effort and Permissions rows and its Advanced section (title
/// and a new worktree branch), as on the web's `ForkSessionDialog`.
struct ForkOptionsSections: View {
  let options: ForkOptions
  let actions: ForkActions
  let startsOnHost: Bool
  @Binding var choices: ForkChoices
  @State private var showsAdvanced = false

  /// The prefix of the new-sandbox host rows' tags; the provider follows.
  static let sandboxTag = "\u{0}sandbox:"

  var body: some View {
    if !options.hosts.isEmpty || options.offersSandbox {
      Section {
        Picker("Host", selection: hostSelection) {
          ForEach(options.hosts) { host in
            Text(host.unavailableReason == nil ? host.name : "\(host.name) (unavailable)")
              .tag(host.id)
          }
          if options.offersSandbox {
            ForEach(sandboxRows) { row in
              Text(row.label).tag(Self.sandboxTag + row.id)
            }
          }
        }
        .accessibilityIdentifier("fork-host")
        if choices.isSandbox {
          sandboxChoices
        }
      }
    }
    runConfiguration
    Section {
      DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
        TextField("Title", text: $choices.title, prompt: Text("Fork of the original"))
          .accessibilityIdentifier("fork-title")
        if startsOnHost {
          TextField("Branch", text: $choices.branch, prompt: Text("feature/my-branch"))
            .font(Theme.codeFont)
            .accessibilityIdentifier("fork-branch")
          Text(
            "Creates a git worktree for a new branch so the copy does not share files with the "
              + "original. Leave blank to start in the directory."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var runConfiguration: some View {
    let modes = options.approvalModes[choices.agentID] ?? []
    if !options.models.isEmpty || !modes.isEmpty {
      Section {
        if !options.models.isEmpty {
          Picker("Model", selection: $choices.model) {
            Text("Same as original").tag(String?.none)
            ForEach(options.models.filter { !$0.hidden }) { model in
              Text(model.displayName ?? model.id).tag(Optional(model.id))
            }
          }
          .accessibilityIdentifier("fork-model")
        }
        if !efforts.isEmpty {
          Picker("Effort", selection: $choices.effort) {
            Text("Default").tag(String?.none)
            ForEach(efforts, id: \.self) { effort in
              Text(ComposerConfiguration.effortLabel(effort)).tag(Optional(effort))
            }
          }
          .accessibilityIdentifier("fork-effort")
        }
        if !modes.isEmpty {
          Picker("Permissions", selection: $choices.approvalMode) {
            ForEach(modes) { mode in
              Text(mode.label).tag(mode.id == modes.first?.id ? String?.none : Optional(mode.id))
            }
          }
          .accessibilityIdentifier("fork-permissions")
        }
      }
    }
  }

  /// The chosen model's efforts.
  private var efforts: [String] {
    options.models.first { $0.id == choices.model }?.supportedReasoningEfforts ?? []
  }

  /// The sandbox rows; a server naming no provider gets one "New sandbox".
  private var sandboxRows: [ForkSandboxOption] {
    options.sandboxes.isEmpty
      ? [ForkSandboxOption(provider: nil, label: "New sandbox")]
      : options.sandboxes
  }

  @ViewBuilder private var sandboxChoices: some View {
    if let profiles = options.profiles, let profileActions = actions.profiles {
      LabeledContent("Profile") {
        SandboxProfilePicker(state: profiles, actions: profileActions)
          .buttonStyle(.borderless)
      }
    }
    if options.isCheckingBranches {
      Label("Checking current branches\u{2026}", systemImage: "arrow.triangle.branch")
        .foregroundStyle(.secondary)
    } else if let repositories = actions.repositories {
      SandboxRepositoriesEditor(state: options.repositories, actions: repositories)
    }
  }

  private var hostSelection: Binding<String> {
    Binding(
      get: {
        choices.isSandbox
          ? Self.sandboxTag + (choices.sandboxProvider ?? "") : (choices.hostID ?? "")
      },
      set: { tag in
        choices.isSandbox = tag.hasPrefix(Self.sandboxTag)
        choices.hostID = choices.isSandbox ? nil : tag
        if choices.isSandbox {
          let provider = String(tag.dropFirst(Self.sandboxTag.count))
          choices.sandboxProvider = provider.isEmpty ? nil : provider
          actions.sandboxSelected?(choices.sandboxProvider)
        }
      })
  }
}

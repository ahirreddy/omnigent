import SwiftUI

/// The fork dialog's Host, Model, Effort and Permissions rows and its Advanced section (title
/// and a new worktree branch), as on the web's `ForkSessionDialog`.
struct ForkOptionsSections: View {
  let options: ForkOptions
  let startsOnHost: Bool
  @Binding var choices: ForkChoices
  @State private var showsAdvanced = false

  /// The "New sandbox" host row's tag.
  static let sandboxTag = "\u{0}sandbox"

  var body: some View {
    if !options.hosts.isEmpty || options.offersSandbox {
      Section {
        Picker("Host", selection: hostSelection) {
          ForEach(options.hosts) { host in
            Text(host.unavailableReason == nil ? host.name : "\(host.name) (unavailable)")
              .tag(host.id)
          }
          if options.offersSandbox {
            Text("New sandbox").tag(Self.sandboxTag)
          }
        }
        .accessibilityIdentifier("fork-host")
        if choices.isSandbox {
          TextField(
            "Repositories", text: $choices.repositories,
            prompt: Text("Inherit the original's (or https://github.com/org/repo#branch)"))
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

  private var hostSelection: Binding<String> {
    Binding(
      get: { choices.isSandbox ? Self.sandboxTag : (choices.hostID ?? "") },
      set: { tag in
        choices.isSandbox = tag == Self.sandboxTag
        choices.hostID = choices.isSandbox ? nil : tag
      })
  }
}

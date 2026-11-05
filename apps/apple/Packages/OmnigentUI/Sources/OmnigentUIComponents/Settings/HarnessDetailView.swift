public import SwiftUI

/// A harness's startup command on a host, as the details show it.
public struct HarnessStartupState: Equatable, Sendable {
  /// One environment override.
  public struct Variable: Equatable, Sendable, Identifiable {
    /// Name.
    public let name: String
    /// Value.
    public let value: String
    /// The name.
    public var id: String { name }

    /// Creates a variable.
    public init(name: String, value: String) {
      self.name = name
      self.value = value
    }
  }

  /// The command, resolved to its path when found.
  public var command: String
  /// The executable was found.
  public var found: Bool
  /// Where the command comes from.
  public var source: String
  /// Whether the host separates the environment overrides, so they are listed.
  public var listsEnvironment: Bool
  /// Environment overrides.
  public var environment: [Variable]
  /// The note under the environment: inherited or cleared, and removed variables.
  public var environmentNote: String
  /// The arguments; empty when none, or when the host reports only how many.
  public var arguments: [String]
  /// Shown instead of the arguments when there are none to list.
  public var argumentsNote: String

  /// Creates the state.
  public init(
    command: String, found: Bool, source: String, listsEnvironment: Bool,
    environment: [Variable], environmentNote: String, arguments: [String],
    argumentsNote: String
  ) {
    self.command = command
    self.found = found
    self.source = source
    self.listsEnvironment = listsEnvironment
    self.environment = environment
    self.environmentNote = environmentNote
    self.arguments = arguments
    self.argumentsNote = argumentsNote
  }
}

/// One harness on one host: Settings > Harnesses > a harness (the web's harness details page).
public struct HarnessDetailState: Equatable, Sendable {
  /// The startup section.
  public enum Startup: Equatable, Sendable {
    /// Not shown: the host does not report it.
    case hidden
    /// Loading.
    case loading
    /// Why it cannot show, e.g. "Update Mac to see launch settings."
    case unavailable(String)
    /// The command.
    case loaded(HarnessStartupState)
  }

  /// A problem with the harness and the button that fixes it.
  public struct Warning: Equatable, Sendable {
    /// What is wrong.
    public var message: String
    /// The button; `nil` when it cannot be fixed from the app.
    public var action: String?

    /// Creates a warning.
    public init(message: String, action: String?) {
      self.message = message
      self.action = action
    }
  }

  /// The harness id, for its glyph.
  public var harness: String
  /// Name.
  public var name: String
  /// The host's name.
  public var hostName: String
  /// `Configured · you@example.com`, `Needs sign-in`, ...
  public var status: String?
  /// Ready.
  public var isReady: Bool
  /// What is wrong, and the button that fixes it, when not set up or out of date.
  public var warning: Warning?
  /// The credential row's label.
  public var credentialLabel: String
  /// Its description.
  public var credentialDescription: String
  /// A credential problem.
  public var credentialWarning: Bool
  /// The credential row's button: Switch Account, Sign In Again or Reconfigure.
  public var credentialAction: String?
  /// What the last fix did.
  public var notice: String?
  /// The startup command.
  public var startup: Startup

  /// Creates the state.
  public init(
    harness: String, name: String, hostName: String, status: String? = nil,
    isReady: Bool = false, warning: Warning? = nil,
    credentialLabel: String, credentialDescription: String, credentialWarning: Bool = false,
    credentialAction: String? = nil, notice: String? = nil, startup: Startup = .hidden
  ) {
    self.harness = harness
    self.name = name
    self.hostName = hostName
    self.status = status
    self.isReady = isReady
    self.warning = warning
    self.credentialLabel = credentialLabel
    self.credentialDescription = credentialDescription
    self.credentialWarning = credentialWarning
    self.credentialAction = credentialAction
    self.notice = notice
    self.startup = startup
  }
}

/// What the details can do.
public struct HarnessDetailActions {
  /// Back to the harness list.
  public var back: @MainActor () -> Void
  /// The warning's button: install, update or set up.
  public var fixWarning: @MainActor () -> Void
  /// The credential row's button: switch account, sign in again or reconfigure.
  public var fixCredential: @MainActor () -> Void

  /// Creates the actions.
  public init(
    back: @escaping @MainActor () -> Void, fixWarning: @escaping @MainActor () -> Void,
    fixCredential: @escaping @MainActor () -> Void
  ) {
    self.back = back
    self.fixWarning = fixWarning
    self.fixCredential = fixCredential
  }
}

/// A harness's details on the selected host: its status, the warning with its fix, the
/// credential with Switch Account or Reconfigure, and the read-only startup command.
public struct HarnessDetailView: View {
  private let state: HarnessDetailState
  private let actions: HarnessDetailActions

  /// Creates the details.
  public init(state: HarnessDetailState, actions: HarnessDetailActions) {
    self.state = state
    self.actions = actions
  }

  /// The details, as grouped form sections.
  public var body: some View {
    Section {
      HStack(spacing: Theme.Spacing.medium) {
        HarnessGlyph(harness: state.harness, size: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(state.name).font(.title3.weight(.semibold))
          if let status = state.status {
            Text(status)
              .font(.caption)
              .foregroundStyle(state.isReady ? Theme.success : Theme.warning)
          }
        }
      }
      LabeledContent("Machine", value: state.hostName)
      if let notice = state.notice {
        Label(notice, systemImage: "checkmark.circle.fill")
          .foregroundStyle(Theme.success)
          .accessibilityIdentifier("harness-detail-notice")
      }
      if let warning = state.warning {
        HStack {
          Label(warning.message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.warning)
          Spacer()
          if let action = warning.action {
            Button(action, action: actions.fixWarning)
              .accessibilityIdentifier("harness-detail-fix")
          }
        }
      }
    } header: {
      Button("Harnesses", systemImage: "chevron.left", action: actions.back)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("harness-detail-back")
    }
    Section("Credential") {
      HStack(spacing: Theme.Spacing.medium) {
        Image(systemName: state.credentialWarning ? "exclamationmark.triangle" : "key")
          .foregroundStyle(state.credentialWarning ? Theme.warning : .secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(state.credentialLabel)
          Text(state.credentialDescription).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if let action = state.credentialAction {
          Button(action, action: actions.fixCredential)
            .accessibilityIdentifier("harness-detail-credential-action")
        } else if state.isReady {
          Text("Configured").font(.caption).foregroundStyle(Theme.success)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("harness-detail-credential")
    }
    startupSection
  }

  @ViewBuilder private var startupSection: some View {
    switch state.startup {
    case .hidden:
      EmptyView()
    case .loading:
      Section("Startup Configuration") { ProgressView() }
    case .unavailable(let reason):
      Section("Startup Configuration") { Text(reason).foregroundStyle(.secondary) }
    case .loaded(let startup):
      HarnessStartupSections(startup: startup)
    }
  }
}

/// The read-only startup command, environment and arguments.
struct HarnessStartupSections: View {
  let startup: HarnessStartupState

  var body: some View {
    Section {
      Text(startup.command)
        .font(Theme.codeFont)
        .textSelection(.enabled)
      if !startup.found {
        Text("Executable not found.").font(.caption).foregroundStyle(Theme.warning)
      }
    } header: {
      Text("Startup Configuration")
    } footer: {
      Text(
        "\(startup.source) Read-only host defaults, not a running session\u{2019}s full command or environment. Sessions and workspaces may override these."
      )
    }
    Section {
      if !startup.environment.isEmpty {
        ForEach(startup.environment) { variable in
          LabeledContent {
            Text(variable.value.isEmpty ? "\"\"" : variable.value)
              .font(Theme.codeFont)
              .textSelection(.enabled)
          } label: {
            Text(variable.name).font(Theme.codeFont)
          }
        }
      } else if startup.listsEnvironment {
        Text("None configured").foregroundStyle(.secondary)
      }
    } header: {
      Text("Environment")
    } footer: {
      Text(startup.environmentNote)
    }
    Section("Arguments") {
      if !startup.arguments.isEmpty {
        ForEach(Array(startup.arguments.enumerated()), id: \.offset) { index, argument in
          LabeledContent("\(index + 1)") {
            Text(argument.isEmpty ? "\"\"" : argument)
              .font(Theme.codeFont)
              .textSelection(.enabled)
          }
        }
      } else {
        Text(startup.argumentsNote).foregroundStyle(.secondary)
      }
    }
  }
}

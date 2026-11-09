import OmnigentPlatform
public import SwiftUI

/// One step of the harness setup checklist.
public struct HarnessSetupStepState: Identifiable, Equatable, Sendable {
  /// Done, to do, or something the host cannot tell.
  public enum Status: Equatable, Sendable { case done, todo, unknown }
  /// What the step offers.
  public enum Control: Equatable, Sendable {
    /// Nothing.
    case none
    /// One-click install.
    case install
    /// The credential form; disabled until the harness is installed.
    case credential(enabled: Bool)
    /// A command to copy and run on the host.
    case command(String)
  }

  /// The step kind, unique within the checklist.
  public let id: String
  /// Title.
  public let title: String
  /// Detail.
  public let detail: String
  /// Status.
  public let status: Status
  /// What it offers.
  public let control: Control
  /// The subscription login command, offered in the credential form.
  public let loginCommand: String?

  /// Creates a step.
  public init(
    id: String, title: String, detail: String, status: Status, control: Control,
    loginCommand: String?
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.status = status
    self.control = control
    self.loginCommand = loginCommand
  }
}

/// The "Set up <harness> on <host>" sheet.
public struct HarnessSetupSheetState: Equatable, Sendable {
  /// The harness name.
  public var name: String
  /// The host name.
  public var hostName: String
  /// The checklist.
  public var steps: [HarnessSetupStepState]
  /// Every step is done.
  public var allDone: Bool
  /// Nothing can be done here: say to run `omni setup` on the host.
  public var needsOmniSetup: Bool
  /// The install is running.
  public var isInstalling: Bool
  /// A credential is being saved.
  public var isSavingCredential: Bool
  /// A credential found on the host the harness can adopt, e.g. `$OPENAI_API_KEY`.
  public var adoptableSource: String?
  /// Still loading the steps.
  public var isLoading: Bool
  /// What the last action did.
  public var notice: String?
  /// Why the last action or the load failed.
  public var errorMessage: String?

  /// Creates the state.
  public init(
    name: String, hostName: String, steps: [HarnessSetupStepState] = [], allDone: Bool = false,
    needsOmniSetup: Bool = false, isInstalling: Bool = false, isSavingCredential: Bool = false,
    adoptableSource: String? = nil, isLoading: Bool = false, notice: String? = nil,
    errorMessage: String? = nil
  ) {
    self.name = name
    self.hostName = hostName
    self.steps = steps
    self.allDone = allDone
    self.needsOmniSetup = needsOmniSetup
    self.isInstalling = isInstalling
    self.isSavingCredential = isSavingCredential
    self.adoptableSource = adoptableSource
    self.isLoading = isLoading
    self.notice = notice
    self.errorMessage = errorMessage
  }
}

/// A credential to save from the sheet.
public enum HarnessCredentialChoice: Equatable, Sendable {
  /// An API key.
  case apiKey(String)
  /// An OpenAI-compatible gateway.
  case gateway(baseURL: String, apiKey: String)
  /// The credential found on the host.
  case adopt
}

/// What the setup sheet can do.
public struct HarnessSetupActions {
  /// Installs the harness.
  public var install: @MainActor () -> Void
  /// Saves a credential.
  public var saveCredential: @MainActor (HarnessCredentialChoice) -> Void
  /// The credential form opened: look for credentials already on the host.
  public var credentialFormOpened: @MainActor () -> Void
  /// Closes the sheet.
  public var close: @MainActor () -> Void

  /// Creates the actions.
  public init(
    install: @escaping @MainActor () -> Void,
    saveCredential: @escaping @MainActor (HarnessCredentialChoice) -> Void,
    credentialFormOpened: @escaping @MainActor () -> Void = {},
    close: @escaping @MainActor () -> Void
  ) {
    self.install = install
    self.saveCredential = saveCredential
    self.credentialFormOpened = credentialFormOpened
    self.close = close
  }
}

/// The web's harness setup dialog: the server's steps as a checklist, each with Install, the
/// credential form (adopt a credential found on the host, sign in with a subscription, an API
/// key, or a gateway) or a command to copy. With nothing to do here it points at `omni setup`.
public struct HarnessSetupSheet: View {
  private let state: HarnessSetupSheetState
  private let actions: HarnessSetupActions
  @State private var credentialStep: String?

  /// Creates the sheet.
  /// - Parameters:
  ///   - state: The checklist.
  ///   - actions: Install, save and close.
  public init(state: HarnessSetupSheetState, actions: HarnessSetupActions) {
    self.state = state
    self.actions = actions
  }

  /// The sheet.
  public var body: some View {
    NavigationStack {
      Form {
        if state.isLoading {
          ProgressView()
        } else if state.needsOmniSetup {
          Section {
            Text(
              "Run \(Text("omni setup").font(Theme.codeFont)) on \(state.hostName) to finish setting up \(state.name)."
            )
            .accessibilityIdentifier("harness-setup-omni")
          } footer: {
            Text("\(state.name) needs a bit more setup on \(state.hostName).")
          }
        } else {
          Section {
            ForEach(state.steps) { step in
              stepRow(step)
            }
          } footer: {
            if state.allDone { Text("\(state.name) is ready on \(state.hostName).") }
          }
        }
        messages
      }
      .formStyle(.grouped)
      .navigationTitle("Set Up \(state.name) on \(state.hostName)")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(state.allDone ? "Done" : "Close", action: actions.close)
            .accessibilityIdentifier("harness-setup-close")
        }
      }
    }
    #if os(macOS)
      .frame(width: 520)
      .frame(minHeight: 260, idealHeight: 380)
    #endif
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness-setup-sheet")
  }

  @ViewBuilder private var messages: some View {
    if let notice = state.notice {
      Label(notice, systemImage: "checkmark.circle.fill")
        .foregroundStyle(Theme.success)
        .accessibilityIdentifier("harness-setup-notice")
    }
    if let error = state.errorMessage {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.failure)
        .textSelection(.enabled)
        .accessibilityIdentifier("harness-setup-error")
    }
  }

  @ViewBuilder private func stepRow(_ step: HarnessSetupStepState) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
        statusIcon(step.status)
        VStack(alignment: .leading, spacing: 2) {
          Text(step.title)
          if step.control == .install && state.isInstalling {
            Text("Installing on \(state.hostName). This can take a few minutes.")
              .font(.caption).foregroundStyle(.secondary)
          } else if !step.detail.isEmpty {
            Text(step.detail).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: Theme.Spacing.medium)
        control(step)
      }
      if credentialStep == step.id, case .credential(true) = step.control {
        HarnessCredentialForm(
          hostName: state.hostName, loginCommand: step.loginCommand,
          adoptableSource: state.adoptableSource, isSaving: state.isSavingCredential,
          save: actions.saveCredential)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness-setup-step-\(step.id)")
  }

  @ViewBuilder private func control(_ step: HarnessSetupStepState) -> some View {
    switch step.control {
    case .none:
      EmptyView()
    case .install:
      Button("Install", action: actions.install)
        .primaryActionStyle()
        .disabled(state.isInstalling)
        .overlay { if state.isInstalling { ProgressView().controlSize(.small) } }
        .accessibilityIdentifier("harness-setup-install")
    case .credential(let enabled):
      Button(credentialStep == step.id ? "Cancel" : "Set Up Sign-In") {
        if credentialStep == step.id {
          credentialStep = nil
        } else {
          credentialStep = step.id
          actions.credentialFormOpened()
        }
      }
      .disabled(!enabled)
      .help(enabled ? "" : "Install first, then set up sign-in.")
      .accessibilityIdentifier("harness-setup-add-credential")
    case .command(let command):
      CopyCommandButton(command: command)
    }
  }

  private func statusIcon(_ status: HarnessSetupStepState.Status) -> some View {
    Group {
      switch status {
      case .done:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
      case .todo:
        Image(systemName: "circle.dashed").foregroundStyle(Theme.warning)
      case .unknown:
        Image(systemName: "info.circle").foregroundStyle(.secondary)
      }
    }
    .accessibilityLabel(
      status == .done ? "Done" : status == .todo ? "To do" : "Instruction")
  }
}

/// A command to run on the host; click to copy it.
struct CopyCommandButton: View {
  let command: String
  @State private var copied = false

  var body: some View {
    Button {
      Pasteboard.copy(command)
      copied = true
    } label: {
      Label(command, systemImage: copied ? "checkmark" : "doc.on.doc")
        .font(Theme.codeFont)
        .labelStyle(.titleAndIcon)
    }
    .buttonStyle(.bordered)
    .help(copied ? "Copied" : "Copy command")
    .accessibilityIdentifier("harness-setup-command")
  }
}

/// The credential options, equally weighted: a credential found on the host, a subscription
/// sign-in command, an API key, or a gateway.
struct HarnessCredentialForm: View {
  let hostName: String
  let loginCommand: String?
  let adoptableSource: String?
  let isSaving: Bool
  let save: @MainActor (HarnessCredentialChoice) -> Void

  @State private var apiKey = ""
  @State private var gatewayURL = ""
  @State private var gatewayKey = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      if let adoptableSource {
        option("Use a credential found on this host", systemImage: "key") {
          HStack {
            Text("Found \(Text(adoptableSource).font(Theme.codeFont)) on \(hostName).")
            Spacer()
            Button("Use It") { save(.adopt) }
              .disabled(isSaving)
              .accessibilityIdentifier("harness-credential-adopt")
          }
        }
      }
      if let loginCommand {
        option("Sign in with your subscription", systemImage: "person.crop.circle") {
          HStack {
            Text("Run on \(hostName):")
            CopyCommandButton(command: loginCommand)
          }
        }
      }
      option("Use an API key", systemImage: "key") {
        HStack {
          SecureField("Paste an API key", text: $apiKey)
            .font(Theme.codeFont)
            .onSubmit(saveKey)
            .accessibilityIdentifier("harness-credential-key")
          Button("Save", action: saveKey)
            .disabled(isSaving || Self.trimmed(apiKey).isEmpty)
            .accessibilityIdentifier("harness-credential-save")
        }
      }
      option("Connect a gateway", systemImage: "point.3.connected.trianglepath.dotted") {
        VStack(alignment: .leading) {
          Text("Route through an OpenAI-compatible proxy (for example OpenRouter).")
            .font(.caption).foregroundStyle(.secondary)
          TextField("Gateway base URL", text: $gatewayURL)
            .accessibilityIdentifier("harness-credential-gateway-url")
          HStack {
            SecureField("Gateway API key", text: $gatewayKey)
              .font(Theme.codeFont)
              .onSubmit(saveGateway)
            Button("Save", action: saveGateway)
              .disabled(
                isSaving || Self.trimmed(gatewayURL).isEmpty || Self.trimmed(gatewayKey).isEmpty
              )
              .accessibilityIdentifier("harness-credential-gateway-save")
          }
        }
      }
      if isSaving { ProgressView().controlSize(.small) }
    }
    .textFieldStyle(.roundedBorder)
    .padding(.leading, Theme.Spacing.large)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness-credential-form")
  }

  private func option(
    _ title: String, systemImage: String, @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Label(title, systemImage: systemImage).font(.callout.weight(.medium))
      content()
    }
  }

  /// A pasted credential often brings a stray space or newline, which the provider would reject.
  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func saveKey() {
    guard !isSaving, !Self.trimmed(apiKey).isEmpty else { return }
    save(.apiKey(Self.trimmed(apiKey)))
    apiKey = ""
  }

  /// Return in the key field gets here too, so it checks what the Save button checks.
  private func saveGateway() {
    guard !isSaving, !Self.trimmed(gatewayURL).isEmpty, !Self.trimmed(gatewayKey).isEmpty else {
      return
    }
    save(.gateway(baseURL: Self.trimmed(gatewayURL), apiKey: Self.trimmed(gatewayKey)))
    gatewayKey = ""
  }
}

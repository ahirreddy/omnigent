public import SwiftUI

/// The connect screen: a server URL field with validation, the organization's servers (marked as
/// managed), and recent servers.
///
/// Return in the field, or the default Connect button, connects. Picking a server connects to it.
/// Recent servers can be forgotten from their context menu or the trailing button.
public struct ServerPickerView: View {
  private let directory: ServerDirectory
  private let prefill: String
  private let banner: AuthBanner?
  private let validator: ServerURLValidator
  private let actions: AuthActions

  @State private var serverUrl: String
  @State private var revealsValidation = false
  @FocusState private var urlFocused: Bool
  #if os(iOS)
    @State private var scansPairingCode = false
  #endif

  /// Creates the picker.
  /// - Parameters:
  ///   - directory: The servers to offer.
  ///   - prefill: The URL to start with (kept on cancel and failure).
  ///   - banner: A notice or the last connection failure.
  ///   - validator: Checks the typed URL with the core's normalizer.
  ///   - actions: The store's actions.
  public init(
    directory: ServerDirectory, prefill: String, banner: AuthBanner?,
    validator: ServerURLValidator, actions: AuthActions
  ) {
    self.directory = directory
    self.prefill = prefill
    self.banner = banner
    self.validator = validator
    self.actions = actions
    _serverUrl = State(initialValue: prefill)
  }

  /// The picker.
  public var body: some View {
    AuthCard(
      systemImage: "server.rack", title: "Connect to Omnigent",
      subtitle: "Enter the URL of your Omnigent server."
    ) {
      if let banner {
        AuthBannerView(banner, retry: actions.retry)
      }
      urlField
      if !directory.managed.isEmpty {
        managedSection
      }
      if !directory.recentServers.isEmpty {
        recentSection
      }
    } buttons: {
      #if os(iOS)
        AuthButton(title: "Scan Pairing Code", identifier: "auth.scan-pairing-code") {
          scansPairingCode = true
        }
      #endif
      AuthButton(title: "Connect", kind: .primary, identifier: "auth.connect", action: connect)
        .disabled(!validator.check(serverUrl).canConnect)
    }
    #if os(iOS)
      .sheet(isPresented: $scansPairingCode) {
        PairingScannerSheet(validator: validator, connect: actions.connect)
      }
    #endif
    .onChange(of: prefill) { _, newValue in serverUrl = newValue }
    .onChange(of: serverUrl) { _, _ in revealsValidation = false }
    .onChange(of: urlFocused) { _, focused in
      if !focused { revealsValidation = true }
    }
    .defaultFocus($urlFocused, true)
  }

  private var urlField: some View {
    VStack(alignment: .leading, spacing: AuthMetrics.fieldSpacing) {
      Text("Server URL")
        .font(.callout.weight(.medium))
        .accessibilityHidden(true)
      TextField(
        "Server URL", text: $serverUrl, prompt: Text(verbatim: "https://omnigent.example.com")
      )
      .labelsHidden()
      .textFieldStyle(.roundedBorder)
      .textContentType(.URL)
      .autocorrectionDisabled()
      #if os(iOS)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .submitLabel(.go)
      #endif
      .focused($urlFocused)
      .onSubmit(connect)
      .accessibilityLabel("Server URL")
      .accessibilityIdentifier("auth.server-url")
      if let hint = validator.hint(for: serverUrl, revealed: revealsValidation) {
        Label {
          Text(verbatim: hint.text)
        } icon: {
          Image(systemName: hint.isError ? "exclamationmark.circle.fill" : "arrow.right.circle")
            .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(hint.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .accessibilityIdentifier(hint.isError ? "auth.url-error" : "auth.url-hint")
      }
    }
  }

  private var managedSection: some View {
    ServerSection(
      title: "Provided by your organization",
      footer: directory.serversAreForced ? "Your organization manages this list." : nil
    ) {
      ForEach(directory.managed) { server in
        ServerRow(
          title: ServerText.escaped(server.displayName, limit: 80),
          subtitle: server.authority == server.displayName ? nil : server.authority,
          systemImage: "building.2", isManaged: true,
          identifier: "auth.managed-server"
        ) {
          choose(server.url)
        }
      }
    }
  }

  private var recentSection: some View {
    ServerSection(title: "Recent servers", footer: nil) {
      ForEach(directory.recentServers, id: \.self) { url in
        ServerRow(
          title: ServerIdentity.hostLabel(url),
          subtitle: url == ServerIdentity.hostLabel(url)
            ? nil : ServerText.escaped(url, limit: 120),
          systemImage: "clock.arrow.circlepath", isManaged: false,
          identifier: "auth.recent-server",
          forget: { actions.forgetServer(url) },
          action: { choose(url) }
        )
      }
    }
  }

  private func choose(_ url: String) {
    serverUrl = url
    connect()
  }

  private func connect() {
    revealsValidation = true
    guard case .valid(let normalized) = validator.check(serverUrl) else { return }
    actions.connect(normalized)
  }
}

private struct ServerSection<Rows: View>: View {
  let title: String
  let footer: String?
  @ViewBuilder var rows: Rows

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) {
        rows
      }
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: AuthMetrics.radius))
      .overlay {
        RoundedRectangle(cornerRadius: AuthMetrics.radius)
          .strokeBorder(.separator, lineWidth: 0.5)
      }
      if let footer {
        Text(footer)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct ServerRow: View {
  let title: String
  let subtitle: String?
  let systemImage: String
  let isManaged: Bool
  let identifier: String
  var forget: (@MainActor () -> Void)?
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      Button(action: action) {
        HStack(spacing: 10) {
          Image(systemName: systemImage)
            .foregroundStyle(.secondary)
            .frame(width: 20)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
              .lineLimit(1)
            if let subtitle {
              Text(verbatim: subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
          Spacer(minLength: 0)
          if isManaged {
            Text("Managed")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.quaternary, in: Capsule())
              .foregroundStyle(.primary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint("Connects to this server")
      .accessibilityIdentifier(identifier)
      if let forget {
        Button {
          forget()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .opacity(forgetVisible ? 1 : 0)
        .help("Forget this server")
        .accessibilityLabel("Forget \(title)")
        .accessibilityIdentifier("auth.forget-server")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(isHovered ? Color.primary.opacity(0.05) : .clear)
    .onHover { isHovered = $0 }
    .contextMenu {
      if let forget {
        Button("Forget Server", systemImage: "trash", role: .destructive) { forget() }
      }
    }
  }

  /// The forget button shows on hover with a pointer, and always on touch.
  private var forgetVisible: Bool {
    #if os(macOS)
      isHovered
    #else
      true
    #endif
  }

  private var accessibilityLabel: String {
    var label = title
    if let subtitle { label += ", \(subtitle)" }
    if isManaged { label += ", managed by your organization" }
    return label
  }
}

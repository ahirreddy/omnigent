import OmnigentCoreFFI
import OmnigentPlatform
import OmnigentStores
public import SwiftUI

/// Server URL form that runs discovery and shows the server name, version and sign-in mode.
///
/// It connects to the stored server URL as soon as it first appears.
public struct ConnectView: View {
  @Environment(ConnectionStore.self) private var store
  @AppStorage(OmnigentDefaults.serverURLKey) private var serverURL = OmnigentDefaults
    .defaultServerURL

  /// Creates the form; it reads the ``ConnectionStore`` from the environment.
  public init() {}

  /// The form.
  public var body: some View {
    Form {
      Section {
        TextField("Server URL", text: $serverURL, prompt: Text(OmnigentDefaults.defaultServerURL))
          .textContentType(.URL)
          .autocorrectionDisabled()
          #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
          #endif
          .onSubmit(connect)
          .accessibilityIdentifier("connect.serverURL")
        Button(action: connect) {
          Text("Connect").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(store.isLoading || serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityIdentifier("connect.button")
      } header: {
        Text("Server")
      } footer: {
        Text("Omnigent core \(coreVersion())")
      }
      status
    }
    .formStyle(.grouped)
    .navigationTitle("Connect")
    .task {
      if store.state == .idle { connect() }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: connect) {
          Label("Reconnect", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoading)
        .help("Reconnect to the server")
      }
    }
  }

  @ViewBuilder private var status: some View {
    switch store.state {
    case .idle:
      Section("Status") {
        Text("Not connected").foregroundStyle(.secondary)
      }
    case .loading(let url):
      Section("Status") {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Connecting to \(url)")
        }
      }
    case .connected(let discovery):
      Section("Server Info") {
        LabeledContent("Name", value: discovery.serverName ?? "Unnamed server")
          .accessibilityIdentifier("connect.serverName")
        LabeledContent("Version", value: discovery.serverVersion ?? "Unknown")
          .accessibilityIdentifier("connect.serverVersion")
        LabeledContent("Sign-in", value: discovery.authMode?.displayName ?? "Not advertised")
          .accessibilityIdentifier("connect.authMode")
        LabeledContent("URL", value: discovery.baseUrl)
      }
    case .failed(let url, let message):
      Section("Status") {
        Label {
          VStack(alignment: .leading, spacing: 4) {
            Text("Could not connect to \(url)").font(.headline)
            Text(message).textSelection(.enabled)
          }
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .accessibilityIdentifier("connect.error")
        Button("Copy Error") { Pasteboard.copy(message) }
      }
    }
  }

  private func connect() {
    let url = serverURL
    Task { await store.discover(serverURL: url) }
  }
}

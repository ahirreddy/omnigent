public import SwiftUI

/// Settings › Phone on the Mac: a QR code the iPhone app scans to add a server. The code holds
/// only the server's address; the phone signs in on its own.
public struct PairingSettingsView: View {
  private let servers: [String]
  @State private var selected: String?

  /// Creates the pane.
  /// - Parameter servers: Server URLs to offer, the most relevant first (open windows, then
  ///   recents).
  public init(servers: [String]) {
    self.servers = servers
    _selected = State(initialValue: servers.first)
  }

  /// The pane.
  public var body: some View {
    Form {
      if servers.isEmpty {
        Section {
          Text("Connect to a server first. Its pairing code shows here.")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("pairing.no-servers")
        }
      } else {
        Section {
          Picker("Server", selection: $selected) {
            ForEach(servers, id: \.self) { url in
              Text(verbatim: ServerIdentity.hostLabel(url)).tag(Optional(url))
            }
          }
          .accessibilityIdentifier("pairing.server-picker")
          if let selected {
            code(for: selected)
          }
        } header: {
          Text("Pair your iPhone")
        } footer: {
          Text(
            """
            In Omnigent on your iPhone, tap Scan Pairing Code on the Connect screen, or point \
            the Camera at the code. The code holds only the server address, never a password \
            or token; your phone confirms the server and signs in on its own.
            """)
        }
      }
    }
    .formStyle(.grouped)
    .accessibilityIdentifier("pairing.settings")
  }

  @ViewBuilder private func code(for url: String) -> some View {
    HStack {
      Spacer()
      PairingQRCodeView(code: PairingCode(serverURL: url))
        .frame(width: 200, height: 200)
      Spacer()
    }
    LabeledContent("Address") {
      Text(verbatim: url)
        .textSelection(.enabled)
        .lineLimit(2)
        .truncationMode(.middle)
        .accessibilityIdentifier("pairing.address")
    }
    if PairingCode.isLoopback(url) {
      Label(
        """
        This server is only reachable from this Mac. To use it from your phone, connect to it \
        through an address your phone can reach, such as a tunnel or your network name.
        """,
        systemImage: "exclamationmark.triangle"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("pairing.loopback-warning")
    }
  }
}

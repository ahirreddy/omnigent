import Foundation
public import SwiftUI

/// The web's "Connect a host" dialog: the `omni host` command for this server, and on a Mac
/// that can run hosts, "Use This Mac" to connect it without a terminal.
public struct ConnectHostSheet: View {
  private let serverURL: String
  private let useThisMachine: (@MainActor () async -> String?)?
  private let close: @MainActor () -> Void
  @State private var isConnecting = false
  @State private var status: String?

  /// Creates the sheet.
  /// - Parameters:
  ///   - serverURL: The server the host connects to.
  ///   - useThisMachine: Connects this Mac as a host; returns a status line, or `nil` when it
  ///     did not start. `nil` hides the button.
  ///   - close: Closes the sheet.
  public init(
    serverURL: String, useThisMachine: (@MainActor () async -> String?)? = nil,
    close: @escaping @MainActor () -> Void
  ) {
    self.serverURL = serverURL
    self.useThisMachine = useThisMachine
    self.close = close
  }

  /// The sheet.
  public var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Run this on the machine the agents should work on:")
          CopyCommandButton(command: "omni host --server \(Self.shellQuoted(serverURL))")
        } footer: {
          Text("The host appears in the Host menu once it connects.")
        }
        if let useThisMachine {
          Section {
            HStack {
              Button("Use This Mac") {
                isConnecting = true
                Task {
                  status = await useThisMachine()
                  isConnecting = false
                }
              }
              .disabled(isConnecting)
              .accessibilityIdentifier("connect-host-this-machine")
              if isConnecting { ProgressView().controlSize(.small) }
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
          } footer: {
            Text("Runs the Omnigent host on this Mac for this server.")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Connect a Host")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: close)
        }
      }
    }
    #if os(macOS)
      .frame(width: 480)
    #endif
    .accessibilityIdentifier("connect-host-sheet")
  }

  /// Single-quotes a shell argument when it needs it.
  static func shellQuoted(_ value: String) -> String {
    let safe = value.allSatisfy { $0.isLetter || $0.isNumber || "-_./:@%+=,".contains($0) }
    return safe ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

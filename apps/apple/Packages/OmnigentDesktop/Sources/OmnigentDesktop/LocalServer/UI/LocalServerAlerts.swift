public import AppKit

/// The native confirmation before this Mac hosts agents for a server. It is a sheet on the key
/// window (an app-modal alert when there is none), and Cancel is the default button, because
/// host mode lets the server run agents that execute commands and change files as this user.
public enum HostModeConfirmation {
  /// The alert's text, for tests and screenshots.
  /// - Parameter serverURL: The server.
  /// - Returns: Title and message.
  public static func text(serverURL: URL) -> (title: String, message: String) {
    let server = serverURL.host(percentEncoded: false) ?? serverURL.absoluteString
    let local = ["127.0.0.1", "localhost", "::1"].contains(server)
    return (
      "Allow agents to run on this Mac?",
      """
      Host mode connects this Mac to \(local ? "the local server" : server) so its sessions can \
      run agents here. Agents run commands, read and change files, and use the network with \
      your account's permissions.

      Only host for a server you trust. Stop hosting at any time from the Server menu or the \
      menu bar.
      """
    )
  }

  /// Asks the user.
  /// - Parameter serverURL: The server to host for.
  /// - Returns: Whether the user chose Start Hosting.
  public static func confirm(serverURL: URL) async -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    let text = text(serverURL: serverURL)
    alert.messageText = text.title
    alert.informativeText = text.message
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Start Hosting")
    return await DesktopAlert.present(alert) == .alertSecondButtonReturn
  }
}

/// Offers to open a window on a local server the user just started.
public enum LocalServerReadyAlert {
  /// Asks the user.
  /// - Parameter endpoint: The ready server.
  /// - Returns: Whether the user chose Open Window.
  public static func confirm(_ endpoint: LocalServerEndpoint) async -> Bool {
    let alert = NSAlert()
    alert.messageText = "The local server is ready"
    alert.informativeText =
      "Omnigent is running on this Mac at \(endpoint.url.absoluteString). Open a window on it?"
    alert.addButton(withTitle: "Open Window")
    alert.addButton(withTitle: "Not Now")
    return await DesktopAlert.present(alert) == .alertFirstButtonReturn
  }
}

/// Presents alerts as a sheet on the main window, or app-modally when none is open (for example
/// when the request came from the menu bar extra, whose panel cannot hold a sheet).
enum DesktopAlert {
  static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    NSApplication.shared.activate()
    guard let window = NSApplication.shared.mainWindow, window.isVisible,
      window.attachedSheet == nil
    else {
      return alert.runModal()
    }
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
    }
  }
}

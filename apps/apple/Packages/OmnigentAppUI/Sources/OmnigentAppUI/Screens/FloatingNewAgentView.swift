#if os(macOS)
  public import OmnigentStores
  public import SwiftUI

  /// The floating New Agent panel's content (the desktop app's `/compose/floating`): the New
  /// Session composer on its own, offering only this Mac and new sandboxes. Command-Return
  /// starts the session; `opened` receives it once its first message is on its way, and a start
  /// that fails keeps the prompt here with the reason.
  public struct FloatingNewAgentView: View {
    private let connection: ConnectionStore
    private let opened: @MainActor (String) -> Void

    /// Creates the panel's content.
    /// - Parameters:
    ///   - connection: The server the session starts on.
    ///   - opened: Receives the started session's id.
    public init(connection: ConnectionStore, opened: @escaping @MainActor (String) -> Void) {
      self.connection = connection
      self.opened = opened
    }

    /// The composer, below the panel's Close button.
    public var body: some View {
      NewSessionContainer(
        connection: connection, open: opened, isFloating: true, onlyThisMachine: true
      )
      // Below the title bar's Close button.
      .padding(.top, 24)
      .padding([.horizontal, .bottom], 12)
      .accessibilityIdentifier("floating-new-agent")
    }
  }
#endif

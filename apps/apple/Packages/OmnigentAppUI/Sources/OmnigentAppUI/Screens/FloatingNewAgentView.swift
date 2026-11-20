#if os(macOS)
  public import OmnigentStores
  import OmnigentUIComponents
  public import SwiftUI

  /// The floating New Agent panel's content (the desktop app's `/compose/floating`): the New
  /// Session composer as the panel's whole content, offering only this Mac and new sandboxes.
  /// Command-Return starts the session (shown beside Send; Return adds a line); `opened`
  /// receives it once its first message is on its way, and a start that fails keeps the prompt
  /// here with the reason.
  public struct FloatingNewAgentView: View {
    private let connection: ConnectionStore
    private let opened: @MainActor (String) -> Void
    private let claimsEscape: @MainActor (Bool) -> Void

    /// Creates the panel's content.
    /// - Parameters:
    ///   - connection: The server the session starts on.
    ///   - claimsEscape: Told whether the composer answers Escape itself (its completion list
    ///     is open), so the panel leaves Escape to it.
    ///   - opened: Receives the started session's id.
    public init(
      connection: ConnectionStore, claimsEscape: @escaping @MainActor (Bool) -> Void = { _ in },
      opened: @escaping @MainActor (String) -> Void
    ) {
      self.connection = connection
      self.claimsEscape = claimsEscape
      self.opened = opened
    }

    /// The composer, below the panel's Close button.
    public var body: some View {
      NewSessionContainer(
        connection: connection, open: opened, isFloating: true, onlyThisMachine: true
      )
      .environment(\.composerFillsWindow, true)
      // Below the title bar's Close button.
      .padding(.top, 24)
      .padding([.horizontal, .bottom], 12)
      .accessibilityIdentifier("floating-new-agent")
      .onPreferenceChange(ComposerClaimsEscape.self) { claimed in claimsEscape(claimed) }
    }
  }
#endif

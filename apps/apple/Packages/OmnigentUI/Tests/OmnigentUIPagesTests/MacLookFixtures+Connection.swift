import SwiftUI

@testable import OmnigentUIComponents

extension LookFixtures {
  // MARK: Connection

  /// A session's detail while the server is away, coming back and back: the connection line on
  /// top and the transcript. The composer's line shows offline only; while the window's line
  /// covers an outage, the composer does not repeat it.
  @ViewBuilder
  static func connection(_ screen: LookScreen) -> some View {
    VStack(spacing: 0) {
      switch screen {
      case .connectionReconnecting:
        ConnectionStatusBanner(
          state: .reconnecting(detail: "Could not connect to the server."), retry: {})
      case .connectionUnreachable:
        ConnectionStatusBanner(
          state: .unreachable(detail: "The network connection was lost."), retry: {})
      case .connectionReconnected:
        ConnectionStatusBanner(state: .reconnected, retry: {})
      default:
        EmptyView()
      }
      connectionTranscript
      if let notice = connectionNotice(screen) {
        ConnectionNoticeRow(notice: notice, reconnect: {}).padding(.vertical, Theme.Spacing.small)
      }
      if screen == .connectionOffline {
        SessionListOfflineBar(message: "Offline \u{2014} showing saved sessions", retry: {})
      }
    }
  }

  private static func connectionNotice(_ screen: LookScreen) -> ComposerConnectionNotice? {
    switch screen {
    case .connectionOffline:
      ComposerConnectionNotice(
        message: "Offline \u{2014} showing saved messages", isOffline: true)
    default: nil
    }
  }

  /// A few lines of a conversation under the connection line.
  private static var connectionTranscript: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text("Run the test suite and fix what fails.")
        .padding(Theme.Spacing.medium)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .frame(maxWidth: .infinity, alignment: .trailing)
      Text(
        "All 214 tests pass. Two were flaky on the first run; both now wait for the server to answer."
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.body)
    .padding(Theme.Spacing.large)
    .frame(maxWidth: .infinity, alignment: .top)
  }
}

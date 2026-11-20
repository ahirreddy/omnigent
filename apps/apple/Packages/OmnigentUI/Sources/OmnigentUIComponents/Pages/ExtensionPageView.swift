public import SwiftUI

/// An extension's page, as the web's `ExtensionViewHost` shows it: a spinner while its bundle
/// loads and the page activates, the page itself once it says it is ready, and why it could not
/// start, with Retry.
public struct ExtensionPageView: View {
  let state: ExtensionPageState
  let channel: ExtensionFrameChannel
  let actions: ExtensionPageActions

  @Environment(\.colorScheme) private var colorScheme

  /// Creates the page.
  /// - Parameters:
  ///   - state: Where the page stands.
  ///   - channel: The relay to its frame.
  ///   - actions: Retry and the appearance.
  public init(
    state: ExtensionPageState, channel: ExtensionFrameChannel, actions: ExtensionPageActions
  ) {
    self.state = state
    self.channel = channel
    self.actions = actions
  }

  /// The page.
  public var body: some View {
    ZStack {
      if let hostPage = state.hostPage, showsFrame {
        ExtensionFrameView(hostPage: hostPage, title: state.title, channel: channel)
          .id(state.mountID)
          .accessibilityIdentifier("extension-page-frame")
      }
      overlay
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(state.title)
    .onChange(of: colorScheme, initial: true) { _, scheme in
      actions.themeChanged(scheme == .dark)
    }
  }

  private var showsFrame: Bool {
    switch state.phase {
    case .activating, .ready: true
    case .loading, .failed, .notFound: false
    }
  }

  @ViewBuilder private var overlay: some View {
    switch state.phase {
    case .loading, .activating:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityLabel("Loading extension")
        .accessibilityIdentifier("extension-page-loading")
    case .ready:
      EmptyView()
    case .failed(let message):
      ContentUnavailableView {
        Label(state.failureTitle, systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("Retry", action: actions.retry)
          .accessibilityIdentifier("extension-page-retry")
      }
      .accessibilityIdentifier("extension-page-error")
    case .notFound:
      ContentUnavailableView {
        Label("Page not found", systemImage: "puzzlepiece.extension")
      } description: {
        Text("The URL you followed doesn\u{2019}t match any route in this app.")
      }
      .accessibilityIdentifier("extension-page-not-found")
    }
  }
}

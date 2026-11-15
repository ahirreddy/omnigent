public import SwiftUI

/// What the new-session page shows before its composer can, such as an Add nested agent page
/// whose source is loading or can't be read: one line, a spinner while waiting, and an optional
/// way on.
public struct NewSessionNotice: View {
  private let title: String
  private let message: String
  private let isWaiting: Bool
  private let action: (title: String, run: @MainActor () -> Void)?

  /// Creates the notice.
  /// - Parameters:
  ///   - title: The navigation title.
  ///   - message: The line to show.
  ///   - isWaiting: Shows a spinner above it.
  ///   - action: A button under it, such as "Continue in a new session".
  public init(
    title: String, message: String, isWaiting: Bool = false,
    action: (title: String, run: @MainActor () -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.isWaiting = isWaiting
    self.action = action
  }

  /// The notice.
  public var body: some View {
    VStack(spacing: Theme.Spacing.large) {
      if isWaiting {
        ProgressView()
      }
      Text(message)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("new-session-notice")
      if let action {
        Button(action.title, action: action.run)
          .accessibilityIdentifier("new-session-notice-action")
      }
    }
    .padding(Theme.Spacing.extraLarge)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themeCanvas()
    .navigationTitle(title)
  }
}

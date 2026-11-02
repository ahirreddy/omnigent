public import SwiftUI

/// Opens Settings › Notifications on iPhone and iPad (the Mac has its Settings window). Like
/// ``OpenAppearanceSettingsAction`` it holds no closure, so it stays equal across updates.
public struct OpenNotificationSettingsAction: Equatable {
  private let presenter: NotificationSettingsPresenter

  /// Creates the action.
  /// - Parameter presenter: The scene's presenter.
  public init(presenter: NotificationSettingsPresenter) {
    self.presenter = presenter
  }

  /// Opens the settings.
  @MainActor public func callAsFunction() { presenter.open?() }

  /// Equal for the same scene's presenter.
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.presenter === rhs.presenter }
}

/// Presents a scene's notification settings; the host refreshes ``open`` on each update.
@MainActor
public final class NotificationSettingsPresenter {
  /// Shows the settings.
  public var open: (@MainActor () -> Void)?

  /// Creates a presenter.
  public init() {}
}

extension EnvironmentValues {
  /// Opens Settings › Notifications; `nil` hides the menu item.
  @Entry public var openNotificationSettings: OpenNotificationSettingsAction?
}

public import SwiftUI

/// Opens the Settings screen on iPhone and iPad (the Mac has its Settings window). Like
/// ``OpenNotificationSettingsAction`` it holds no closure, so it stays equal across updates.
public struct OpenSettingsScreenAction: Equatable {
  private let presenter: SettingsScreenPresenter

  /// Creates the action.
  /// - Parameter presenter: The scene's presenter.
  public init(presenter: SettingsScreenPresenter) {
    self.presenter = presenter
  }

  /// Opens the settings.
  @MainActor public func callAsFunction() { presenter.open?() }

  /// Equal for the same scene's presenter.
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.presenter === rhs.presenter }
}

/// Presents a scene's Settings screen; the host sets ``open``.
@MainActor
public final class SettingsScreenPresenter {
  /// Shows the settings.
  public var open: (@MainActor () -> Void)?

  /// Creates a presenter.
  public init() {}
}

extension EnvironmentValues {
  /// Opens the Settings screen; `nil` keeps the server menu's separate Appearance and
  /// Notifications items.
  @Entry public var openSettingsScreen: OpenSettingsScreenAction?
}

extension View {
  /// A button inside a settings row: borderless on iPhone and iPad, where a row with plain
  /// buttons fires all of them on any tap; the platform style on the Mac.
  /// - Returns: The view.
  func settingsRowButton() -> some View {
    #if os(iOS)
      buttonStyle(.borderless)
    #else
      self
    #endif
  }

  /// A settings sheet's fixed size on the Mac; iPhone and iPad sheets size themselves.
  /// - Parameters:
  ///   - width: The width.
  ///   - height: The height, or `nil` to fit.
  /// - Returns: The view.
  func settingsSheetFrame(width: CGFloat, height: CGFloat? = nil) -> some View {
    #if os(macOS)
      frame(width: width, height: height)
    #else
      self
    #endif
  }
}

/// Where device-local settings are kept, for footers ("Saved on this Mac.").
enum SettingsDevice {
  /// "Mac" on the Mac, "device" on iPhone and iPad.
  static let name: String = {
    #if os(macOS)
      "Mac"
    #else
      "device"
    #endif
  }()
}

import OmnigentPlatform
public import SwiftUI

/// Copies text and confirms it, as the web's toasts do ("Link copied"): a short banner, and a
/// haptic on touch. Outside a ``View/copyConfirmations()`` host it only copies. It holds no
/// closure, so it stays equal across updates.
public struct CopyAction: Equatable {
  let presenter: CopyConfirmationPresenter?

  /// Copies `text` and shows `confirmation`.
  /// - Parameters:
  ///   - text: What to copy.
  ///   - confirmation: For example "Link copied".
  @MainActor public func callAsFunction(_ text: String, confirmation: String) {
    Pasteboard.copy(text)
    presenter?.confirm?(confirmation)
  }

  /// Equal for the same window's presenter.
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.presenter === rhs.presenter }
}

/// Shows a window's copy confirmations; the host refreshes ``confirm`` on each update.
@MainActor
final class CopyConfirmationPresenter {
  var confirm: (@MainActor (String) -> Void)?
}

extension EnvironmentValues {
  /// Copies with a confirmation; only copies outside a ``View/copyConfirmations()`` host.
  @Entry public var copyWithConfirmation = CopyAction(presenter: nil)
}

extension View {
  /// Confirms the copies made below with ``CopyAction`` in a banner at the bottom.
  /// - Returns: The view.
  public func copyConfirmations() -> some View {
    modifier(CopyConfirmationHost())
  }
}

private struct CopyConfirmationHost: ViewModifier {
  @State private var presenter = CopyConfirmationPresenter()
  @State private var banner: TransientBanner?

  func body(content: Content) -> some View {
    presenter.confirm = { banner = TransientBanner(message: $0) }
    return
      content
      .environment(\.copyWithConfirmation, CopyAction(presenter: presenter))
      .transientBanner($banner)
      #if os(iOS)
        .sensoryFeedback(.success, trigger: banner?.id) { _, new in new != nil }
      #endif
  }
}

/// A menu or context-menu item that copies with a confirmation.
struct ConfirmedCopyButton: View {
  let title: String
  let systemImage: String
  let text: String
  let confirmation: String
  @Environment(\.copyWithConfirmation) private var copy

  var body: some View {
    Button(title, systemImage: systemImage) { copy(text, confirmation: confirmation) }
  }
}

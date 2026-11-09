public import SwiftUI

/// A short confirmation that hides itself (the web's toasts): "Reply sent to Fix tests",
/// optionally with one action such as Open.
nonisolated public struct TransientBanner: Hashable, Sendable, Identifiable {
  /// Distinguishes repeats of the same message, so each one restarts the timer.
  public var id = UUID()
  /// What happened.
  public var message: String
  /// The action's title, when it has one.
  public var actionTitle: String?

  /// Creates a banner.
  public init(message: String, actionTitle: String? = nil) {
    self.message = message
    self.actionTitle = actionTitle
  }
}

extension View {
  /// Shows `banner` at the bottom for a few seconds, announced to VoiceOver.
  /// - Parameters:
  ///   - banner: The banner; cleared when it hides.
  ///   - action: Runs the banner's action.
  /// - Returns: The view.
  public func transientBanner(
    _ banner: Binding<TransientBanner?>, action: (@MainActor (TransientBanner) -> Void)? = nil
  ) -> some View {
    modifier(TransientBannerPresenter(banner: banner, action: action))
  }
}

struct TransientBannerPresenter: ViewModifier {
  @Binding var banner: TransientBanner?
  let action: (@MainActor (TransientBanner) -> Void)?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var duration: Duration = .seconds(4)

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let current = banner {
          bar(current)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: current.id) {
              AccessibilityNotification.Announcement(current.message).post()
              do {
                try await Task.sleep(for: duration)
              } catch {
                return  // Replaced or dismissed; the newer banner owns the timer.
              }
              hide(current)
            }
        }
      }
      .animation(reduceMotion ? nil : Theme.Motion.feedback, value: banner)
  }

  private func bar(_ current: TransientBanner) -> some View {
    HStack(spacing: Theme.Spacing.medium) {
      Label(current.message, systemImage: "checkmark.circle").font(.callout)
      if let title = current.actionTitle, let action {
        Button(title) {
          action(current)
          hide(current)
        }
        .buttonStyle(.borderless)
        .fontWeight(.semibold)
        .accessibilityIdentifier("transient-banner-action")
      }
    }
    .padding(.horizontal, Theme.Spacing.large)
    .padding(.vertical, Theme.Spacing.small)
    .glassSurface(in: Capsule())
    .padding(Theme.Spacing.large)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("transient-banner")
  }

  private func hide(_ current: TransientBanner) {
    if banner?.id == current.id { banner = nil }
  }
}

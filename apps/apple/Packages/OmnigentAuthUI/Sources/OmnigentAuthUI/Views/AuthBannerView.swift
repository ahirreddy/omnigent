public import SwiftUI

/// A notice or a connection error above a form.
///
/// Errors show a short title, the core's message, and the server's refusal reason verbatim in its
/// own box: rendered with `Text(verbatim:)` (no Markdown, no links) after ``ServerText/escaped(_:limit:)``,
/// and selectable so it can be copied into a support request. Retryable errors offer Retry.
public struct AuthBannerView: View {
  private let banner: AuthBanner
  private let title: String?
  private let retry: (@MainActor () -> Void)?

  /// Creates a banner.
  /// - Parameters:
  ///   - banner: The notice or error.
  ///   - title: Replaces the error's own title, for a form that knows better (for example
  ///     "Couldn't sign in" on the password form).
  ///   - retry: Called by Retry; omit to hide Retry.
  public init(_ banner: AuthBanner, title: String? = nil, retry: (@MainActor () -> Void)? = nil) {
    self.banner = banner
    self.title = title
    self.retry = retry
  }

  /// The banner.
  public var body: some View {
    switch banner {
    case .notice(let text):
      Label {
        Text(verbatim: ServerText.escaped(text))
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "info.circle.fill")
          .foregroundStyle(.blue)
          .accessibilityHidden(true)
      }
      .font(.callout)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: AuthMetrics.radius))
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("auth.notice")
    case .error(let error):
      ErrorBody(error: error, title: title ?? error.title, retry: retry)
    }
  }
}

private struct ErrorBody: View {
  let error: SignInError
  let title: String
  let retry: (@MainActor () -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(.red)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.callout.weight(.semibold))
          if let detail = error.detail {
            Text(verbatim: ServerText.escaped(detail))
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 0)
      }
      if let reason = error.refusalReason {
        ServerReasonView(reason: reason)
      }
      if let retry, error.isRetryable {
        HStack {
          Spacer()
          Button("Retry", systemImage: "arrow.clockwise", action: retry)
            .controlSize(.small)
            .accessibilityIdentifier("auth.retry")
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: AuthMetrics.radius))
    .overlay {
      RoundedRectangle(cornerRadius: AuthMetrics.radius)
        .strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("auth.error")
  }

  private var symbol: String {
    switch error.category {
    case .transport: "wifi.exclamationmark"
    case .invalidUrl: "link.badge.plus"
    case .httpStatus, .decode, .auth, .oidc, .secureStore, .other:
      error.failure == .transport ? "wifi.exclamationmark" : "exclamationmark.triangle.fill"
    }
  }
}

/// The server's reason, verbatim.
struct ServerReasonView: View {
  let reason: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("The server said:")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(verbatim: ServerText.escaped(reason))
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("The server said: \(ServerText.escaped(reason))")
    .accessibilityIdentifier("auth.server-reason")
  }
}

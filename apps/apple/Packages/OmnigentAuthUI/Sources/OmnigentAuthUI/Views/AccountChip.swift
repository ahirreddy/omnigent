public import SwiftUI

/// The signed-in account as a compact chip, for a toolbar or sidebar footer. Its menu names the
/// account and server and offers Sign Out.
public struct AccountChip: View {
  private let account: SignedInAccount
  private let actions: AuthActions

  /// Creates the chip.
  /// - Parameters:
  ///   - account: The connected account.
  ///   - actions: The store's actions.
  public init(account: SignedInAccount, actions: AuthActions) {
    self.account = account
    self.actions = actions
  }

  /// The chip.
  public var body: some View {
    Menu {
      Section {
        Text(verbatim: "Signed in as \(account.userLabel)")
        Text(verbatim: account.server.displayName)
        if account.server.displayName != account.server.hostLabel {
          Text(verbatim: account.server.hostLabel)
        }
      }
      if account.canSignOut {
        Divider()
        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
          actions.signOut()
        }
        .accessibilityIdentifier("auth.sign-out")
      }
    } label: {
      AccountChipLabel(account: account)
    }
    // A plain button-style menu draws the custom label; the default macOS style would replace
    // it with a pop-up button.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("\(account.userLabel) on \(account.server.displayName)")
    .accessibilityLabel("Account: \(account.userLabel) on \(account.server.displayName)")
    .accessibilityHint(account.canSignOut ? "Shows the account menu with Sign Out" : "")
    .accessibilityIdentifier("auth.account-chip")
  }
}

/// The chip's face: an initial avatar, the user, and the server.
struct AccountChipLabel: View {
  let account: SignedInAccount

  var body: some View {
    HStack(spacing: 8) {
      Text(verbatim: initial)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(Circle().fill(.tint))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(verbatim: account.userLabel)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(verbatim: account.server.displayName)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Image(systemName: "chevron.up.chevron.down")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .padding(.leading, 4)
    .padding(.trailing, 8)
    .padding(.vertical, 4)
    .background(.background.secondary, in: Capsule())
    .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
    .contentShape(Capsule())
  }

  private var initial: String {
    let first = account.userLabel.first { $0.isLetter || $0.isNumber }
    return first.map { String($0).uppercased() } ?? "?"
  }
}

/// The connected state inside the sign-in flow: confirms who is signed in where.
public struct SignedInView: View {
  private let account: SignedInAccount
  private let actions: AuthActions

  /// Creates the view.
  /// - Parameters:
  ///   - account: The connected account.
  ///   - actions: The store's actions.
  public init(account: SignedInAccount, actions: AuthActions) {
    self.account = account
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    AuthCard(
      systemImage: "checkmark.circle", title: "Signed in",
      subtitle: "You\u{2019}re connected to \(account.server.displayName)."
    ) {
      HStack {
        AccountChip(account: account, actions: actions)
        Spacer(minLength: 0)
      }
    } buttons: {
      if account.canSignOut {
        AuthButton(title: "Sign Out", kind: .secondary, identifier: "auth.sign-out-button") {
          actions.signOut()
        }
      }
    }
    .accessibilityIdentifier("auth.signed-in")
  }
}

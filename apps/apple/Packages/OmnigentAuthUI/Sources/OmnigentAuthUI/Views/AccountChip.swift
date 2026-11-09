public import SwiftUI

/// The signed-in account as a compact chip, or as the row at the foot of the sidebar. Its menu
/// names the account and server and offers Sign Out.
public struct AccountChip: View {
  /// How the account draws.
  public enum Style: Sendable {
    /// A capsule at its own size.
    case chip
    /// A row as wide as the sidebar, at its foot.
    case sidebarFooter
  }

  private let account: SignedInAccount
  private let style: Style
  private let signOut: (@MainActor () -> Void)?

  /// Creates the chip.
  /// - Parameters:
  ///   - account: The connected account.
  ///   - actions: The store's actions.
  public init(account: SignedInAccount, actions: AuthActions) {
    self.init(account: account, style: .chip, signOut: actions.signOut)
  }

  /// Creates the account in a style.
  /// - Parameters:
  ///   - account: The connected account.
  ///   - style: A chip or the sidebar's footer row.
  ///   - signOut: Signs out; `nil` leaves Sign Out out of the menu.
  public init(account: SignedInAccount, style: Style, signOut: (@MainActor () -> Void)?) {
    self.account = account
    self.style = style
    self.signOut = signOut
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
      if account.canSignOut, let signOut {
        Divider()
        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
          signOut()
        }
        .accessibilityIdentifier("auth.sign-out")
      }
    } label: {
      switch style {
      case .chip: AccountChipLabel(account: account)
      case .sidebarFooter: AccountFooterLabel(account: account)
      }
    }
    // A plain button-style menu draws the custom label; the default macOS style would replace
    // it with a pop-up button.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: style == .chip, vertical: true)
    .help("\(account.userLabel) on \(account.server.displayName)")
    .accessibilityLabel("Account: \(account.userLabel) on \(account.server.displayName)")
    .accessibilityHint(
      account.canSignOut && signOut != nil ? "Shows the account menu with Sign Out" : ""
    )
    .accessibilityIdentifier("auth.account-chip")
  }
}

/// The chip's face: an initial avatar, the user, and the server.
struct AccountChipLabel: View {
  let account: SignedInAccount

  var body: some View {
    HStack(spacing: 8) {
      AccountAvatar(account: account)
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
}

/// The sidebar footer's face: the avatar, the user over the server, and the menu's chevrons,
/// across the sidebar's width. A narrow sidebar shortens the names, not the row.
struct AccountFooterLabel: View {
  let account: SignedInAccount
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    HStack(spacing: 8) {
      AccountAvatar(account: account)
      VStack(alignment: .leading, spacing: 0) {
        Text(verbatim: account.userLabel)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(verbatim: account.server.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Image(systemName: "chevron.up.chevron.down")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.fill.tertiary.opacity(isHovered ? 1 : 0), in: shape)
    .contentShape(shape)
    .onHover { isHovered = $0 }
  }
}

/// The account's initial in a tinted circle.
struct AccountAvatar: View {
  let account: SignedInAccount

  var body: some View {
    Text(verbatim: initial)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)
      .frame(width: 22, height: 22)
      .background(Circle().fill(.tint))
      .accessibilityHidden(true)
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

public import SwiftUI

/// Creates an account on an accounts server: the first administrator of a new server (the web's
/// Setup page) or an invited user (its Register page, with the invite link pasted here).
///
/// Usernames are lowercased as typed, as the server stores them. The passwords are cleared once
/// submitted and when the form goes away, and never logged.
public struct CreateAccountView: View {
  private let server: ServerIdentity
  private let form: AccountForm
  private let banner: AuthBanner?
  private let isSubmitting: Bool
  private let actions: AuthActions

  @State private var inviteLink = ""
  @State private var username = ""
  @State private var password = ""
  @State private var confirmation = ""
  @FocusState private var focus: Field?

  private enum Field: Hashable {
    case invite, username, password, confirmation
  }

  /// Creates the form.
  /// - Parameters:
  ///   - server: The server to create the account on.
  ///   - form: ``AccountForm/createAdmin`` or ``AccountForm/register``.
  ///   - banner: The last failure.
  ///   - isSubmitting: Whether the account is being created.
  ///   - inviteLink: The invite link that opened the app, prefilled.
  ///   - actions: The store's actions.
  public init(
    server: ServerIdentity, form: AccountForm, banner: AuthBanner?, isSubmitting: Bool,
    inviteLink: String? = nil, actions: AuthActions
  ) {
    self.server = server
    self.form = form
    self.banner = banner
    self.isSubmitting = isSubmitting
    self.actions = actions
    _inviteLink = State(initialValue: inviteLink ?? "")
  }

  private var isInvited: Bool { form == .register }

  /// The form.
  public var body: some View {
    AuthCard(
      systemImage: isInvited ? "person.badge.plus" : "person.badge.shield.checkmark",
      title: isInvited ? "Join your team" : "Create the admin account",
      subtitle: isInvited
        ? "Paste the invite link you were sent, then choose your username and password."
        : "This server has no administrator yet. Choose the username and password for its admin; you can invite others once you\u{2019}re in."
    ) {
      ServerSummary(server: server)
      if let banner {
        AuthBannerView(banner, title: "Couldn\u{2019}t create the account", retry: actions.retry)
      }
      fields
    } buttons: {
      AuthButton(
        title: "Sign In Instead", kind: .cancel, identifier: "auth.sign-in-instead",
        action: { actions.showAccountForm(.signIn) })
      AuthButton(
        title: isSubmitting ? "Creating\u{2026}" : "Create Account", kind: .primary,
        isBusy: isSubmitting, identifier: "auth.create-account", action: submit
      )
      .disabled(!canSubmit)
    }
    .defaultFocus($focus, isInvited ? .invite : .username)
    .onDisappear {
      password = ""
      confirmation = ""
    }
  }

  private var inviteToken: String? {
    isInvited ? actions.inviteToken(inviteLink) : nil
  }

  private var canSubmit: Bool {
    !isSubmitting
      && AccountFormInput.canSubmit(
        username: username, password: password, confirmation: confirmation,
        requiresInvite: isInvited, invite: inviteToken)
  }

  private var fields: some View {
    VStack(alignment: .leading, spacing: 12) {
      if isInvited {
        LabeledField(label: "Invite link") {
          TextField(
            "Invite link", text: $inviteLink,
            prompt: Text(verbatim: "https://omnigent.example.com/register?invite=\u{2026}")
          )
          .textContentType(.URL)
          .focused($focus, equals: .invite)
          .onSubmit { focus = .username }
          .accessibilityIdentifier("auth.invite-link")
        }
        if !inviteLink.isEmpty && inviteToken == nil {
          FieldMessage(text: "That isn\u{2019}t an invite link.", isError: true)
        }
      }
      LabeledField(label: "Username") {
        TextField("Username", text: $username)
          .textContentType(.username)
          .focused($focus, equals: .username)
          .onChange(of: username) { _, newValue in
            let lowered = newValue.lowercased()
            if lowered != newValue { username = lowered }
          }
          .onSubmit { focus = .password }
          .accessibilityIdentifier("auth.new-username")
      }
      FieldMessage(
        text: "Lowercase letters, digits, dots, hyphens and underscores, or an email address.",
        isError: false)
      LabeledField(label: "Password") {
        SecureField("Password", text: $password)
          .textContentType(.newPassword)
          .focused($focus, equals: .password)
          .onSubmit { focus = .confirmation }
          .accessibilityIdentifier("auth.new-password")
      }
      LabeledField(label: "Confirm password") {
        SecureField("Confirm password", text: $confirmation)
          .textContentType(.newPassword)
          .focused($focus, equals: .confirmation)
          .onSubmit(submit)
          .accessibilityIdentifier("auth.confirm-password")
      }
      if let problem = AccountFormInput.problem(password: password, confirmation: confirmation) {
        FieldMessage(text: problem, isError: true)
      }
    }
    .disabled(isSubmitting)
  }

  private func submit() {
    guard canSubmit else { return }
    let kind: AccountCreationRequest.Kind
    if isInvited {
      guard let token = inviteToken else { return }
      kind = .invited(token: token)
    } else {
      kind = .firstAdmin
    }
    let request = AccountCreationRequest(
      kind: kind,
      credentials: AccountCredentials(
        username: AccountFormInput.normalizedUsername(username), password: password))
    password = ""
    confirmation = ""
    actions.createAccount(request)
  }
}

/// A form field with its label above, as the sign-in screens lay fields out.
struct LabeledField<Field: View>: View {
  let label: String
  @ViewBuilder var field: Field

  var body: some View {
    VStack(alignment: .leading, spacing: AuthMetrics.fieldSpacing) {
      Text(label)
        .font(.callout.weight(.medium))
        .accessibilityHidden(true)
      field
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        .accessibilityLabel(label)
    }
  }
}

/// A one-line hint or error under a field.
struct FieldMessage: View {
  let text: String
  let isError: Bool

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      .fixedSize(horizontal: false, vertical: true)
  }
}

import NativeLabCore
import SafariServices
import SwiftUI

struct LocalServerConnectionControls: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var focusedField: Field?
  @State private var method = SignInMethod.automatic
  @State private var username = ""
  @State private var password = ""
  @State private var token = ""
  @State private var remember = true
  @State private var saved: [SavedServerAccount] = []
  @State private var selected: SavedServerAccount?
  @State private var task: Task<Void, Never>?
  @State private var busy = false
  @State private var errorMessage: String?
  @State private var status: String?
  @State private var browser: LoginBrowser?
  @State private var browserLoginPending = false
  var onConnected: () -> Void = {}
  var onEditingChanged: (Bool) -> Void = { _ in }
  private let store = SecureServerStore()

  private enum Field: Hashable { case url, username, password, token }

  private enum SignInMethod: String, CaseIterable, Identifiable {
    case automatic = "Choose automatically"
    case accounts = "Username and password"
    case browser = "Browser sign-in"
    case token = "Access token"
    var id: String { rawValue }
  }

  private var isLocal: Bool {
    guard let url = URL(string: model.localServerURL),
      let endpoint = try? ServerEndpoint(baseURL: url)
    else { return false }
    return endpoint.isLocalSingleUser
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Server connection", systemImage: "network").font(.headline)
      if !saved.isEmpty {
        Menu {
          ForEach(saved) { account in
            Button(
              "\(account.userID) · \(account.serverURL.absoluteString)"
            ) {
              model.localServerURL = account.serverURL.absoluteString
              selected = account
              username = account.userID
              errorMessage = nil
            }
          }
        } label: {
          Label("Saved accounts", systemImage: "person.crop.circle")
        }
        .accessibilityIdentifier("saved-server-accounts")
        .disabled(busy || model.isConnecting)
      }
      HStack {
        TextField("https://your-server.example", text: $model.localServerURL)
          .textFieldStyle(.roundedBorder)
          .keyboardType(.URL)
          .submitLabel(.go)
          .focused($focusedField, equals: .url)
          .onSubmit { connect() }
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityLabel("Server API URL")
          .accessibilityIdentifier("local-server-url")
          .disabled(busy || model.isConnecting)
        if focusedField == .url && !model.localServerURL.isEmpty {
          Button {
            model.localServerURL = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Clear server address")
          .accessibilityIdentifier("clear-server-url")
          .disabled(busy || model.isConnecting)
        }
      }
      if isLocal {
        Text("Local development in Simulator. On a physical phone, localhost is the phone itself.")
          .font(.footnote).foregroundStyle(.secondary)
      } else {
        Text(
          "Use the HTTPS API address, including its workspace path. For Databricks workspace routing, include ?o= followed by your workspace ID."
        )
        .font(.footnote).foregroundStyle(.secondary)
        if let selected, selected.serverURL.absoluteString == model.localServerURL {
          Label("Sign in as \(selected.userID) using Keychain", systemImage: "key.fill")
            .font(.footnote)
          Button("Use a different sign-in") { self.selected = nil }
            .disabled(busy)
          Button("Forget this account", role: .destructive) { forget(selected) }
            .accessibilityIdentifier("forget-server-account")
            .disabled(busy)
        } else {
          Picker("Sign-in method", selection: $method) {
            ForEach(SignInMethod.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("server-auth-method")
          .disabled(busy)
          if method == .accounts {
            TextField("Username", text: $username)
              .focused($focusedField, equals: .username)
              .textContentType(.username).textInputAutocapitalization(.never)
              .autocorrectionDisabled().textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("server-username")
              .disabled(busy)
            SecureField("Password", text: $password)
              .focused($focusedField, equals: .password)
              .textContentType(.password).textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("server-password")
              .disabled(busy)
          } else if method == .token {
            SecureField("Access token", text: $token)
              .focused($focusedField, equals: .token)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("server-access-token")
              .disabled(busy)
            Text(
              "For workspace or proxy deployments, use a token issued for this server. Expired tokens require signing in again."
            )
            .font(.footnote).foregroundStyle(.secondary)
          }
          Toggle("Remember sign-in in Keychain", isOn: $remember)
            .accessibilityIdentifier("remember-server-sign-in")
            .disabled(busy)
        }
      }
      if let message = errorMessage ?? model.connectionError {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.red)
          .accessibilityIdentifier("connection-error")
      }
      if let status {
        Text(status).font(.footnote).accessibilityIdentifier("server-sign-in-status")
      }
      Button {
        connect()
      } label: {
        HStack {
          if busy || model.isConnecting {
            ProgressView().accessibilityIdentifier("connection-loading")
          }
          Text(
            busy || model.isConnecting
              ? "Connecting…" : (isLocal ? "Connect to local server" : "Connect to server"))
        }
        .frame(maxWidth: .infinity, minHeight: 32)
      }
      .buttonStyle(.borderedProminent)
      .disabled(busy || model.isConnecting)
      .accessibilityIdentifier("connect-local")
      if busy {
        Button("Cancel sign-in") {
          task?.cancel()
          browser = nil
        }
        .accessibilityIdentifier("cancel-server-sign-in")
      }
      Text("Connecting does not start an agent. Sending a message can run one.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .onAppear { saved = store.accounts }
    .onChange(of: focusedField) { _, field in onEditingChanged(field != nil) }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { focusedField = nil }
          .accessibilityIdentifier("dismiss-server-keyboard")
      }
    }
    .onChange(of: model.localServerURL) { _, address in
      if selected?.serverURL.absoluteString != address { selected = nil }
      password = ""
      token = ""
      errorMessage = nil
      status = nil
    }
    .onDisappear {
      // Connecting switches Settings to Sessions while initial data is still loading.
      if !model.isConnecting { task?.cancel() }
      password = ""
      token = ""
    }
    .sheet(
      item: $browser,
      onDismiss: {
        if browserLoginPending { task?.cancel() }
      },
      content: { login in ServerLoginBrowser(url: login.url) })
  }

  private func connect() {
    guard !busy, !model.isConnecting else { return }
    focusedField = nil
    busy = true
    errorMessage = nil
    status = nil
    task = Task { @MainActor in
      defer {
        busy = false
        browserLoginPending = false
        browser = nil
      }
      do {
        guard
          let url = URL(
            string: model.localServerURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw LocalServerClientError.invalidBaseURL }
        let endpoint = try ServerEndpoint(baseURL: url)
        var bearer: String?
        var identity: String?
        var expiry: Date?
        if !endpoint.isLocalSingleUser {
          if let selected, selected.serverURL == endpoint.baseURL {
            bearer = try store.credential(for: selected)
            identity = selected.userID
          } else {
            let auth = try ServerAuthenticationClient(baseURL: endpoint.baseURL)
            if method == .automatic {
              let discovery: ServerAuthenticationDiscovery
              do { discovery = try await auth.discover() } catch LocalServerClientError.unauthorized
              {
                method = .token
                status =
                  "This server requires authentication before discovery. Enter its access token, then connect."
                return
              } catch LocalServerClientError.forbidden {
                method = .token
                status =
                  "This server requires authentication before discovery. Enter its access token, then connect."
                return
              }
              if discovery.needsSetup {
                status = "Finish server account setup in its web app, then sign in here."
                return
              }
              switch discovery.mode {
              case .accounts:
                method = .accounts
                status = "Enter your username and password, then connect."
                return
              case .oidc:
                method = .browser
              case .proxy:
                method = .token
                status = "Enter an access token issued for this server, then connect."
                return
              case .localSingleUser:
                throw LocalServerClientError.unsupportedAuthentication
              }
            }
            if method == .token {
              bearer = token.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
              let credential: ServerCredential
              if method == .accounts {
                let submittedPassword = password
                password = ""
                credential = try await auth.login(username: username, password: submittedPassword)
              } else {
                let login = try await auth.beginBrowserLogin()
                try Task.checkCancellation()
                browserLoginPending = true
                browser = LoginBrowser(url: login.loginURL)
                status = "Complete sign-in in the browser. Waiting for confirmation…"
                var result: ServerCredential?
                while result == nil {
                  try Task.checkCancellation()
                  result = try await auth.pollBrowserLogin(login)
                  if result == nil { try await Task.sleep(for: .seconds(2)) }
                }
                credential = result!
                browserLoginPending = false
                browser = nil
              }
              bearer = credential.token
              identity = credential.userID
              expiry = credential.expiresAt
            }
          }
        }
        try Task.checkCancellation()
        model.localServerURL = endpoint.baseURL.absoluteString
        guard await model.connectToLocalServer(bearerToken: bearer, expectedUserID: identity) else {
          return
        }
        try Task.checkCancellation()
        if remember, selected == nil, let bearer {
          do {
            try store.save(
              token: bearer,
              account: SavedServerAccount(
                serverURL: endpoint.baseURL, userID: model.serverIdentity),
              expiresAt: expiry)
            saved = store.accounts
          } catch {
            await model.useDemo()
            throw error
          }
        }
        token = ""
        password = ""
        status = nil
        onConnected()
      } catch is CancellationError {
        status = nil
      } catch {
        errorMessage = error.localizedDescription
        status = nil
      }
    }
  }

  private func forget(_ account: SavedServerAccount) {
    do {
      try store.remove(account)
      saved = store.accounts
      selected = nil
      if model.connectedServerURL == account.serverURL.absoluteString
        && model.serverIdentity == account.userID
      {
        Task { await model.useDemo() }
      }
    } catch { errorMessage = error.localizedDescription }
  }
}

private struct LoginBrowser: Identifiable {
  let id = UUID()
  let url: URL
}

private struct ServerLoginBrowser: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> SFSafariViewController {
    SFSafariViewController(url: url)
  }
  func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

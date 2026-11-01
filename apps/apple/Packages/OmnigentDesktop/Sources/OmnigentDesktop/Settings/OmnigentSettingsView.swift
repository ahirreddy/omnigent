import AppKit
public import SwiftUI

/// The Settings window: General, Notifications and Advanced tabs. Use inside a `Settings` scene.
///
/// The package does not depend on the browser package, so the app supplies the General tab's
/// browser section (typically `OmnigentBrowser.BrowserEngineSettingsView`, which lists only the
/// engines its build offers).
public struct OmnigentSettingsView<BrowserSettings: View>: View {
  private let desktop: DesktopController
  private let recentServers: [URL]
  private let exportDiagnostics: (() -> Void)?
  private let browserSettings: BrowserSettings

  /// Creates the view.
  /// - Parameters:
  ///   - desktop: The shell services.
  ///   - recentServers: The user's recent servers, offered as the default server.
  ///   - exportDiagnostics: Shown on the Advanced tab when provided.
  ///   - browserSettings: A `Section` for the General tab's browser settings.
  public init(
    desktop: DesktopController, recentServers: [URL] = [],
    exportDiagnostics: (() -> Void)? = nil,
    @ViewBuilder browserSettings: () -> BrowserSettings
  ) {
    self.desktop = desktop
    self.recentServers = recentServers
    self.exportDiagnostics = exportDiagnostics
    self.browserSettings = browserSettings()
  }

  /// The tabs.
  public var body: some View {
    TabView {
      Tab("General", systemImage: "gearshape") {
        GeneralSettingsTab(
          preferences: desktop.preferences, managed: desktop.managedPreferences,
          recentServers: recentServers, browserSettings: browserSettings)
      }
      Tab("Notifications", systemImage: "bell.badge") {
        NotificationSettingsTab(
          preferences: desktop.preferences, notifications: desktop.notifications)
      }
      Tab("Advanced", systemImage: "gearshape.2") {
        AdvancedSettingsTab(
          managed: desktop.managedPreferences, exportDiagnostics: exportDiagnostics)
      }
    }
    .scenePadding()
    .frame(width: 520)
    .frame(minHeight: 320)
  }
}

extension OmnigentSettingsView where BrowserSettings == EmptyView {
  /// Creates the view without browser settings.
  /// - Parameters:
  ///   - desktop: The shell services.
  ///   - recentServers: The user's recent servers, offered as the default server.
  ///   - exportDiagnostics: Shown on the Advanced tab when provided.
  public init(
    desktop: DesktopController, recentServers: [URL] = [],
    exportDiagnostics: (() -> Void)? = nil
  ) {
    self.init(
      desktop: desktop, recentServers: recentServers, exportDiagnostics: exportDiagnostics
    ) { EmptyView() }
  }
}

struct GeneralSettingsTab<BrowserSettings: View>: View {
  @Bindable var preferences: DesktopPreferences
  let managed: ManagedPreferences
  let recentServers: [URL]
  let browserSettings: BrowserSettings
  @State private var organizationServers: [ManagedServer] = []
  @State private var managedError: ManagedPreferencesError?

  var body: some View {
    Form {
      Section {
        Picker("Open new windows on", selection: $preferences.defaultServerURL) {
          Text("Connect screen").tag(URL?.none)
          if !organizationServers.isEmpty {
            Section("Provided by your organization") {
              ForEach(organizationServers, id: \.url) { server in
                Text(server.displayName).tag(Optional(server.url))
              }
            }
          }
          let recents = ManagedPreferences.excludingManaged(
            recentServers, managed: organizationServers)
          if !recents.isEmpty {
            Section("Recent") {
              ForEach(recents, id: \.self) { url in
                Text(url.host(percentEncoded: false) ?? url.absoluteString).tag(Optional(url))
              }
            }
          }
          if let current = preferences.defaultServerURL, !isListed(current, recents: recents) {
            Text(current.absoluteString).tag(Optional(current))
          }
        }
        if let managedError {
          Text("Your organization's server list was ignored: \(managedError.localizedSummary)")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Servers")
      }
      browserSettings
    }
    .formStyle(.grouped)
    .task { readManaged() }
  }

  private func isListed(_ url: URL, recents: [URL]) -> Bool {
    recents.contains(url) || organizationServers.contains { $0.url == url }
  }

  private func readManaged() {
    do {
      organizationServers = try managed.servers().servers
      managedError = nil
    } catch {
      organizationServers = []
      managedError = error
    }
  }
}

struct NotificationSettingsTab: View {
  @Bindable var preferences: DesktopPreferences
  let notifications: DesktopNotificationCenter
  @State private var soundNames: [String] = []
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        LabeledContent("Permission", value: permissionLabel)
        switch notifications.authorization {
        case .notDetermined, .unknown:
          Button("Allow Notifications\u{2026}") { Task { await requestAuthorization() } }
            .disabled(!DesktopNotificationCenter.isAvailable)
        case .denied, .provisional:
          Button("Open Notification Settings\u{2026}") { openSystemNotificationSettings() }
        case .authorized:
          EmptyView()
        }
      }
      Section {
        Toggle("A turn finishes", isOn: $preferences.notifyTurnEnded)
        Toggle("An agent asks for input", isOn: $preferences.notifyElicitations)
        Toggle("A runner goes offline", isOn: $preferences.notifyRunnerOffline)
      } header: {
        Text("Notify when")
      } footer: {
        Text("The conversation you are viewing in the frontmost window never notifies.")
      }
      Section {
        Toggle("Play sound", isOn: $preferences.soundEnabled)
        Picker("Sound", selection: $preferences.soundName) {
          ForEach(soundNames, id: \.self) { Text($0).tag($0) }
        }
        .disabled(!preferences.soundEnabled || soundNames.isEmpty)
        .onChange(of: preferences.soundName) { preview() }
      } header: {
        Text("Sound")
      }
      if let errorMessage {
        Text(errorMessage).font(.callout).foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
    .task {
      loadSounds()
      await refreshAuthorization()
    }
  }

  private var permissionLabel: String {
    guard DesktopNotificationCenter.isAvailable else { return "Unavailable outside the app" }
    return switch notifications.authorization {
    case .unknown: "Checking\u{2026}"
    case .notDetermined: "Not requested"
    case .denied: "Off in System Settings"
    case .authorized: "Allowed"
    case .provisional: "Delivered quietly"
    }
  }

  private func loadSounds() {
    do {
      soundNames = try SystemSounds.names()
      if !soundNames.contains(preferences.soundName), let first = soundNames.first {
        preferences.soundName =
          soundNames.contains(SystemSounds.defaultName) ? SystemSounds.defaultName : first
      }
    } catch {
      soundNames = []
      errorMessage = "Could not list system sounds: \(error.localizedDescription)"
    }
  }

  private func preview() {
    do {
      try SystemSounds.play(preferences.soundName)
    } catch {
      errorMessage = "Could not play \(preferences.soundName)."
    }
  }

  private func refreshAuthorization() async {
    guard DesktopNotificationCenter.isAvailable else { return }
    do {
      try await notifications.refreshAuthorization()
    } catch {
      errorMessage = "Could not read notification permission: \(error)"
    }
  }

  private func requestAuthorization() async {
    do {
      try await notifications.requestAuthorization()
    } catch {
      errorMessage = "Could not request notification permission: \(error)"
    }
  }

  private func openSystemNotificationSettings() {
    var components = URLComponents()
    components.scheme = "x-apple.systempreferences"
    components.path = "com.apple.Notifications-Settings.extension"
    components.queryItems = Bundle.main.bundleIdentifier.map {
      [URLQueryItem(name: "id", value: $0)]
    }
    guard let url = components.url, NSWorkspace.shared.open(url) else {
      errorMessage = "Open System Settings > Notifications to change this."
      return
    }
  }
}

struct AdvancedSettingsTab: View {
  let managed: ManagedPreferences
  let exportDiagnostics: (() -> Void)?
  @State private var snapshot: Result<ManagedPreferencesSnapshot, ManagedPreferencesError>?
  @State private var internalFeatures: Result<Bool, ManagedPreferencesError>?

  var body: some View {
    Form {
      Section {
        switch snapshot {
        case .none:
          ProgressView()
        case .success(let snapshot) where snapshot.servers.isEmpty:
          Text("No organization servers are configured.").foregroundStyle(.secondary)
        case .success(let snapshot):
          ForEach(snapshot.servers, id: \.url) { server in
            LabeledContent(server.displayName, value: server.url.absoluteString)
          }
          if let domain = snapshot.serversDomain {
            LabeledContent(
              "Source", value: snapshot.serversAreForced ? "\(domain) (profile)" : domain)
          }
        case .failure(let error):
          Text("Ignored: \(error.localizedSummary)").foregroundStyle(.red)
        }
        LabeledContent("Databricks internal features", value: internalFeaturesLabel)
      } header: {
        Text("Managed by your organization")
      } footer: {
        Text(domainsFootnote)
      }
      Section {
        Button("Reset Window Position") {
          NSWindow.removeFrame(usingName: ServerWindowMetrics.frameAutosaveName)
        }
        if let exportDiagnostics {
          Button("Export Diagnostics\u{2026}", action: exportDiagnostics)
        }
      } header: {
        Text("Troubleshooting")
      }
    }
    .formStyle(.grouped)
    .task { read() }
  }

  private var domainsFootnote: String {
    switch managed.domains.count {
    case 0: "No managed preference domain is read."
    case 1: "Read from the \(managed.domains[0]) preference domain."
    default: "Read from the \(managed.domains.formatted(.list(type: .and))) preference domains."
    }
  }

  private var internalFeaturesLabel: String {
    switch internalFeatures {
    case .none: ""
    case .success(let enabled): enabled ? "On" : "Off"
    case .failure(let error): "Off (\(error.localizedSummary))"
    }
  }

  private func read() {
    snapshot = Result { () throws(ManagedPreferencesError) in try managed.servers() }
    internalFeatures = Result { () throws(ManagedPreferencesError) in
      try managed.databricksInternalFeaturesEnabled()
    }
  }
}

extension ManagedPreferencesError {
  /// A one-line description for Settings.
  public var localizedSummary: String {
    switch self {
    case .notAnArray(let domain): "\(domain) serverUrls is not a list"
    case .tooManyServers(let domain, let count):
      "\(domain) serverUrls has \(count) entries (at most \(ManagedPreferences.maximumServerCount))"
    case .invalidServer(let domain, let index, let reason):
      "\(domain) serverUrls entry \(index + 1) \(reason)"
    case .notABoolean(let domain, let key): "\(domain) \(key) is not a boolean"
    }
  }
}

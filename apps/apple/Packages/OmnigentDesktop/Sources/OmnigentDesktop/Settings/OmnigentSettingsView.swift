import AppKit
public import SwiftUI

/// A Settings tab the app adds from packages the desktop shell does not depend on (for
/// example Appearance from the UI components, or Terminal from the terminal package).
public struct SettingsTabItem: Identifiable {
  /// The tab title, also its identity.
  public let title: String
  /// An SF Symbol.
  public let systemImage: String
  /// The tab's content, usually a `Form`.
  public let content: AnyView
  /// The content sizes itself (a split view) instead of taking the form width.
  public let isWide: Bool

  /// Creates a tab.
  /// - Parameters:
  ///   - title: The tab title.
  ///   - systemImage: An SF Symbol.
  ///   - isWide: The content sizes itself instead of taking the form width.
  ///   - content: The tab's content.
  public init(
    _ title: String, systemImage: String, isWide: Bool = false,
    @ViewBuilder content: () -> some View
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isWide = isWide
    self.content = AnyView(content())
  }

  /// The title.
  public var id: String { title }
}

/// The Settings window: General, Notifications, the app's extra tabs, Local Server and Advanced.
/// Use inside a `Settings` scene.
///
/// The package does not depend on the browser package, so the app supplies the General tab's
/// browser section (typically `OmnigentBrowser.BrowserEngineSettingsView`, which lists only the
/// engines its build offers).
public struct OmnigentSettingsView<BrowserSettings: View>: View {
  private let desktop: DesktopController
  private let recentServers: [URL]
  private let exportDiagnostics: (() -> Void)?
  private let browserSettings: BrowserSettings
  private let extraTabs: [SettingsTabItem]
  private let selection: Binding<String>?
  @State private var localSelection = SettingsTabID.general

  /// Creates the view.
  /// - Parameters:
  ///   - desktop: The shell services.
  ///   - recentServers: The user's recent servers, offered as the default server.
  ///   - exportDiagnostics: Shown on the Advanced tab when provided.
  ///   - extraTabs: Tabs after Notifications, in order.
  ///   - selection: The shown tab's id (a ``SettingsTabID`` or an extra tab's title), so other
  ///     windows can open Settings at a tab; the view keeps its own when `nil`.
  ///   - browserSettings: A `Section` for the General tab's browser settings.
  public init(
    desktop: DesktopController, recentServers: [URL] = [],
    exportDiagnostics: (() -> Void)? = nil, extraTabs: [SettingsTabItem] = [],
    selection: Binding<String>? = nil,
    @ViewBuilder browserSettings: () -> BrowserSettings
  ) {
    self.desktop = desktop
    self.recentServers = recentServers
    self.exportDiagnostics = exportDiagnostics
    self.extraTabs = extraTabs
    self.selection = selection
    self.browserSettings = browserSettings()
  }

  /// The tabs.
  public var body: some View {
    TabView(selection: selection ?? $localSelection) {
      Tab(SettingsTabID.general, systemImage: "gearshape", value: SettingsTabID.general) {
        GeneralSettingsTab(
          preferences: desktop.preferences, managed: desktop.managedPreferences,
          recentServers: recentServers, browserSettings: browserSettings
        )
        .frame(width: Self.formWidth)
      }
      Tab(
        SettingsTabID.notifications, systemImage: "bell.badge", value: SettingsTabID.notifications
      ) {
        NotificationSettingsTab(
          preferences: desktop.preferences, notifications: desktop.notifications
        )
        .frame(width: Self.formWidth)
      }
      ForEach(extraTabs) { item in
        Tab(item.title, systemImage: item.systemImage, value: item.id) {
          item.content.frame(width: item.isWide ? nil : Self.formWidth)
        }
      }
      Tab(SettingsTabID.localServer, systemImage: "server.rack", value: SettingsTabID.localServer) {
        LocalServerSettingsTab(
          manager: desktop.localServer, preferences: desktop.localServerPreferences
        )
        .frame(width: Self.formWidth)
      }
      Tab(SettingsTabID.advanced, systemImage: "gearshape.2", value: SettingsTabID.advanced) {
        AdvancedSettingsTab(
          managed: desktop.managedPreferences, exportDiagnostics: exportDiagnostics
        )
        .frame(width: Self.formWidth)
      }
    }
    .scenePadding()
    // The window takes the content's minimum, so this keeps General and Appearance unclipped.
    .frame(minHeight: Self.formHeight)
  }

  /// The width of the form tabs; a wide tab (``SettingsTabItem/isWide``) sizes itself.
  static var formWidth: CGFloat { 580 }

  /// The tabs' least height: tall enough that General and Appearance show their groups; each
  /// form scrolls within it.
  static var formHeight: CGFloat { 680 }
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
        Picker("New windows open on", selection: $preferences.defaultServerURL) {
          Text("Server picker").tag(URL?.none)
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
          .accessibilityIdentifier("settings.notifications.play-sound")
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

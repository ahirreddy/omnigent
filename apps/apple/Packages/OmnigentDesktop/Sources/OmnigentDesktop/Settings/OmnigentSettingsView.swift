import AppKit
public import SwiftUI

/// Settings: General, Notifications, the app's extra tabs, Local Server and Advanced, handed in
/// that order to the page that lays them out. The app shows them as a page of its window, with
/// the tabs as a sidebar's categories; without a page they are a `Settings` scene's tabs
/// (``SettingsTabWindow``).
///
/// The package does not depend on the browser package, so the app supplies the General tab's
/// browser section (typically `OmnigentBrowser.BrowserEngineSettingsView`, which lists only the
/// engines its build offers).
public struct OmnigentSettingsView<BrowserSettings: View, Page: View>: View {
  private let desktop: DesktopController
  private let recentServers: [URL]
  private let browserSettings: BrowserSettings
  private let extraTabs: [SettingsTabItem]
  private let selection: Binding<String>?
  private let page: ([SettingsTabItem], Binding<String>) -> Page
  @State private var localSelection = SettingsTabID.general

  /// Creates the view.
  /// - Parameters:
  ///   - desktop: The shell services.
  ///   - recentServers: The user's recent servers, offered as the default server.
  ///   - extraTabs: Tabs after Notifications, in order.
  ///   - selection: The shown tab's id (a ``SettingsTabID`` or an extra tab's title), so the
  ///     app can open Settings at a tab; the view keeps its own when `nil`.
  ///   - browserSettings: A `Section` for the General tab's browser settings.
  ///   - page: Lays out the tabs, in order, around the shown tab's id.
  public init(
    desktop: DesktopController, recentServers: [URL] = [],
    extraTabs: [SettingsTabItem] = [], selection: Binding<String>? = nil,
    @ViewBuilder browserSettings: () -> BrowserSettings,
    @ViewBuilder page: @escaping ([SettingsTabItem], Binding<String>) -> Page
  ) {
    self.desktop = desktop
    self.recentServers = recentServers
    self.extraTabs = extraTabs
    self.selection = selection
    self.browserSettings = browserSettings()
    self.page = page
  }

  /// The page, over every tab.
  public var body: some View {
    page(tabs, selection ?? $localSelection)
  }

  /// Every tab, in order: General and Notifications, the app's, then Local Server and Advanced.
  var tabs: [SettingsTabItem] {
    let leading = [
      SettingsTabItem(SettingsTabID.general, systemImage: "gearshape") {
        GeneralSettingsTab(
          preferences: desktop.preferences, managed: desktop.managedPreferences,
          recentServers: recentServers, browserSettings: browserSettings)
      },
      SettingsTabItem(SettingsTabID.notifications, systemImage: "bell.badge") {
        NotificationSettingsTab(
          preferences: desktop.preferences, notifications: desktop.notifications)
      },
    ]
    let trailing = [
      SettingsTabItem(SettingsTabID.localServer, systemImage: "server.rack") {
        LocalServerSettingsTab(
          manager: desktop.localServer, preferences: desktop.localServerPreferences)
      },
      SettingsTabItem(SettingsTabID.advanced, systemImage: "gearshape.2") {
        AdvancedSettingsTab(managed: desktop.managedPreferences)
      },
    ]
    return leading + extraTabs + trailing
  }
}

extension OmnigentSettingsView where Page == SettingsTabWindow {
  /// Creates the view as a `Settings` scene's tabs.
  /// - Parameters:
  ///   - desktop: The shell services.
  ///   - recentServers: The user's recent servers, offered as the default server.
  ///   - extraTabs: Tabs after Notifications, in order.
  ///   - selection: The shown tab's id; the view keeps its own when `nil`.
  ///   - browserSettings: A `Section` for the General tab's browser settings.
  public init(
    desktop: DesktopController, recentServers: [URL] = [], extraTabs: [SettingsTabItem] = [],
    selection: Binding<String>? = nil,
    @ViewBuilder browserSettings: () -> BrowserSettings
  ) {
    self.init(
      desktop: desktop, recentServers: recentServers, extraTabs: extraTabs,
      selection: selection, browserSettings: browserSettings
    ) { tabs, selection in
      SettingsTabWindow(tabs: tabs, selection: selection)
    }
  }
}

extension OmnigentSettingsView where BrowserSettings == EmptyView, Page == SettingsTabWindow {
  /// Creates the view without browser settings.
  /// - Parameters:
  ///   - desktop: The shell services.
  ///   - recentServers: The user's recent servers, offered as the default server.
  public init(desktop: DesktopController, recentServers: [URL] = []) {
    self.init(desktop: desktop, recentServers: recentServers) { EmptyView() }
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
  var isAvailable = DesktopNotificationCenter.isAvailable
  var listSounds: @MainActor () throws -> [String] = SystemSounds.names
  @State private var soundNames: [String] = []
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        LabeledContent("Permission", value: permissionLabel)
        switch notifications.authorization {
        case .notDetermined, .unknown:
          Button("Allow Notifications\u{2026}") { Task { await requestAuthorization() } }
            .disabled(!isAvailable)
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
          .id("settings.notifications.play-sound")
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
    guard isAvailable else { return "Unavailable outside the app" }
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
      soundNames = try listSounds()
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
    guard isAvailable else { return }
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
    let url = DesktopNotificationCenter.systemSettingsURL(
      bundleIdentifier: Bundle.main.bundleIdentifier)
    guard let url, NSWorkspace.shared.open(url) else {
      errorMessage = "Open System Settings > Notifications to change this."
      return
    }
  }
}

struct AdvancedSettingsTab: View {
  let managed: ManagedPreferences
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
        LabeledContent("Internal features", value: internalFeaturesLabel)
      } header: {
        Text("Managed by your organization")
      } footer: {
        Text(domainsFootnote)
      }
      Section {
        Button("Reset Window Position") {
          NSWindow.removeFrame(usingName: ServerWindowMetrics.frameAutosaveName)
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
      try managed.internalFeaturesEnabled()
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

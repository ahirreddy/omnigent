public import SwiftUI

/// Clear browsing data for one profile, with a time range.
public struct BrowserClearDataView: View {
  private let environment: BrowserEnvironment
  private let profileID: UUID
  @State private var range = Range.allTime
  @State private var types: BrowserDataTypes = [.history, .cookies, .cache, .siteData]
  @State private var running = false
  @State private var error: BrowserError?
  @Environment(\.dismiss) private var dismiss

  enum Range: String, CaseIterable, Identifiable {
    case lastHour = "Last hour"
    case lastDay = "Last 24 hours"
    case lastWeek = "Last 7 days"
    case allTime = "All time"

    var id: String { rawValue }

    var since: Date? {
      switch self {
      case .lastHour: Date().addingTimeInterval(-3_600)
      case .lastDay: Date().addingTimeInterval(-86_400)
      case .lastWeek: Date().addingTimeInterval(-7 * 86_400)
      case .allTime: nil
      }
    }
  }

  /// Creates the view.
  public init(environment: BrowserEnvironment, profileID: UUID) {
    self.environment = environment
    self.profileID = profileID
  }

  /// The view body.
  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Clear Browsing Data").font(.title2.bold())
        Spacer()
        BrowserProfileChip(profile: environment.profiles.profile(id: profileID))
      }
      Picker("Time range", selection: $range) {
        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
      }
      .accessibilityIdentifier("browser.clearData.range")
      toggle("Browsing history", .history)
      toggle("Cookies", .cookies)
      toggle("Cached images and files", .cache)
      toggle("Site storage (local storage, databases, service workers)", .siteData)
      toggle("Site permissions and zoom levels", .siteSettings)
      toggle("Downloads list (files stay on disk)", .downloads)
      if let error {
        Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Clear Data") { clear() }
          .keyboardShortcut(.defaultAction)
          .disabled(types.isEmpty || running)
          .accessibilityIdentifier("browser.clearData.confirm")
      }
    }
    .padding(20)
    .frame(width: 440)
    .accessibilityIdentifier("browser.clearData")
  }

  private func toggle(_ title: String, _ type: BrowserDataTypes) -> some View {
    Toggle(
      title,
      isOn: Binding(
        get: { types.contains(type) },
        set: { isOn in if isOn { types.insert(type) } else { types.remove(type) } }))
  }

  private func clear() {
    running = true
    Task {
      do throws(BrowserError) {
        try await environment.clearBrowsingData(
          profileID: profileID, types: types, since: range.since)
        dismiss()
      } catch let failure {
        error = failure
      }
      running = false
    }
  }
}

/// Remembered permission decisions of one profile, with removal.
public struct BrowserSiteSettingsView: View {
  private let store: BrowserPermissionStore
  private let profile: BrowserProfile
  @State private var decisions: [String: BrowserPermissionDecision] = [:]
  @Environment(\.dismiss) private var dismiss

  /// Creates the view.
  public init(store: BrowserPermissionStore, profile: BrowserProfile) {
    self.store = store
    self.profile = profile
  }

  /// The view body.
  public var body: some View {
    VStack(spacing: 0) {
      Text("Site Permissions").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
      if decisions.isEmpty {
        ContentUnavailableView("No Remembered Permissions", systemImage: "hand.raised")
      } else {
        List(decisions.keys.sorted(), id: \.self) { key in
          let parts = key.split(separator: "|")
          HStack {
            Text(parts.first.map(String.init) ?? key)
            Spacer()
            Text(Self.permissionName(parts.last.map(String.init)))
              .foregroundStyle(.secondary)
            Text(decisions[key] == .allow ? "Allowed" : "Blocked")
            Button("Forget", systemImage: "xmark.circle") {
              store.forget(key: key, profile: profile)
              decisions = store.decisions(for: profile)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
          }
        }
      }
      Divider()
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(minWidth: 480, minHeight: 320)
    .onAppear { decisions = store.decisions(for: profile) }
  }

  private static func permissionName(_ bit: String?) -> String {
    guard let bit else { return "" }
    return BrowserPermissions.named.first { String($0.0.rawValue) == bit }?.1 ?? "Permission \(bit)"
  }
}

/// Settings for the browser: search engine, bookmarks bar, new-tab page and profiles.
public struct BrowserSettingsView: View {
  private let environment: BrowserEnvironment
  @State private var showsProfiles = false

  /// Creates the settings section.
  public init(environment: BrowserEnvironment) {
    self.environment = environment
  }

  /// The view body.
  public var body: some View {
    @Bindable var settings = environment.settings
    Section("Browsing") {
      Picker("Search engine", selection: $settings.searchEngineID) {
        ForEach(BrowserSearchEngine.builtIn) { Text($0.name).tag($0.id) }
        Text("Custom").tag("custom")
      }
      .accessibilityIdentifier("settings.browser.searchEngine")
      if settings.searchEngineID == "custom" {
        TextField("Search URL with %s", text: $settings.customSearchTemplate)
        if !BrowserSearchEngine.isValidTemplate(settings.customSearchTemplate) {
          Text("Use an http(s) URL with one %s for the query. Google is used until then.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Toggle("Show bookmarks bar", isOn: $settings.showsBookmarksBar)
      LabeledContent("Profiles") {
        HStack {
          BrowserProfileChip(profile: environment.profiles.defaultProfile)
          Button("Manage…") { showsProfiles = true }
        }
      }
    }
    .sheet(isPresented: $showsProfiles) { BrowserProfileManagerView(environment: environment) }
  }
}

public import SwiftUI

/// A host the Harnesses section can show.
public struct HarnessesSettingsHost: Identifiable, Equatable, Sendable {
  /// Host id.
  public let id: String
  /// Name.
  public let name: String
  /// Online.
  public let isOnline: Bool

  /// Creates a host.
  public init(id: String, name: String, isOnline: Bool) {
    self.id = id
    self.name = name
    self.isOnline = isOnline
  }
}

/// One harness on the selected host.
public struct HarnessesSettingsRow: Identifiable, Equatable, Sendable {
  /// The harness id.
  public let id: String
  /// Name.
  public let name: String
  /// One line.
  public let description: String
  /// Status line, e.g. Configured or Needs sign-in; `nil` when the host does not report it.
  public let status: String?
  /// Ready.
  public let isReady: Bool
  /// Not ready: offer Set Up.
  public let needsSetup: Bool

  /// Creates a row.
  public init(
    id: String, name: String, description: String, status: String?, isReady: Bool,
    needsSetup: Bool
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.status = status
    self.isReady = isReady
    self.needsSetup = needsSetup
  }
}

/// The Harnesses section of the server settings.
public struct HarnessesSettingsState: Equatable, Sendable {
  /// Hosts, online first.
  public var hosts: [HarnessesSettingsHost]
  /// The host whose harnesses show.
  public var selectedHostID: String?
  /// Its harnesses.
  public var rows: [HarnessesSettingsRow]
  /// Still loading.
  public var isLoading: Bool
  /// Why loading failed.
  public var errorMessage: String?

  /// Creates the state.
  public init(
    hosts: [HarnessesSettingsHost] = [], selectedHostID: String? = nil,
    rows: [HarnessesSettingsRow] = [], isLoading: Bool = false, errorMessage: String? = nil
  ) {
    self.hosts = hosts
    self.selectedHostID = selectedHostID
    self.rows = rows
    self.isLoading = isLoading
    self.errorMessage = errorMessage
  }
}

/// What the Harnesses section can do.
public struct HarnessesSettingsActions {
  /// Shows another host.
  public var selectHost: @MainActor (String) -> Void
  /// Opens the setup sheet for a harness on the selected host.
  public var setUp: @MainActor (HarnessesSettingsRow) -> Void
  /// Reads the hosts' readiness again.
  public var refresh: @MainActor () -> Void
  /// Opens a harness's details; `nil` hides the Details buttons.
  public var open: (@MainActor (HarnessesSettingsRow) -> Void)?

  /// Creates the actions.
  public init(
    selectHost: @escaping @MainActor (String) -> Void,
    setUp: @escaping @MainActor (HarnessesSettingsRow) -> Void,
    refresh: @escaping @MainActor () -> Void,
    open: (@MainActor (HarnessesSettingsRow) -> Void)? = nil
  ) {
    self.selectHost = selectHost
    self.setUp = setUp
    self.refresh = refresh
    self.open = open
  }
}

/// Settings > Harnesses (the web's harness inventory): pick a host, see each coding harness's
/// readiness on it, and set up one that is not ready. Search filters by name and description;
/// Configured shows only ready harnesses.
public struct HarnessesSettingsSection: View {
  private let state: HarnessesSettingsState
  private let actions: HarnessesSettingsActions
  @State private var query = ""
  @State private var configuredOnly = false

  /// Creates the section.
  /// - Parameters:
  ///   - state: Hosts and harnesses.
  ///   - actions: Host choice, Set Up and refresh.
  public init(state: HarnessesSettingsState, actions: HarnessesSettingsActions) {
    self.state = state
    self.actions = actions
  }

  /// The section's content, for a grouped `Form`.
  public var body: some View {
    Section {
      Picker(
        "Host",
        selection: Binding(
          get: { state.selectedHostID ?? "" }, set: { actions.selectHost($0) })
      ) {
        if state.hosts.isEmpty { Text("No hosts").tag("") }
        ForEach(state.hosts) { host in
          Text(host.isOnline ? host.name : "\(host.name) (offline)").tag(host.id)
        }
      }
      .accessibilityIdentifier("harness-settings-host")
      Picker("Show", selection: $configuredOnly) {
        Text("All").tag(false)
        Text("Configured").tag(true)
      }
      .pickerStyle(.segmented)
      TextField("Search", text: $query, prompt: Text("Search harnesses"))
        .accessibilityIdentifier("harness-settings-search")
    } footer: {
      if state.hosts.isEmpty && !state.isLoading {
        Text("Connect a host to see and set up its harnesses.")
      }
    }
    Section {
      if state.isLoading && state.rows.isEmpty { ProgressView() }
      if let error = state.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(Theme.failure)
          .textSelection(.enabled)
      }
      ForEach(visibleRows) { row in
        HStack(spacing: Theme.Spacing.medium) {
          HarnessGlyph(harness: row.id, size: 22)
          VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
            Text(row.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let status = row.status {
              Label(
                status, systemImage: row.isReady ? "checkmark.circle" : "exclamationmark.triangle"
              )
              .font(.caption)
              .foregroundStyle(row.isReady ? Theme.success : Theme.warning)
            }
          }
          Spacer()
          if row.needsSetup {
            Button("Set Up\u{2026}") { actions.setUp(row) }
              .accessibilityIdentifier("harness-settings-setup-\(row.id)")
          }
          if let open = actions.open, row.status != nil {
            Button("Details", systemImage: "chevron.right") { open(row) }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help("Show \(row.name)\u{2019}s account and startup settings")
              .accessibilityIdentifier("harness-settings-open-\(row.id)")
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("harness-settings-row-\(row.id)")
      }
      if visibleRows.isEmpty && !state.rows.isEmpty {
        Text(
          query.isEmpty
            ? "No configured harnesses." : "No harnesses match \u{201C}\(query)\u{201D}."
        )
        .foregroundStyle(.secondary)
      }
    } header: {
      HStack {
        Text("Harnesses")
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise", action: actions.refresh)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Check the host's harnesses again")
      }
    }
  }

  private var visibleRows: [HarnessesSettingsRow] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    return state.rows.filter { row in
      (!configuredOnly || row.isReady)
        && (needle.isEmpty || row.name.lowercased().contains(needle)
          || row.description.lowercased().contains(needle))
    }
  }
}

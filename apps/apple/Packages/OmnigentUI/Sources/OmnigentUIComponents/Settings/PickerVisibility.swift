public import Foundation
public import SwiftUI

/// The harnesses and agents the user hid from the agent pickers, under the web's key
/// (`omnigent:hidden-picker-agents`, a JSON array of agent names). Keyed by name, not id, so a
/// re-registered agent stays hidden.
nonisolated public enum PickerVisibility {
  /// The `UserDefaults` key.
  public static let key = "omnigent:hidden-picker-agents"

  /// The hidden names in a stored value; a missing or corrupt value hides nothing.
  /// - Parameter raw: The stored JSON text.
  /// - Returns: The names.
  public static func hiddenNames(_ raw: String?) -> Set<String> {
    guard let data = raw?.data(using: .utf8),
      let names = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return Set(names)
  }

  /// The stored value for `names`: sorted JSON, or `nil` (no key) when nothing is hidden.
  /// - Parameter names: The hidden names.
  /// - Returns: The JSON text.
  public static func stored(_ names: Set<String>) -> String? {
    guard !names.isEmpty,
      let data = try? JSONEncoder().encode(names.sorted()),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text
  }

  /// The hidden names on this device.
  /// - Parameter defaults: The store.
  /// - Returns: The names.
  public static func hidden(in defaults: UserDefaults = .standard) -> Set<String> {
    hiddenNames(defaults.string(forKey: key))
  }

  /// The entries a picker shows: the hidden ones dropped, except the selected entry.
  /// - Parameters:
  ///   - entries: The picker's entries.
  ///   - name: An entry's agent name.
  ///   - id: An entry's id.
  ///   - selectedID: The selected entry, which always stays.
  ///   - hidden: The hidden names.
  /// - Returns: The shown entries.
  public static func shown<Entry>(
    _ entries: [Entry], name: (Entry) -> String, id: (Entry) -> String, selectedID: String?,
    hidden: Set<String>
  ) -> [Entry] {
    guard !hidden.isEmpty else { return entries }
    return entries.filter { !hidden.contains(name($0)) || id($0) == selectedID }
  }

  /// "Showing 15 of 17. Hidden: Debby and Codex.", as the web's summary.
  /// - Parameters:
  ///   - entries: Every entry the pickers can offer.
  ///   - hidden: The hidden names; names no longer offered are ignored.
  /// - Returns: The summary.
  public static func summary(_ entries: [PickerVisibilityEntry], hidden: Set<String>) -> String {
    let hiddenTitles = entries.filter { hidden.contains($0.name) }.map(\.title)
    if hiddenTitles.isEmpty { return "Showing all \(entries.count)." }
    let named = Array(hiddenTitles.prefix(3))
    let overflow = hiddenTitles.count - named.count
    let listed = (overflow > 0 ? named + ["\(overflow) more"] : named)
      .formatted(.list(type: .and).locale(Locale(identifier: "en_US")))
    return "Showing \(entries.count - hiddenTitles.count) of \(entries.count). Hidden: \(listed)."
  }
}

/// One harness or agent the pickers can offer.
nonisolated public struct PickerVisibilityEntry: Hashable, Sendable, Identifiable {
  /// Which list it is under.
  public enum Group: String, Hashable, Sendable, CaseIterable {
    /// Harnesses.
    case harnesses = "Harnesses"
    /// Agents, built-in and custom.
    case agents = "Agents"
  }

  /// The agent's name, the key it is hidden under.
  public var name: String
  /// The label.
  public var title: String
  /// Its list.
  public var group: Group

  /// The name.
  public var id: String { name }

  /// Creates an entry.
  /// - Parameters:
  ///   - name: Agent name.
  ///   - title: Label.
  ///   - group: List.
  public init(name: String, title: String, group: Group) {
    self.name = name
    self.title = title
    self.group = group
  }
}

/// The server's picker entries, or why they could not be read.
public enum PickerVisibilityLoad: Sendable {
  /// The entries.
  case loaded([PickerVisibilityEntry])
  /// The failure message.
  case failed(String)
}

/// Reads a server's harnesses and agents for Settings › Show in agent pickers. Equal for the
/// same server, so the environment does not change on every update.
public struct PickerVisibilitySource: Equatable {
  /// The server it reads.
  public let server: String
  /// Reads the entries.
  public let load: @MainActor @Sendable () async -> PickerVisibilityLoad

  /// Creates a source.
  /// - Parameters:
  ///   - server: The server's id (its URL).
  ///   - load: Reads the entries.
  public init(server: String, load: @escaping @MainActor @Sendable () async -> PickerVisibilityLoad)
  {
    self.server = server
    self.load = load
  }

  /// Equal for the same server.
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.server == rhs.server }
}

extension EnvironmentValues {
  /// The entries for Settings › Show in agent pickers; `nil` hides the setting.
  @Entry public var pickerVisibilitySource: PickerVisibilitySource?
}

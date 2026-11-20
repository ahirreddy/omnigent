public import Foundation
public import Observation

/// A registered system-wide shortcut, released with ``unregister()``.
public protocol HotKeyRegistration: AnyObject {
  /// Releases the chord.
  func unregister()
}

extension SystemHotKey: HotKeyRegistration {}

/// Registers a chord system-wide, calling the action on each press.
public typealias HotKeyRegistrar =
  @MainActor (
    _ chord: HotKeyChord, _ action: @escaping @MainActor () -> Void
  ) throws(SystemHotKeyError) -> any HotKeyRegistration

/// The floating New Agent panel's system-wide shortcut, as the desktop app's Settings row
/// "Open New Agent from anywhere" sets it: off, or a chord (⇧⌘Space by default). The chord is
/// registered only while a signed-in server turns the panel on (`floating_composer`), and is
/// released while Settings records a new one, so pressing the old chord records it.
@Observable
public final class FloatingPanelShortcut {
  /// The row's setting.
  nonisolated public enum Setting: Hashable, Sendable {
    /// No system-wide shortcut.
    case off
    /// This chord opens the panel.
    case chord(HotKeyChord)
  }

  static let defaultsKey = "desktop.floatingPanel.shortcut"
  static let offValue = "off"

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let register: HotKeyRegistrar
  @ObservationIgnored private let reportIssue: DesktopIssueReporter
  @ObservationIgnored private var registration: (any HotKeyRegistration)?
  @ObservationIgnored private var registeredChord: HotKeyChord?

  /// Off, or the chord. Setting it saves it and registers the new chord.
  public var setting: Setting {
    didSet {
      save()
      apply()
    }
  }

  /// A signed-in server turns the panel on. Settings shows the row only then.
  public var isAvailable = false {
    didSet { if oldValue != isAvailable { apply() } }
  }

  /// Settings is recording a chord: the current one is released meanwhile.
  public var isRecording = false {
    didSet { if oldValue != isRecording { apply() } }
  }

  /// Why the chord isn't registered, when the system refused it.
  public private(set) var problem: String?

  /// What pressing the chord does: shows the panel.
  @ObservationIgnored public var onPress: @MainActor () -> Void = {}

  /// The chord registered right now, if any.
  public var activeChord: HotKeyChord? { registeredChord }

  /// Reads the saved setting.
  /// - Parameters:
  ///   - defaults: The store.
  ///   - reportIssue: Where a refused or released chord's failure is reported too.
  ///   - register: Registers a chord; the system's hot keys when `nil` (tests pass a fake).
  public init(
    defaults: UserDefaults = .standard, reportIssue: @escaping DesktopIssueReporter,
    register: HotKeyRegistrar? = nil
  ) {
    self.defaults = defaults
    self.reportIssue = reportIssue
    if let register {
      self.register = register
    } else {
      self.register = Self.systemRegistrar(reportIssue: reportIssue)
    }
    let saved = Self.load(defaults)
    setting = saved.setting
    problem = saved.problem
  }

  /// Registers chords with the system's hot keys.
  private static func systemRegistrar(reportIssue: @escaping DesktopIssueReporter)
    -> HotKeyRegistrar
  {
    { chord, action throws(SystemHotKeyError) in
      try SystemHotKey(chord: chord, reportIssue: reportIssue, action: action)
    }
  }

  /// The saved setting: off, a chord, or ⇧⌘Space when nothing was saved. A saved chord that
  /// can't be read keeps the default and says why.
  static func load(_ defaults: UserDefaults) -> (setting: Setting, problem: String?) {
    if defaults.string(forKey: defaultsKey) == offValue { return (.off, nil) }
    guard let data = defaults.data(forKey: defaultsKey) else {
      return (.chord(.newAgentPanelDefault), nil)
    }
    do {
      return (.chord(try JSONDecoder().decode(HotKeyChord.self, from: data)), nil)
    } catch {
      return (
        .chord(.newAgentPanelDefault),
        "The saved shortcut couldn\u{2019}t be read (\(error.localizedDescription)); "
          + "using \(HotKeyChord.newAgentPanelDefault.displayText)."
      )
    }
  }

  private func save() {
    switch setting {
    case .off:
      defaults.set(Self.offValue, forKey: Self.defaultsKey)
    case .chord(let chord):
      do {
        defaults.set(try JSONEncoder().encode(chord), forKey: Self.defaultsKey)
      } catch {
        problem = "Couldn\u{2019}t save \(chord.displayText): \(error.localizedDescription)"
      }
    }
  }

  /// Registers the chord that should be live, releasing any other.
  private func apply() {
    var wanted: HotKeyChord?
    if isAvailable, !isRecording, case .chord(let chord) = setting { wanted = chord }
    guard wanted != registeredChord else { return }
    registration?.unregister()
    registration = nil
    registeredChord = nil
    problem = nil
    guard let wanted else { return }
    do {
      registration = try register(wanted) { [weak self] in self?.onPress() }
      registeredChord = wanted
    } catch {
      problem = error.description
      reportIssue(.systemShortcut(error))
    }
  }
}

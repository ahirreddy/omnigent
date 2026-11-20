import Foundation
public import Observation
public import OmnigentCoreFFI

/// Omni Advisor on one server, as the web's `useProactiveAgentSettings` and its admin controls:
/// whether it runs for the caller (the Inbox's tab follows it), both switches, and the admin's
/// prompt and Run now. Each write's failure stays with it until the next try.
@Observable
public final class AdvisorStore {
  /// The caller's settings; a failed refresh keeps the ones read before.
  public private(set) var settings: CreationLoad<AdvisorSettingsRecord> = .idle
  /// A switch change is in flight.
  public private(set) var isSavingSwitch = false
  /// The last switch change the server refused.
  public private(set) var switchError: CoreError?
  /// The prompt every user's runs follow (admins).
  public private(set) var prompt: CreationLoad<AdvisorPromptRecord> = .idle
  /// A prompt save is in flight.
  public private(set) var isSavingPrompt = false
  /// The last prompt save the server refused.
  public private(set) var promptError: CoreError?
  /// Run now is in flight.
  public private(set) var isRunning = false
  /// What the last Run now did.
  public private(set) var runs: AdvisorRunsRecord?
  /// Why the last Run now failed.
  public private(set) var runError: CoreError?

  private let core: ClientCore
  /// Reads the Inbox's items again, after a switch changes which ones show.
  @ObservationIgnored var refreshItems: @MainActor () async -> Void = {}
  /// Reads started so far; only the latest one lands, so a reset drops one in flight.
  private var settingsReads = 0

  init(core: ClientCore) {
    self.core = core
  }

  /// The advisor's items show in the Inbox: the settings say it runs for the caller.
  public var isOn: Bool { settings.value?.enabled == true }

  /// Forgets another server's or account's advisor.
  func reset() {
    settingsReads += 1
    settings = .idle
    isSavingSwitch = false
    switchError = nil
    prompt = .idle
    isSavingPrompt = false
    promptError = nil
    isRunning = false
    runs = nil
    runError = nil
  }

  /// Reads the caller's settings. A failed refresh keeps the settings read before, as the web's
  /// query does.
  public func loadSettings() async {
    settingsReads += 1
    let read = settingsReads
    if settings.value == nil { settings = .loading }
    do {
      let loaded = try await core.advisorSettings()
      guard read == settingsReads else { return }
      settings = .loaded(loaded)
    } catch {
      guard read == settingsReads, settings.value == nil else { return }
      settings = .failed(coreError(error))
    }
  }

  /// Turns the advisor on or off for the caller or, for an admin, the workspace.
  /// - Returns: Whether the server took it; a refusal is in ``switchError``.
  @discardableResult
  public func setEnabled(_ scope: AdvisorScopeRecord, _ enabled: Bool) async -> Bool {
    isSavingSwitch = true
    switchError = nil
    defer { isSavingSwitch = false }
    do {
      let saved = try await core.setAdvisorEnabled(scope: scope, enabled: enabled)
      settingsReads += 1
      settings = .loaded(saved)
    } catch {
      switchError = coreError(error)
      return false
    }
    await refreshItems()
    return true
  }

  /// Reads the advisor's prompt (admins).
  public func loadPrompt() async {
    if prompt.value == nil { prompt = .loading }
    do {
      prompt = .loaded(try await core.advisorPrompt())
    } catch {
      prompt = .failed(coreError(error))
    }
  }

  /// Saves the prompt for every user; `nil` restores the built-in one.
  /// - Returns: The prompt now in use, or `nil` when the save failed (see ``promptError``).
  public func savePrompt(_ text: String?) async -> AdvisorPromptRecord? {
    isSavingPrompt = true
    promptError = nil
    defer { isSavingPrompt = false }
    do {
      let saved = try await core.saveAdvisorPrompt(prompt: text)
      prompt = .loaded(saved)
      return saved
    } catch {
      promptError = coreError(error)
      return nil
    }
  }

  /// Starts runs now for the users typed in `text` (commas or spaces; `*` is everyone).
  public func run(_ text: String) async {
    let users = advisorRunUsers(text: text)
    guard !users.isEmpty else { return }
    isRunning = true
    runError = nil
    defer { isRunning = false }
    do {
      runs = try await core.runAdvisor(users: users)
    } catch {
      runs = nil
      runError = coreError(error)
    }
  }
}

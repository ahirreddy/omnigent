public import Foundation
public import Observation
public import OmnigentCoreFFI

/// The `/rewind` picker of a Claude session (the web's `RewindPicker`): its prompts, newest
/// first, read a few pages at a time, with older ones on request.
@Observable
public final class RewindPicker: Identifiable {
  /// Where reading the prompts stands.
  public enum Phase: Equatable, Sendable {
    /// The first batch is being read.
    case loading
    /// The prompts are listed.
    case loaded
    /// The first batch could not be read.
    case failed(String)
  }

  /// Where reading older prompts stands.
  public enum OlderPhase: Equatable, Sendable {
    /// Nothing in flight.
    case idle
    /// The next older batch is being read.
    case loading
    /// The last attempt failed; another can be made.
    case failed(String)
  }

  /// This opening of the picker, so a sheet shows it once.
  public let id = UUID()
  /// The first batch.
  public private(set) var phase = Phase.loading
  /// The prompts read so far, newest first.
  public private(set) var prompts: [RewindPrompt] = []
  /// Where older prompts continue; `nil` once none remain.
  public private(set) var olderCursor: String?
  /// The older batch.
  public private(set) var older = OlderPhase.idle

  let sessionID: String
  private let core: ClientCore

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
  }

  /// Reads the newest prompts.
  public func load() async {
    phase = .loading
    do {
      let page = try await core.rewindPrompts(sessionId: sessionID, after: nil)
      prompts = page.prompts
      olderCursor = page.olderCursor
      older = .idle
      phase = .loaded
    } catch {
      phase = .failed(coreError(error).message)
    }
  }

  /// Reads the next older batch, once the first is listed; one at a time.
  public func loadOlder() async {
    guard phase == .loaded, let cursor = olderCursor, older != .loading else { return }
    older = .loading
    do {
      let page = try await core.rewindPrompts(sessionId: sessionID, after: cursor)
      prompts += page.prompts
      olderCursor = page.olderCursor
      older = .idle
    } catch {
      older = .failed(coreError(error).message)
    }
  }
}

/// What a rewind left for the caller.
public struct RewindOutcome: Equatable, Sendable {
  /// The new session, holding the history before the prompt, with the prompt in its composer.
  public var sessionID: String
  /// What did not come back with the prompt (some attachments, or the prompt itself); `nil`
  /// when everything did.
  public var warning: String?
}

extension ComposerStore {
  /// Closes the `/rewind` picker without rewinding.
  public func dismissRewindPicker() {
    rewindPicker = nil
  }

  /// Continues the conversation from just before `prompt` in a new session, on the same host
  /// and runner, with the prompt (and its attachments) in the new session's composer; this one
  /// keeps everything. Closes the picker first. A refusal (a running turn, for one) shows in
  /// ``commandNotice``.
  /// - Parameter prompt: One of the picker's prompts.
  /// - Returns: The new session and any attachment warning; `nil` when the rewind failed.
  public func rewind(to prompt: RewindPrompt) async -> RewindOutcome? {
    rewindPicker = nil
    let rewound: Rewound
    do {
      rewound = try await core.rewindSession(sessionId: sessionID, itemId: prompt.itemId)
    } catch {
      commandNotice = "Rewind failed: \(coreError(error).message)"
      return nil
    }
    do {
      let restored = try await core.restoreRewoundPrompt(rewound: rewound)
      return RewindOutcome(
        sessionID: rewound.sessionId,
        warning: Self.attachmentWarning(
          incomplete: rewound.attachmentsIncomplete,
          missing: restored.unrestored.map(\.filename)))
    } catch {
      // The new session exists; only its draft is missing.
      return RewindOutcome(
        sessionID: rewound.sessionId,
        warning: "The prompt could not be put back in the composer: \(coreError(error).message)")
    }
  }

  /// The web's warning when a rewound prompt's attachments did not all come back, naming the
  /// ones that could not be restored here.
  static func attachmentWarning(incomplete: Bool, missing: [String]) -> String? {
    guard incomplete || !missing.isEmpty else { return nil }
    let warning = "Some attachments couldn't be restored. Attach them again before sending."
    return missing.isEmpty ? warning : "\(warning) Missing: \(missing.joined(separator: ", "))."
  }
}

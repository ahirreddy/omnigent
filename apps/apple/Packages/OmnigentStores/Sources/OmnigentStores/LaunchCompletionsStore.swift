import Foundation
public import Observation
public import OmnigentCoreFFI

/// The new-session composer's `/` skills and `@` mentions before a session exists, as on the
/// web's launcher: skills discovered for the chosen host, folder and harness, and a browser over
/// the folder's files whose tagged paths go ahead of the first message as marker lines.
@Observable
public final class LaunchCompletionsStore {
  /// Where skills and files are read from.
  public struct Target: Hashable, Sendable {
    /// The host.
    public var hostID: String
    /// The harness the session will run, which decides the skills and the `$` prefix.
    public var harness: String?
    /// The agent, for its bundled skills.
    public var agentID: String?
    /// The absolute folder the session works in.
    public var folder: String

    /// Creates a target.
    /// - Parameters:
    ///   - hostID: The host.
    ///   - harness: The harness.
    ///   - agentID: The agent.
    ///   - folder: The absolute folder.
    public init(hostID: String, harness: String?, agentID: String?, folder: String) {
      self.hostID = hostID
      self.harness = harness
      self.agentID = agentID
      self.folder = folder
    }
  }

  /// Skills for the `/` menu.
  public private(set) var skills: [SlashCommand] = []
  /// Why the `/` menu has no or partial skills; `nil` when complete.
  public private(set) var skillsNote: String?
  /// Folder paths for the `@` menu, relative to the target's folder; folders end in `/`.
  public private(set) var mentionCandidates: [String] = []
  /// Paths tagged with `@`, shown as chips.
  public private(set) var mentions: [String] = []
  /// Why the `@` menu has no results.
  public private(set) var mentionProblem: String?

  private let core: ClientCore
  @ObservationIgnored private var skillsTarget: Target?
  @ObservationIgnored private var mentionQuery: String?
  @ObservationIgnored private var mentionTask: Task<Void, Never>?

  init(core: ClientCore) {
    self.core = core
  }

  /// Reads the skills for `target`, or says why there are none (`unavailable`, in the web's
  /// words). Reading the same target again does nothing.
  /// - Parameters:
  ///   - target: Where to discover skills; `nil` with `unavailable` set.
  ///   - unavailable: Why skills cannot be discovered yet.
  public func loadSkills(_ target: Target?, unavailable: String?) async {
    guard let target, unavailable == nil else {
      skillsTarget = nil
      if !skills.isEmpty { skills = [] }
      if skillsNote != unavailable { skillsNote = unavailable }
      return
    }
    guard target != skillsTarget else { return }
    skillsTarget = target
    do {
      let catalog = try await core.hostSkills(
        hostId: target.hostID, harness: target.harness ?? "", path: target.folder,
        agentId: target.agentID)
      guard skillsTarget == target else { return }
      skills = OmnigentCoreFFI.skillCommands(harness: target.harness, skills: catalog.skills)
      skillsNote =
        catalog.warnings.isEmpty
        ? nil : "Some skills could not be read: \(catalog.warnings.joined(separator: "; "))"
    } catch {
      guard skillsTarget == target else { return }
      skillsTarget = nil
      skills = []
      skillsNote = "Skills are unavailable: \(coreError(error).message)"
    }
  }

  /// Lists the target's folder for the `@` mention being typed at the end of `draft`, after a
  /// short pause; clears the list when none is typed or `target` is `nil`.
  /// - Parameters:
  ///   - draft: The composer text.
  ///   - target: The host and folder; `nil` turns mentions off.
  public func draftChanged(_ draft: String, target: Target?) {
    let query = target == nil ? nil : ComposerStore.mentionQuery(in: draft)
    guard query != mentionQuery else { return }
    mentionQuery = query
    mentionTask?.cancel()
    guard let query, let target else {
      if !mentionCandidates.isEmpty { mentionCandidates = [] }
      if mentionProblem != nil { mentionProblem = nil }
      return
    }
    mentionTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        // Superseded by a newer query, which lists for itself.
        return
      }
      await self?.listMentions(query, target: target)
    }
  }

  private func listMentions(_ query: String, target: Target) async {
    let root = target.folder.hasSuffix("/") ? String(target.folder.dropLast()) : target.folder
    let folder = query.lastIndex(of: "/").map { String(query[..<$0]) } ?? ""
    do {
      let entries = try await core.hostEntries(
        hostId: target.hostID, path: folder.isEmpty ? root : "\(root)/\(folder)")
      guard mentionQuery == query else { return }
      let listing = entries.map { entry in
        MentionEntry(
          path: Self.relative(entry.path, to: root), name: entry.name,
          isDirectory: entry.isDirectory)
      }
      let rows = ComposerStore.mentionRows(query: query, listing: listing)
      if mentionCandidates != rows { mentionCandidates = rows }
      if mentionProblem != nil { mentionProblem = nil }
    } catch {
      guard mentionQuery == query else { return }
      mentionCandidates = []
      mentionProblem = "Could not list the folder: \(coreError(error).message)"
    }
  }

  /// `path` relative to `root`, or `path` itself outside it.
  static func relative(_ path: String, to root: String) -> String {
    let prefix = root == "/" ? "/" : root + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
  }

  /// Tags `path` (a file, or a folder ending in `/`) to go with the first message.
  /// - Parameter path: The folder-relative path.
  public func addMention(_ path: String) {
    guard !path.isEmpty, !mentions.contains(path) else { return }
    mentions.append(path)
  }

  /// Untags `path`.
  /// - Parameter path: The path.
  public func removeMention(_ path: String) {
    mentions.removeAll { $0 == path }
  }

  /// Clears the tags after the session started.
  public func clearMentions() {
    if !mentions.isEmpty { mentions = [] }
  }

  /// `text` with the tagged paths' marker lines ahead of it, worded for `harness`.
  /// - Parameters:
  ///   - text: The first message.
  ///   - harness: The session's harness.
  /// - Returns: The message to send.
  public func message(_ text: String, harness: String?) -> String {
    guard !mentions.isEmpty else { return text }
    return OmnigentCoreFFI.mentionPreamble(harness: harness, paths: mentions) + text
  }
}

extension ConnectionStore {
  /// The new-session composer's skills and mentions; `nil` without a core.
  public func launchCompletions() -> LaunchCompletionsStore? {
    core.map { LaunchCompletionsStore(core: $0) }
  }
}

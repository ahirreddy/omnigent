#if DEBUG
  import Dispatch
  import Foundation
  import OSLog
  public import SwiftUI
  import notify

  /// Darwin notifications that another process posts (`notifyutil -p <name>`), for debug-build
  /// measurement hooks driven from a script.
  @MainActor
  public enum DarwinNotifications {
    /// Calls `handler` on the main thread each time `name` is posted.
    /// - Parameters:
    ///   - name: The notification name.
    ///   - handler: Runs on the main thread.
    /// - Returns: The registration token, for ``cancel(_:)``.
    @discardableResult
    public static func observe(_ name: String, _ handler: @escaping @MainActor () -> Void) -> Int32
    {
      var token: Int32 = 0
      let status = unsafe notify_register_dispatch(name, &token, .main) { _ in
        MainActor.assumeIsolated { handler() }
      }
      precondition(
        status == NOTIFY_STATUS_OK, "notify_register_dispatch(\(name)) failed: \(status)")
      return token
    }

    /// Stops a registration.
    /// - Parameter token: What ``observe(_:_:)`` returned.
    public static func cancel(_ token: Int32) {
      notify_cancel(token)
    }
  }

  extension View {
    /// Runs `action` with the name's suffix after `ai.omnigent.perf.` whenever one of `names`
    /// is posted while the view is on screen (debug measurement hooks).
    /// - Parameters:
    ///   - names: Suffixes after `ai.omnigent.perf.`.
    ///   - action: Runs on the main thread with the posted suffix.
    /// - Returns: The view.
    public func perfHooks(_ names: [String], action: @escaping @MainActor (String) -> Void)
      -> some View
    {
      modifier(PerfHooks(names: names, action: action))
    }
  }

  private struct PerfHooks: ViewModifier {
    let names: [String]
    let action: @MainActor (String) -> Void
    @State private var tokens: [Int32] = []

    func body(content: Content) -> some View {
      content
        .onAppear {
          tokens = names.map { name in
            DarwinNotifications.observe("ai.omnigent.perf.\(name)") { action(name) }
          }
        }
        .onDisappear {
          tokens.forEach(DarwinNotifications.cancel)
          tokens = []
        }
    }
  }

  /// A faster channel than `simctl spawn notifyutil` (which takes tens of seconds on a busy
  /// machine): a script appends `<sequence> <name>` lines to `tmp/perf-command` in the app's
  /// container, and the app posts `ai.omnigent.perf.<name>` itself for each new sequence.
  @MainActor
  final class PerfCommandFile {
    private static let logger = Logger(subsystem: FrameMonitor.subsystem, category: "commands")
    private let file = FileManager.default.temporaryDirectory.appending(path: "perf-command")
    private var lastSequence: Int?
    private var timer: Timer?

    /// Checks the file every 50 ms.
    func start() {
      timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.check() }
      }
    }

    private func check() {
      let text: String
      do {
        text = try String(contentsOf: file, encoding: .utf8)
      } catch CocoaError.fileReadNoSuchFile {
        return
      } catch {
        Self.logger.error(
          "Reading the command file: \(error.localizedDescription, privacy: .public)")
        return
      }
      let commands = Self.commands(in: text)
      guard let newest = commands.map(\.sequence).max() else { return }
      defer { lastSequence = newest }
      // Commands left from an earlier launch are not for this one.
      if lastSequence == nil, let modified = Self.modified(file),
        modified < Date().addingTimeInterval(-2)
      {
        return
      }
      for command in commands where command.sequence > (lastSequence ?? 0) {
        unsafe notify_post("ai.omnigent.perf.\(command.name)")
      }
    }

    /// The `<sequence> <name>` lines in `text`, in order.
    static func commands(in text: String) -> [(sequence: Int, name: String)] {
      text.split(whereSeparator: \.isNewline).compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let sequence = Int(parts[0]) else { return nil }
        let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (sequence, name)
      }
    }

    /// When the file last changed, or `nil` when that can't be read, as when it just went away.
    static func modified(_ file: URL) -> Date? {
      do {
        return try file.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
      } catch {
        logger.error(
          "Reading the command file's date: \(error.localizedDescription, privacy: .public)")
        return nil
      }
    }
  }
#endif

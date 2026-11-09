#if DEBUG
  import AppKit
  import Foundation
  import MetricKit
  import SwiftUI
  import Testing
  import notify

  @testable import OmnigentPlatform

  /// Lets timers (the run loop) and notifications (the main queue) fire until `condition` holds.
  @MainActor
  private func spin(seconds: TimeInterval = 2, until condition: () -> Bool = { false }) async
    -> Bool
  {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      spinRunLoop()
      do {
        try await Task.sleep(for: .milliseconds(5))
      } catch {
        return condition()
      }
    }
    return condition()
  }

  @MainActor
  private func spinRunLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  }

  private func uniqueName() -> String { "omnigent-test-\(UUID().uuidString)" }

  @MainActor
  @Suite("Hostile perf commands", .serialized)
  struct HostilePerfCommandTests {
    private let file = FileManager.default.temporaryDirectory.appending(path: "perf-command")

    /// Runs `body` with the command file free, and leaves no file behind.
    private func withCommandFile(_ body: () async throws -> Void) async throws {
      try #require(!FileManager.default.fileExists(atPath: file.path))
      defer {
        do {
          try FileManager.default.removeItem(at: file)
        } catch {
          // A test that wrote nothing has nothing to remove.
        }
      }
      try await body()
    }

    @Test("lines that are not commands are skipped")
    func parsing() {
      let lines = [
        "", " ", "\n\n", "1", "1 ", "x y", "1.5 x", "99999999999999999999 x", "٣ x", "1\tx",
        "\u{0} x", "0x10 y",
      ]
      for line in lines {
        let commands = PerfCommandFile.commands(in: line)
        #expect(commands.isEmpty || commands.allSatisfy { $0.sequence == 1 }, "\(line)")
      }
      #expect(PerfCommandFile.commands(in: "99999999999999999999 x").isEmpty)
      #expect(PerfCommandFile.commands(in: "-5 x").map(\.sequence) == [-5])
      #expect(PerfCommandFile.commands(in: "+5 x").map(\.sequence) == [5])
      #expect(PerfCommandFile.commands(in: "\(Int.max) x").map(\.sequence) == [.max])
      #expect(
        PerfCommandFile.commands(in: "1 a b  c\r\n2 d\r3 e").map(\.name) == ["a b  c", "d", "e"])
      #expect(PerfCommandFile.commands(in: "1  spaced ").map(\.name) == ["spaced"])
      #expect(PerfCommandFile.commands(in: "1 👩‍👩‍👧‍👦").map(\.name) == ["👩‍👩‍👧‍👦"])
      let many = (0..<50_000).map { "\($0) x" }.joined(separator: "\n")
      #expect(PerfCommandFile.commands(in: many).count == 50_000)
    }

    @Test(
      "a line with only spaces after its number names nothing")
    func blankName() {
      #expect(PerfCommandFile.commands(in: "1  ").isEmpty)
    }

    @Test("a new command is posted once under its name")
    func postsNewCommands() async throws {
      try await withCommandFile {
        let name = uniqueName()
        var calls = 0
        let token = DarwinNotifications.observe("ai.omnigent.perf.\(name)") { calls += 1 }
        defer { DarwinNotifications.cancel(token) }
        let commands = PerfCommandFile()
        commands.start()
        try Data("1 \(name)\n".utf8).write(to: file)
        #expect(await spin { calls == 1 })
        _ = await spin(seconds: 0.2)
        #expect(calls == 1)
        try Data("1 \(name)\n2 \(name)\n".utf8).write(to: file)
        #expect(await spin { calls == 2 })
      }
    }

    @Test("commands from an earlier launch are not replayed")
    func staleCommands() async throws {
      try await withCommandFile {
        let name = uniqueName()
        var calls = 0
        let token = DarwinNotifications.observe("ai.omnigent.perf.\(name)") { calls += 1 }
        defer { DarwinNotifications.cancel(token) }
        try Data("1 \(name)\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
          [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
        let commands = PerfCommandFile()
        commands.start()
        _ = await spin(seconds: 0.2)
        #expect(calls == 0)
        try Data("1 \(name)\n2 \(name)\n".utf8).write(to: file)
        #expect(await spin { calls == 1 })
      }
    }

    @Test(
      "commands out of order post once"
    )
    func outOfOrderCommands() async throws {
      try await withCommandFile {
        let name = uniqueName()
        var calls = 0
        let token = DarwinNotifications.observe("ai.omnigent.perf.\(name)") { calls += 1 }
        defer { DarwinNotifications.cancel(token) }
        let commands = PerfCommandFile()
        commands.start()
        try Data("5 \(name)\n3 other-\(name)\n".utf8).write(to: file)
        #expect(await spin { calls >= 1 })
        _ = await spin(seconds: 0.3)
        #expect(calls == 1)
      }
    }

    @Test("a file that is not text, is empty or is a directory does nothing")
    func unreadableFiles() async throws {
      try await withCommandFile {
        let commands = PerfCommandFile()
        commands.start()
        _ = await spin(seconds: 0.1)
        try Data([0xFF, 0xFE, 0x00, 0xC0]).write(to: file)
        _ = await spin(seconds: 0.1)
        try Data().write(to: file)
        _ = await spin(seconds: 0.1)
        try Data("garbage only\n".utf8).write(to: file)
        _ = await spin(seconds: 0.1)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        _ = await spin(seconds: 0.1)
        #expect(FileManager.default.fileExists(atPath: file.path))
      }
    }

    @Test("a command that no longer has an owner keeps its timer harmless")
    func releasedCommands() async {
      weak var released: PerfCommandFile?
      do {
        let commands = PerfCommandFile()
        commands.start()
        released = commands
      }
      _ = await spin(seconds: 0.1)
      #expect(released == nil)
    }
  }

  @MainActor
  @Suite("Hostile Darwin notifications", .serialized)
  struct HostileDarwinNotificationTests {
    private func post(_ name: String) { _ = unsafe notify_post(name) }

    @Test("empty, stacked and odd names register and cancel")
    func oddNames() async {
      let names = [
        "omnigent-test-👩‍👩‍👧‍👦-\(UUID())", "omnigent test \(UUID())", "omnigent-test\n\(UUID())",
      ]
      for name in names {
        var calls = 0
        let token = DarwinNotifications.observe(name) { calls += 1 }
        post(name)
        #expect(await spin { calls == 1 }, "\(name)")
        DarwinNotifications.cancel(token)
      }
    }

    @Test("an empty name")
    func emptyName() {
      DarwinNotifications.cancel(DarwinNotifications.observe("") {})
    }

    @Test("a name cut short by a NUL")
    func nameWithNUL() {
      DarwinNotifications.cancel(DarwinNotifications.observe("omnigent-test\u{0}\(UUID())") {})
    }

    @Test("a very long name")
    func longName() {
      let name = "omnigent-test-" + String(repeating: "x", count: 100_000)
      DarwinNotifications.cancel(DarwinNotifications.observe(name) {})
    }

    @Test("many registrations come and go")
    func manyRegistrations() async {
      let name = uniqueName()
      var calls = 0
      let tokens = (0..<500).map { _ in DarwinNotifications.observe(name) { calls += 1 } }
      post(name)
      #expect(await spin { calls == 500 })
      tokens.forEach(DarwinNotifications.cancel)
    }

    @Test("perf hooks listen from when a view appears until it disappears")
    func perfHooks() async throws {
      _ = NSApplication.shared
      let first = uniqueName()
      let second = uniqueName()
      var heard: [String] = []
      let view = Color.clear.frame(width: 20, height: 20)
        .perfHooks([first, second, second, ""]) { heard.append($0) }
      let host = NSHostingView(rootView: view)
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      _ = await spin(seconds: 0.2)
      post("ai.omnigent.perf.\(first)")
      #expect(await spin { heard == [first] })
      post("ai.omnigent.perf.\(second)")
      #expect(await spin { heard == [first, second, second] })
      window.contentView = nil
      _ = await spin(seconds: 0.2)
      let count = heard.count
      post("ai.omnigent.perf.\(first)")
      _ = await spin(seconds: 0.2)
      #expect(heard.count == count)
    }

    @Test("a view with no hooks draws")
    func noHooks() {
      let host = NSHostingView(rootView: Color.clear.perfHooks([]) { _ in })
      host.layoutSubtreeIfNeeded()
      #expect(host.frame.width >= 0)
    }
  }

  @MainActor
  @Suite("Frame monitor", .serialized)
  struct FrameMonitorTests {
    // swiftlint:disable:next discouraged_optional_boolean
    private func defaults(setting value: Bool? = nil) throws -> UserDefaults {
      let name = "FrameMonitorTests"
      let store = try #require(UserDefaults(suiteName: name))
      store.removePersistentDomain(forName: name)
      if let value { store.set(value, forKey: FrameMonitor.launchArgument) }
      return store
    }

    /// One test, because the monitor is a process-wide singleton that never stops.
    @Test("marks do nothing until the launch argument starts it, then count and log")
    func lifecycle() async throws {
      _ = NSApplication.shared
      FrameMonitor.count("before")
      FrameMonitor.begin("before")
      FrameMonitor.end()
      FrameMonitor.startIfRequested(defaults: try defaults())
      FrameMonitor.startIfRequested(defaults: try defaults(setting: false))
      FrameMonitor.count("still off")

      FrameMonitor.startIfRequested(defaults: try defaults(setting: true))
      FrameMonitor.startIfRequested(defaults: try defaults(setting: true))
      FrameMonitor.end()
      for name in ["", "\u{0}", "👩‍👩‍👧‍👦", String(repeating: "W", count: 10_000)] {
        FrameMonitor.count(name)
        FrameMonitor.begin(name)
        FrameMonitor.count(name)
        FrameMonitor.begin(name)
        _ = await spin(seconds: 0.05)
        FrameMonitor.end()
        FrameMonitor.end()
      }
      NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
      // Past a second, so the display link logs its per-second line when a screen is awake.
      _ = await spin(seconds: 1.2)
      #expect(FrameMonitor.subsystem == "ai.omnigent.perf")
    }

    @Test("no MetricKit payloads log nothing")
    func metricKit() {
      let log = MetricKitLog()
      log.didReceive([MXMetricPayload]())
      log.didReceive([MXDiagnosticPayload]())
    }
  }
#endif

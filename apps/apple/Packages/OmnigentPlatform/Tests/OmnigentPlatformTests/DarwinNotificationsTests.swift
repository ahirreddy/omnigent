#if DEBUG
  import Foundation
  import Testing
  import notify

  @testable import OmnigentPlatform

  /// Posts use a name of their own, so no running app is listening for them.
  @MainActor
  @Suite("Darwin notifications")
  struct DarwinNotificationsTests {
    private func uniqueName() -> String { "ai.omnigent.tests.\(UUID().uuidString)" }

    private func post(_ name: String) { _ = unsafe notify_post(name) }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
      for _ in 0..<200 {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
      }
      return condition()
    }

    /// Long enough for a delivery that would come to arrive.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }

    @Test("A post calls the handler until the registration is cancelled")
    func observeAndCancel() async throws {
      let name = uniqueName()
      var calls = 0
      let token = DarwinNotifications.observe(name) { calls += 1 }
      post(name)
      #expect(try await eventually { calls == 1 })

      DarwinNotifications.cancel(token)
      post(name)
      try await settle()
      #expect(calls == 1)
    }

    @Test("A post reaches only the handlers of its own name")
    func namesStaySeparate() async throws {
      let first = uniqueName()
      let second = uniqueName()
      var calls: [String] = []
      let tokens = [
        DarwinNotifications.observe(first) { calls.append("first") },
        DarwinNotifications.observe(second) { calls.append("second") },
      ]
      defer { tokens.forEach(DarwinNotifications.cancel) }
      #expect(tokens[0] != tokens[1])
      post(second)
      #expect(try await eventually { calls == ["second"] })
    }

    @Test("Two handlers of one name both run; cancelling one leaves the other")
    func twoHandlers() async throws {
      let name = uniqueName()
      var first = 0
      var second = 0
      let firstToken = DarwinNotifications.observe(name) { first += 1 }
      let secondToken = DarwinNotifications.observe(name) { second += 1 }
      defer { DarwinNotifications.cancel(secondToken) }
      post(name)
      #expect(try await eventually { first == 1 && second == 1 })
      DarwinNotifications.cancel(firstToken)
      post(name)
      #expect(try await eventually { second == 2 })
      #expect(first == 1)
    }

    @Test("Cancelling a token twice or one that never existed does nothing")
    func oddTokens() async throws {
      let name = uniqueName()
      var calls = 0
      let token = DarwinNotifications.observe(name) { calls += 1 }
      DarwinNotifications.cancel(token)
      DarwinNotifications.cancel(token)
      DarwinNotifications.cancel(-1)
      DarwinNotifications.cancel(.max)
      post(name)
      try await settle()
      #expect(calls == 0)
    }

    @Test("Command lines that don't parse are skipped, whatever they hold")
    func oddCommandLines() {
      let huge = String(repeating: "9", count: 40)
      let long = String(repeating: "x", count: 100_000)
      let text = "\n \n1\n\(huge) overflow\n-3 negative\nnope name\n2   spaced  \n3 \(long)\n"
      let commands = PerfCommandFile.commands(in: text)
      #expect(commands.map(\.sequence) == [-3, 2, 3])
      #expect(commands.map(\.name) == ["negative", "spaced", long])
      #expect(PerfCommandFile.commands(in: "").isEmpty)
    }
  }
#endif

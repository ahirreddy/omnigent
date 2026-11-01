internal import AppKit
internal import Darwin
internal import Foundation
internal import OmnigentWebLayer

struct ProofFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// Scripted end-to-end checks, driven through the same paths a user and an agent use: NSEvents
/// sent to the window for user input, `WebContentRenderer` agent calls for agent input.
final class Proofs {
  static let all = [
    "boot", "render", "pixels", "input", "select", "js", "keys", "cookies", "agent", "crash",
    "hang",
  ]

  /// Scenario by name. "quit" only waits for the first page; the app then quits.
  static let scenarios: [String: (Proofs) -> () async throws -> Void] = [
    "boot": { $0.boot }, "render": { $0.render }, "pixels": { $0.pixels },
    "input": { $0.input }, "select": { $0.select }, "js": { $0.javascript },
    "keys": { $0.unhandledKeys }, "cookies": { $0.cookies }, "agent": { $0.agentInput },
    "crash": { $0.crashRecovery }, "hang": { $0.hangRecovery }, "spike": { $0.renderingSpike },
    "quit": { $0.waitForPage },
  ]

  let model: ExampleModel
  var webView: WebView { model.webView }
  var outputDirectory: URL { model.options.output }

  init(model: ExampleModel) {
    self.model = model
  }

  func run(_ names: [String]) async -> Int {
    var failures = 0
    do {
      try await waitUntil("a visible window", timeout: 5) { self.window != nil }
    } catch {
      Clock.log("FAIL setup: \(error)")
      return 1
    }
    NSApp.activate()
    // Keep the window on screen: an occluded window is reported hidden and stops rendering.
    window?.level = .floating
    window?.makeKeyAndOrderFront(nil)
    for name in names.flatMap({ $0 == "all" ? Self.all : [$0] }) {
      Clock.log("== proof \(name)")
      do {
        guard let scenario = Self.scenarios[name] else {
          throw ProofFailure("Unknown proof \(name)")
        }
        try await scenario(self)()
        Clock.log("PASS \(name)")
      } catch {
        failures += 1
        Clock.log("FAIL \(name): \(error)")
      }
    }
    return failures
  }

}

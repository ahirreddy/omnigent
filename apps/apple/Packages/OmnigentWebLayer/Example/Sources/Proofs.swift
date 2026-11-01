internal import AppKit
internal import Darwin
internal import Foundation
internal import OmnigentBrowser
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
    // Protocol 1.1 browser UI, through the shared OmnigentBrowser UI (`--engine` picks one).
    "dialogs": { $0.dialogs }, "permissions": { $0.permissions }, "files": { $0.files },
    "downloads": { $0.downloads }, "auth": { $0.authentication }, "certs": { $0.certificates },
    "popups": { $0.popups }, "menu": { $0.contextMenu }, "ime": { $0.ime },
    "drag": { $0.dragAndDrop },
    "color": { $0.color }, "agent-actions": { $0.agentActions },
  ]

  /// The 1.1 proofs, in order.
  static let browserUI = [
    "dialogs", "permissions", "files", "downloads", "auth", "certs", "popups", "menu", "ime",
    "drag", "color", "agent-actions",
  ]

  let model: ExampleModel
  var webView: WebView { model.webView }
  var outputDirectory: URL { model.options.output }
  /// The engine the browser-UI proofs run on.
  var engine: BrowserEngineKind { model.options.engine }
  private(set) lazy var provider = HarnessProvider(session: model.session)
  var server: ProofServer?

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
    defer { server?.stop() }
    let expanded = names.flatMap { name in
      name == "all" ? Self.all : name == "browser-ui" ? Self.browserUI : [name]
    }
    for name in expanded {
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

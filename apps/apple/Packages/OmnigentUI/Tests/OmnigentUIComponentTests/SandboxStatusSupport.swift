#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI

  @testable import OmnigentUIComponents

  /// Sandbox states as the app's adapter hands them over.
  @MainActor
  enum SandboxFixture {
    static let wake = SandboxStatusState.Operation(
      id: "wake", title: "Wake", help: "Brings the sandbox and its agent back.")
    static let stop = SandboxStatusState.Operation(
      id: "stop", title: "Stop Agent", help: "Ends the agent\u{2019}s process.",
      isDestructive: true)

    /// A sandbox showing `mark` and `summary`, with Wake and Stop both applying.
    static func state(
      _ mark: SandboxStatusState.Mark, _ summary: String,
      operations: [SandboxStatusState.Operation] = [wake, stop]
    ) -> SandboxStatusState {
      SandboxStatusState(
        mark: mark, title: "Modal Sandbox", summary: summary, operations: operations)
    }

    static var running: SandboxStatusState {
      var state = state(.running, "Running")
      state.host = .online
      state.runner = .online
      return state
    }

    /// Actions that record each operation asked for and answer with `refusal`.
    static func actions(_ log: HostLog, refusal: String? = nil) -> SandboxStatusActions {
      SandboxStatusActions { id in
        log.add(id)
        return refusal
      }
    }
  }

  extension OffscreenWindow {
    /// The middle of the accessibility element with `identifier`, as a click point.
    func center(of identifier: String) throws -> CGPoint {
      let frame = try withAccessibilityTree { try accessibilityFrame(identifier) }
      return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Whether the accessibility tree has an element with `identifier`.
    func hasElement(_ identifier: String) throws -> Bool {
      try withAccessibilityTree {
        do {
          _ = try accessibilityElement(identifier)
          return true
        } catch OffscreenWindowError.notFound {
          return false
        }
      }
    }

    /// The words the element with `identifier` gives assistive technology: its label, title
    /// and value, whichever it has.
    func words(of identifier: String) throws -> [String] {
      try withAccessibilityTree {
        let element = try accessibilityElement(identifier)
        let names = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
        return names.compactMap { name in
          guard element.responds(to: NSSelectorFromString(name)) else { return nil }
          return element.value(forKey: name) as? String
        }
      }
    }
  }
#endif

import Foundation
import Testing

@testable import OmnigentTerminalUI

@Suite("Terminal clipboard policy")
@MainActor
struct ClipboardPolicyTests {
  @Test("a remote copy asks, or is refused visibly, as the setting says")
  func remoteCopyFollowsThePolicy() throws {
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    controller.remoteCopied("rm -rf ~", policy: .ask)
    #expect(controller.pendingClipboard?.text == "rm -rf ~")
    controller.declinePendingClipboard()

    controller.remoteCopied("rm -rf ~", policy: .block)
    #expect(controller.pendingClipboard == nil)
    #expect(controller.lastError?.contains("blocked") == true)
  }

  @Test("an unset or unknown stored policy asks")
  func storedPolicyDefaultsToAsk() throws {
    let defaults = try #require(UserDefaults(suiteName: "ClipboardPolicyTests"))
    defaults.removePersistentDomain(forName: "ClipboardPolicyTests")
    #expect(TerminalClipboardPolicy.current(defaults) == .ask)
    defaults.set("sometimes", forKey: TerminalClipboardPolicy.key)
    #expect(TerminalClipboardPolicy.current(defaults) == .ask)
    defaults.set("block", forKey: TerminalClipboardPolicy.key)
    #expect(TerminalClipboardPolicy.current(defaults) == .block)
  }
}

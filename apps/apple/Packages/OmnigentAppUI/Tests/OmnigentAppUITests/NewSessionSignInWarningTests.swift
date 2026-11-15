import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A host that reports no sign-in: an in-process SDK agent still starts, with the web's warning
/// in the composer's notice line, and a CLI harness stays blocked.
@MainActor
@Suite("New session sign-in warning", .timeLimit(.minutes(1)))
struct NewSessionSignInWarningTests {
  @Test("An SDK agent needing a sign-in starts with a warning; a CLI one isn't ready")
  func sdkAgentWarnsAndCLIAgentIsBlocked() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/hosts",
      .json(
        #"{"hosts":[{"host_id":"mac","name":"Mac","status":"online","configured_harnesses":{"claude-native":"needs-auth","agents_sdk":"needs-auth"}}]}"#
      ))
    server.route(
      "/v1/agents",
      .json(
        #"{"data":[{"id":"ag_claude","name":"Claude","harness":"claude-native"},{"id":"ag_mock","name":"mock-model","harness":"agents_sdk"}],"has_more":false}"#
      ))
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    #expect(form.selection.agentId == "ag_mock", "the SDK agent is the one that can start")

    let warning = try #require(form.harnessNotice(creation))
    #expect(warning.text.hasPrefix("Authentication may be required."))
    #expect(warning.text.hasSuffix("Launching may fail unless the agent supplies its own."))
    #expect(warning.name == "mock-model")
    #expect(form.options(creation).harnessNotice == warning.text)
    form.selectFolder(creation, "/work")
    try await eventually("the start is offered") {
      form.composerState(creation, connection: connection).availability == .available
    }

    form.selectAgent("ag_claude", creation)
    #expect(form.harnessNotice(creation)?.text == "Claude isn't ready on Mac.")
    let reason = form.composerState(creation, connection: connection).availability.reason
    #expect(reason?.hasPrefix("Authentication required. Sign in or add credentials") == true)
  }
}

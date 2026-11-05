import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@Suite("A conversation opening")
@MainActor
struct ConversationPlaceholderTests {
  private func header(title: String, placeholder: Bool) -> SessionHeader {
    SessionHeader(
      id: "s1", title: title, status: .idle, readOnly: placeholder, archived: false,
      permissionLevel: nil, failureMessage: nil, settings: nil, isPlaceholder: placeholder)
  }

  @Test("the core's stand-in header reads as loading, not as a read-only \"Conversation\"")
  func placeholderHeaderIsNoHeader() throws {
    let core = try ClientCore(
      http: FakeHttpTransport(failingWith: .Other(message: "unused")),
      streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(), clock: SystemClock(),
      scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let conversation = ConversationStore(sessionID: "s1", core: core)
    conversation.reset(
      revision: 1, rows: [], header: header(title: "Conversation", placeholder: true),
      sections: [], decisions: [])
    #expect(conversation.header == nil)
    let real = header(title: "Fix the build", placeholder: false)
    conversation.reset(revision: 2, rows: [], header: real, sections: [], decisions: [])
    #expect(conversation.header == real)
  }
}

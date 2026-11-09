import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Conversation stores fed by hand, so a test can give an adapter data no server should send.
@MainActor
enum ConversationFixtures {
  /// A connection to a server with sign-in off; `routes` add to or replace its answers, and any
  /// other request is answered 404.
  static func connection(routes: [String: HttpResponse] = [:]) async throws -> ConnectionStore {
    let base: [String: HttpResponse] = [
      "/.well-known/omnigent.json": .json(ManifestFixtures.localNoAuth),
      "/v1/info": .json(#"{"single_user":true,"accounts_enabled":false}"#),
      "/v1/me": .json(#"{"user_id":"local"}"#),
      "/v1/sessions": .json(#"{"data":[],"has_more":false}"#),
    ]
    let http = FakeHttpTransport(routes: base.merging(routes) { _, new in new })
    let core = try ClientCore(
      http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let connection = ConnectionStore(core: core)
    await connection.connect(serverURL: "http://127.0.0.1:6767")
    // The first list read would replace rows a test feeds in, so it finishes first.
    let deadline = ContinuousClock.now + .seconds(10)
    while !connection.sessionList.isLoaded, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(connection.sessionList.isLoaded)
    return connection
  }

  /// A connected core; see ``connection(routes:)``.
  static func core(routes: [String: HttpResponse] = [:]) async throws -> ClientCore {
    try #require(try await connection(routes: routes).core)
  }

  /// A store holding `header` and `sections`.
  static func store(
    header: SessionHeader? = nil, sections: [EventSection] = [], rows: [Row] = [],
    hydrated: Bool = true
  ) async throws -> ConversationStore {
    let store = ConversationStore(sessionID: "conv", core: try await core())
    let inserts = rows.enumerated().map { RowOp.insert(index: UInt32($0.offset), row: $0.element) }
    store.apply(
      revision: 1, change: TranscriptChange(rows: inserts, header: header, sections: sections))
    if hydrated { store.hydrated() }
    return store
  }

  static func settings(
    harness: String? = "claude-sdk", wrapper: String? = nil, agentID: String? = "agent",
    parentID: String? = nil, sideChatSourceID: String? = nil, routingMode: String? = nil,
    modelOverride: ReportedValue = .notReported, effort: ReportedValue = .notReported,
    // swiftlint:disable:next discouraged_optional_boolean
    hostOnline: Bool? = true
  ) -> SessionSettings {
    SessionSettings(
      agentId: agentID, harness: harness, wrapper: wrapper, modelOverride: modelOverride,
      baseModel: nil, reasoningEffort: effort, modelOptions: [], hostId: "host",
      hostOnline: hostOnline, runnerOnline: true, runnerBound: true, hostResumable: nil,
      parentId: parentID, sideChatSourceId: sideChatSourceID, routingMode: routingMode)
  }

  static func header(
    settings: SessionSettings? = nil, readOnly: Bool = false, archived: Bool = false,
    status: TurnStatus = .idle
  ) -> SessionHeader {
    SessionHeader(
      id: "conv", title: "", status: status, readOnly: readOnly, archived: archived,
      permissionLevel: nil, failureMessage: nil, settings: settings)
  }

  static func section(_ id: String, summary: String = "", details: [(String, String)] = [])
    -> EventSection
  {
    EventSection(
      id: id, title: id, summary: summary,
      details: details.map { DetailSection(id: $0.0, title: $0.0, text: $0.1, isCode: false) },
      sessionId: nil)
  }

  static func userRow(_ id: String, text: String, role: RowRole = .user) -> Row {
    Row(
      id: id, role: role, text: text, isStreaming: false, activity: nil, attachments: [],
      callId: nil, responseId: nil, interrupted: false, author: nil, agent: nil, createdAt: nil,
      isEphemeral: false, isActivityOnly: false)
  }

  static func configuration(
    harness: String? = "claude-sdk", wrapper: String? = nil, routingMode: String? = nil
  ) -> SessionConfiguration {
    SessionConfiguration(
      agentId: "agent", harness: harness, wrapper: wrapper, modelOverride: nil, baseModel: nil,
      effort: nil, modelReported: true, effortReported: true, models: [], hostId: "host",
      hostOnline: true, runnerOnline: true, runnerBound: true, hostResumable: nil, parentId: nil,
      routingMode: routingMode)
  }

  /// A session row with nothing set beyond what a test names.
  static func summary(
    _ id: String, status: SessionListStatus = .idle, updatedAt: Int64 = 0, title: String = "",
    preview: String = "", workspace: String = "", isArchived: Bool = false,
    isReadOnly: Bool = false, failureMessage: String? = nil, pendingRequests: UInt32 = 0,
    configuration: SessionConfiguration? = nil, commentsCount: UInt64 = 0
  ) -> SessionSummary {
    SessionSummary(
      id: id, title: title, preview: preview, status: status, pendingRequests: pendingRequests,
      isReadOnly: isReadOnly, updatedAt: updatedAt, workspace: workspace, agentName: "",
      isPinned: false, isArchived: isArchived, permissionLevel: nil,
      failureMessage: failureMessage, canRename: false, canPin: false, canArchive: false,
      configuration: configuration, commentsCount: commentsCount)
  }
}

import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The source session of the nested agent tests, on `mac` in `/work/app`.
nonisolated let nestedSourceRow =
  #"{"id":"conv_src","status":"idle","created_at":1,"updated_at":5,"title":"Coordinator","host_id":"mac","workspace":"/work/app","permission_level":4,"archived":false}"#

/// `newSessionServer()` offering nested agents under `policy` (or not at all), new sandboxes when
/// `sandboxes`, the source session in its list, and a created session that takes its message.
/// `sandboxHost` adds a sandbox host of that id to the hosts.
nonisolated func nestedServer(
  policy: String = "any_host", siblings: Bool = true, sandboxes: Bool = false,
  sandboxHost: String? = nil
) -> AppServer {
  let server = newSessionServer()
  server.route(
    "/v1/info",
    .json(
      #"{"single_user":true,"accounts_enabled":false,"sibling_sessions":\#(siblings),"sibling_session_destinations":"\#(policy)","managed_sandboxes_enabled":\#(sandboxes),"sandbox_provider":"modal"}"#
    ))
  var hosts = ["mac", "box"].map { id in
    #"{"host_id":"\#(id)","name":"\#(id)","status":"online","configured_harnesses":{"claude-native":true,"codex-native":true}}"#
  }
  if let sandboxHost {
    hosts.append(
      #"{"host_id":"\#(sandboxHost)","name":"\#(sandboxHost)","status":"online","sandbox_provider":"modal","configured_harnesses":{"claude-native":true,"codex-native":true}}"#
    )
  }
  server.route("/v1/hosts", .json(#"{"hosts":[\#(hosts.joined(separator: ","))]}"#))
  server.route(
    "/v1/sessions", method: "GET",
    .json(#"{"object":"list","data":[\#(nestedSourceRow)],"has_more":false}"#))
  server.route("/v1/sessions/conv_src", .json(nestedSourceRow))
  server.route(
    "/v1/sessions/conv_new",
    .json(
      #"{"id":"conv_new","status":"idle","created_at":1,"agent_id":"ag_claude","host_id":"mac","permission_level":4}"#
    ))
  server.route(
    "/v1/sessions/conv_new/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
  return server
}

/// What a nested composer asked its host to do.
@MainActor
final class NestedRoutes {
  let connection: ConnectionStore
  var opened: [String] = []
  var notices: [String] = []
  var continued = 0

  init(connection: ConnectionStore) {
    self.connection = connection
  }
}

/// A nested composer's form with the stores it reads.
@MainActor
struct LoadedNestedForm {
  let form: NewSessionForm
  let creation: CreationStore
  let connection: ConnectionStore

  /// The Host menu's row ids, as the composer shows them.
  var hostIDs: [String] {
    form.composerState(creation, connection: connection).hosts?.hosts.map(\.id) ?? []
  }
}

/// A form loaded as the composer beside `sourceID` opens it, outside any window.
@MainActor
func loadedNestedForm(
  _ server: AppServer, sourceID: String = "conv_src"
) async throws -> LoadedNestedForm {
  let connection = try await signedInStore(server)
  let creation = try #require(connection.creation())
  let form = try isolatedForm()
  form.nested = NestedComposer(sourceID: sourceID)
  await form.loadNested(creation)
  return LoadedNestedForm(form: form, creation: creation, connection: connection)
}

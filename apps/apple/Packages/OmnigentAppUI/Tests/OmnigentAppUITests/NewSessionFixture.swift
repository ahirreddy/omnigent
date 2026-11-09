import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentAppUI

/// A server with two machines, native Claude Code and Codex agents, models on each and home
/// folders that say which host they are on. `offline` hosts report offline.
nonisolated func newSessionServer(offline: Set<String> = []) -> AppServer {
  let server = AppServer()
  let hosts = ["mac", "box"].map { id in
    """
    {"host_id":"\(id)","name":"\(id)","status":"\(offline.contains(id) ? "offline" : "online")",\
    "configured_harnesses":{"claude-native":true,"codex-native":true}}
    """
  }
  server.route("/v1/hosts", .json(#"{"hosts":[\#(hosts.joined(separator: ","))]}"#))
  server.route(
    "/v1/agents",
    .json(
      #"{"data":[{"id":"ag_claude","name":"Claude","harness":"claude-native"},{"id":"ag_codex","name":"Codex","harness":"codex-native"}],"has_more":false}"#
    ))
  for host in ["mac", "box"] {
    for harness in ["claude-native", "codex-native"] {
      server.route(
        "/v1/hosts/\(host)/harnesses/\(harness)/model-options",
        .json(#"{"models":[{"id":"\#(harness)-fast","model":"\#(harness)-fast"}]}"#))
    }
    server.route(
      "/v1/hosts/\(host)/filesystem",
      .json(
        #"{"data":[{"name":"src","path":"/home/\#(host)/src","type":"directory"}],"has_more":false}"#
      ))
  }
  server.route(
    "/v1/sessions", method: "POST",
    .json(
      #"{"id":"conv_new","status":"idle","created_at":1,"agent_id":"ag_claude","host_id":"mac","permission_level":4}"#,
      status: 201))
  return server
}

/// A session row on `host` in `workspace`, as the list reports it.
nonisolated func sessionRow(
  _ id: String, host: String, workspace: String, updatedAt: Int64,
  status: String = "idle", archived: Bool = false
) -> String {
  """
  {"id":"\(id)","status":"\(status)","created_at":1,"updated_at":\(updatedAt),\
  "host_id":"\(host)","workspace":"\(workspace)","permission_level":4,\
  "archived":\(archived)}
  """
}

nonisolated private let scratchSuites = Mutex<[String]>([])
nonisolated private let scratchCleanup: Void = {
  atexit {
    for name in scratchSuites.withLock({ $0 }) {
      UserDefaults.standard.removePersistentDomain(forName: name)
    }
  }
}()

/// Defaults of their own, removed when the tests end so no file stays on the machine.
nonisolated func scratchDefaults() throws -> UserDefaults {
  _ = scratchCleanup
  let name = "omnigent-tests-\(UUID().uuidString)"
  scratchSuites.withLock { $0.append(name) }
  return try #require(UserDefaults(suiteName: name))
}

/// A form with its own defaults, so runs never share or touch the user's choices.
@MainActor
func isolatedForm() throws -> NewSessionForm {
  let form = NewSessionForm()
  form.preferences = try scratchDefaults()
  return form
}

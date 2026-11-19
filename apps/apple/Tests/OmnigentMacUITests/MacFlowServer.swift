import Foundation
import XCTest

/// The local server's API, for flows that set up and remove their own data: the projects they
/// create are named "UI flow …" and removed once the test ends, pass or fail, and a run first
/// removes those an earlier run left, so they never crowd a later flow's sidebar.
extension MacLiveUITestSupport {
  /// The start of every project name a flow creates.
  nonisolated static let flowProjectPrefix = "UI flow "
  /// Whether this run removed the projects earlier runs left.
  private static var removedLeftovers = false

  /// Sends a request to the local server the flows run on and reads its JSON object; an empty
  /// `body` (whose values may nest) sends none.
  func serverJSON(
    _ method: String, _ path: String, body: [String: Any] = [:]
  ) async throws -> [String: Any] {
    try await Self.serverJSON(method, path, body: body, on: server)
  }

  /// ``serverJSON(_:_:body:)`` on `server`, for a teardown, which outlives the test's support.
  nonisolated static func serverJSON(
    _ method: String, _ path: String, body: [String: Any] = [:], on server: String
  ) async throws -> [String: Any] {
    let url = try XCTUnwrap(URL(string: server + path))
    var request = URLRequest(url: url)
    request.httpMethod = method
    if !body.isEmpty {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    XCTAssertTrue((200..<300).contains(status), "\(method) \(path) answered \(status)")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// A new project named "UI flow `purpose` …", removed with its sessions once the test ends.
  func flowProject(_ purpose: String) async throws -> (id: String, name: String) {
    try await removeLeftoverFlowProjects()
    let name = "\(Self.flowProjectPrefix)\(purpose) \(UUID().uuidString.prefix(6))"
    let project = try await serverJSON("POST", "/v1/projects", body: ["name": name])
    let id = try XCTUnwrap(project["id"] as? String, "\(project)")
    let server = server
    test.addTeardownBlock {
      try await Self.removeFlowProject(id: id, name: name, on: server)
    }
    return (id, name)
  }

  /// Deletes `path` on the server once the test ends, pass or fail.
  func removeAfterTheTest(_ path: String) {
    let server = server
    test.addTeardownBlock {
      _ = try await Self.serverJSON("DELETE", path, on: server)
    }
  }

  /// Removes the "UI flow" projects on the server, once a run, before it makes its own: any
  /// there then are an earlier run's, left by a flow that failed or stopped.
  private func removeLeftoverFlowProjects() async throws {
    guard !Self.removedLeftovers else { return }
    Self.removedLeftovers = true
    let projects = try await serverJSON("GET", "/v1/projects")["data"] as? [[String: Any]] ?? []
    for project in projects {
      guard let id = project["id"] as? String, let name = project["name"] as? String,
        name.hasPrefix(Self.flowProjectPrefix)
      else { continue }
      try await Self.removeFlowProject(id: id, name: name, on: server)
    }
  }

  /// Deletes a flow's project: its sessions a flow made ("UI flow …") go too, and others, such as
  /// the fixture session a flow filed there, are taken out of it first.
  private nonisolated static func removeFlowProject(id: String, name: String, on server: String)
    async throws
  {
    let project = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
    let members =
      try await serverJSON(
        "GET", "/v1/sessions?project=\(project)&visibility=mine&limit=100", on: server)["data"]
      as? [[String: Any]] ?? []
    for member in members {
      guard let session = member["id"] as? String else { continue }
      if (member["title"] as? String)?.hasPrefix(flowProjectPrefix) == true {
        _ = try await serverJSON("DELETE", "/v1/sessions/\(session)", on: server)
      } else {
        _ = try await serverJSON(
          "PATCH", "/v1/sessions/\(session)", body: ["project_id": ""], on: server)
      }
    }
    _ = try await serverJSON("DELETE", "/v1/projects/\(id)", on: server)
  }
}

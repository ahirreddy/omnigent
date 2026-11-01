import Foundation
import Testing

@testable import OmnigentDesktop

@Suite("Server window registry")
@MainActor
struct ServerWindowRegistryTests {
  let workspace: ServerWindowID
  let workspaceTwin: ServerWindowID
  let local: ServerWindowID
  let connectScreen = ServerWindowID.newWindow(serverURL: nil)

  init() throws {
    workspace = try .newWindow(serverURL: url("https://workspace.example.com/ml/omnigents"))
    workspaceTwin = try .newWindow(serverURL: url("https://WORKSPACE.example.com:443/other"))
    local = try .newWindow(serverURL: url("http://localhost:8000"))
  }

  @Test("tracks windows in creation order and updates in place")
  func order() throws {
    let registry = ServerWindowRegistry()
    registry.update(workspace, isReady: false, viewedSessionID: nil, unreadCount: 0)
    registry.update(local, isReady: true, viewedSessionID: nil, unreadCount: 0)
    registry.update(workspace, isReady: true, viewedSessionID: "c1", unreadCount: 0)
    #expect(registry.entries.map(\.id) == [workspace, local])
    #expect(registry.entry(workspace.instance)?.viewedSessionID == "c1")
    #expect(
      registry.entry(workspace.instance)?.origin
        == (try ServerOrigin(serialized: "https://workspace.example.com")))
  }

  @Test("a window keeps its identity when it changes server")
  func rebinding() throws {
    let registry = ServerWindowRegistry()
    registry.update(connectScreen, isReady: false, viewedSessionID: nil, unreadCount: 0)
    let bound = try connectScreen.rebound(to: url("http://localhost:8000"))
    registry.update(bound, isReady: true, viewedSessionID: nil, unreadCount: 0)
    #expect(registry.entries.count == 1)
    #expect(registry.entries.first?.id == bound)
    #expect(registry.activeOrigins.count == 1)
  }

  @Test("the badge counts each server once and sums across servers")
  func unreadTotal() {
    let registry = ServerWindowRegistry()
    var published: [Int] = []
    registry.onUnreadTotalChange = { published.append($0) }
    registry.update(workspace, isReady: true, viewedSessionID: nil, unreadCount: 3)
    registry.update(workspaceTwin, isReady: true, viewedSessionID: nil, unreadCount: 4)
    registry.update(local, isReady: true, viewedSessionID: nil, unreadCount: 2)
    registry.update(connectScreen, isReady: false, viewedSessionID: nil, unreadCount: 9)
    #expect(registry.unreadTotal == 6)
    registry.update(local, isReady: true, viewedSessionID: nil, unreadCount: 2)
    registry.remove(workspaceTwin.instance)
    #expect(registry.unreadTotal == 5)
    registry.update(workspace, isReady: true, viewedSessionID: nil, unreadCount: -1)
    #expect(registry.unreadTotal == 2)
    #expect(published == [3, 4, 6, 5, 2])
  }

  @Test("pending routes wait until the window is ready")
  func pendingRoutes() {
    let registry = ServerWindowRegistry()
    registry.deliver(.conversation(sessionID: "c1"), to: workspace.instance)
    #expect(registry.takePendingRoute(for: workspace.instance) == nil)
    registry.update(workspace, isReady: false, viewedSessionID: nil, unreadCount: 0)
    #expect(registry.takePendingRoute(for: workspace.instance) == nil)
    #expect(registry.pendingRoute(for: workspace.instance) == .conversation(sessionID: "c1"))
    registry.update(workspace, isReady: true, viewedSessionID: nil, unreadCount: 0)
    #expect(registry.takePendingRoute(for: workspace.instance) == .conversation(sessionID: "c1"))
    #expect(registry.takePendingRoute(for: workspace.instance) == nil)
  }

  @Test("closing a window drops its pending route and key status")
  func removal() {
    let registry = ServerWindowRegistry()
    registry.update(workspace, isReady: true, viewedSessionID: nil, unreadCount: 0)
    registry.setKey(workspace.instance, isKey: true)
    registry.deliver(.home, to: workspace.instance)
    registry.remove(workspace.instance)
    #expect(registry.keyWindow == nil)
    #expect(registry.pendingRoute(for: workspace.instance) == nil)
    #expect(registry.entries.isEmpty)
  }

  @Test("notification context follows the key window")
  func notificationContext() throws {
    let registry = ServerWindowRegistry()
    registry.update(workspace, isReady: true, viewedSessionID: "c1", unreadCount: 0)
    registry.update(local, isReady: true, viewedSessionID: "c2", unreadCount: 0)
    registry.setKey(workspace.instance, isKey: true)
    registry.setKey(local.instance, isKey: true)
    registry.setKey(workspace.instance, isKey: false)
    let context = registry.notificationContext(appIsActive: true)
    #expect(
      context.viewing
        == ViewedSession(
          origin: try ServerOrigin(serialized: "http://localhost:8000"), sessionID: "c2"))
    #expect(context.activeServerCount == 2)
    #expect(context.appIsActive)
    registry.setKey(local.instance, isKey: false)
    #expect(registry.notificationContext(appIsActive: true).viewing == nil)
  }

  @Test("a window bound to a non-http URL is reported and never ready")
  func invalidServer() throws {
    var issues: [String] = []
    let registry = ServerWindowRegistry { issues.append("\($0)") }
    let ftp = try ServerWindowID.newWindow(serverURL: url("ftp://files.example.com"))
    registry.update(ftp, isReady: true, viewedSessionID: nil, unreadCount: 1)
    #expect(registry.entry(ftp.instance)?.isReady == false)
    #expect(registry.entry(ftp.instance)?.origin == nil)
    #expect(issues.count == 1)
    #expect(registry.unreadTotal == 0)
  }

  @Test("window values round-trip through Codable for restoration")
  func codable() throws {
    let data = try JSONEncoder().encode([workspace, connectScreen])
    #expect(
      try JSONDecoder().decode([ServerWindowID].self, from: data) == [workspace, connectScreen])
  }
}

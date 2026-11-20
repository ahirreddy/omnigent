import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Where an extension page's navigation leads in the app.
struct ExtensionNavigationRoutes {
  /// Shows a destination: another of the extension's pages, or a session.
  var show: @MainActor (SidebarDestination) -> Void
  /// Opens New session, filed into a project when given.
  var newSession: @MainActor (ProjectSummary?) -> Void
  /// Opens a web page the host handed the extension.
  var openExternal: @MainActor (URL) -> Void
}

/// The host methods of one extension, as the web's `useExtensionHostServices` implements them:
/// navigation, the theme, the user's storage, the caller's sessions and projects, and a session's
/// pull request. Parameters and results are checked and shaped by the core; reads of the session
/// list and pull requests are spaced 100 ms apart, and storage writes 25 ms apart.
@MainActor
final class LiveExtensionHostServices: ExtensionHostServices {
  let extensionItem: Extension
  let connection: ConnectionStore
  private let routes: ExtensionNavigationRoutes
  private let storage: ExtensionUserStorage?
  /// Whether the app shows dark; the page's controller answers.
  var isDark: @MainActor () -> Bool = { false }
  /// The pull request pages handed to the extension: the only external pages it may open.
  var externalURLs: Set<String> = []
  let sessionReads = ExtensionCallSpacing(interval: .milliseconds(100))
  let pullRequestReads = ExtensionCallSpacing(interval: .milliseconds(100))
  private let storageWrites = ExtensionCallSpacing(interval: .milliseconds(25))

  init(
    extensionItem: Extension, connection: ConnectionStore, routes: ExtensionNavigationRoutes,
    storage: ExtensionUserStorage?
  ) {
    self.extensionItem = extensionItem
    self.connection = connection
    self.routes = routes
    self.storage = storage
  }

  func perform(_ method: String, params: String?) async throws -> String {
    switch method {
    case "theme.getCurrent", "theme.subscribe":
      return extensionThemeResult(dark: isDark())
    case "sessions.getCached":
      return try cachedSessions(params)
    case "sessions.listPage":
      return try await sessionPage(params)
    case "sessions.pullRequest":
      return try await pullRequest(params)
    case "projects.list":
      return extensionProjectsResult(projects: try await projects().map(Self.projectRow))
    case "projects.create":
      return try await createProject(params)
    default:
      return try await method.hasPrefix("storage.")
        ? storageCall(method, params: params) : navigate(method, params: params)
    }
  }

  /// `navigation.*`: each answers `null` once it has gone where it was asked.
  private func navigate(_ method: String, params: String?) async throws -> String {
    switch method {
    case "navigation.openPage":
      let route = try extensionPageRoute(paramsJson: params, pages: extensionItem.pages)
      routes.show(.extensionPage(extensionID: extensionItem.id, route: route))
    case "navigation.openSession":
      routes.show(.session(try extensionSessionId(paramsJson: params)))
    case "navigation.openNewSession":
      try await openNewSession(params)
    case "navigation.openExternal":
      let url = try extensionExternalUrl(paramsJson: params)
      guard externalURLs.contains(url), let target = URL(string: url) else {
        throw ExtensionHostFault.Failed(
          code: "PermissionDenied", message: "URL was not provided by the host")
      }
      routes.openExternal(target)
    default:
      throw Self.notFound
    }
    return "null"
  }

  /// `storage.user.*`: a value read, or `null` once written or removed.
  private func storageCall(_ method: String, params: String?) async throws -> String {
    switch method {
    case "storage.user.get":
      return try userStorage().get(try extensionStorageKey(paramsJson: params)) ?? "null"
    case "storage.user.set":
      let write = try extensionStorageWrite(paramsJson: params)
      let storage = try userStorage()
      try await storageWrites.run { try storage.set(write) }
    case "storage.user.delete":
      let key = try extensionStorageKey(paramsJson: params)
      let storage = try userStorage()
      try await storageWrites.run { storage.delete(key) }
    default:
      throw Self.notFound
    }
    return "null"
  }

  private static let notFound = ExtensionHostFault.Failed(
    code: "MethodNotFound", message: "Host method is not available")

  private func userStorage() throws -> ExtensionUserStorage {
    guard let storage else {
      throw ExtensionHostFault.Failed(
        code: "Unavailable",
        message: "Extension storage requires resolved user and server identities")
    }
    return storage
  }

  private func openNewSession(_ params: String?) async throws {
    guard let projectID = try extensionNewSessionProject(paramsJson: params) else {
      routes.newSession(nil)
      return
    }
    // The new-session page files into a project by its summary, so resolve the id here.
    guard let project = try await projects().first(where: { $0.id == projectID }) else {
      throw ExtensionHostFault.Failed(code: "InvalidParams", message: "Project not found")
    }
    routes.newSession(project)
  }

  /// The caller's projects: the sidebar's, else a read.
  private func projects() async throws -> [ProjectSummary] {
    let listed = connection.sessionList.projects
    if !listed.isEmpty { return listed }
    guard let core = connection.core else { throw Self.unavailable("Project list") }
    do {
      return try await core.projects()
    } catch {
      throw ExtensionHostFault.Failed(code: "HostError", message: "Project list request failed")
    }
  }

  private func createProject(_ params: String?) async throws -> String {
    let name = try extensionProjectName(paramsJson: params)
    guard let core = connection.core else { throw Self.unavailable("Project creation") }
    let project: ProjectSummary
    do {
      project = try await core.createProject(name: name)
    } catch {
      let detail = String(ConnectionStore.describe(error).prefix(200))
      throw ExtensionHostFault.Failed(
        code: "HostError", message: "Project could not be created: \(detail)")
    }
    // The sidebar lists projects too; read them again so the new one shows there.
    let list = connection.sessionList
    Task { await list.loadProjects() }
    return try extensionProjectResult(project: Self.projectRow(project))
  }

  private static func projectRow(_ project: ProjectSummary) -> ExtensionProjectRow {
    ExtensionProjectRow(id: project.id, name: project.name, icon: project.icon)
  }

  static func unavailable(_ what: String) -> ExtensionHostFault {
    .Failed(code: "Unavailable", message: "\(what) is unavailable")
  }
}

/// Runs calls one at a time, each starting at least `interval` after the one before ended, as
/// the web's limiters space the session list, pull request and storage calls.
@MainActor
final class ExtensionCallSpacing {
  private let interval: Duration
  private var tail: Task<Void, Never>?
  private var lastEnded: ContinuousClock.Instant?

  init(interval: Duration) {
    self.interval = interval
  }

  /// Runs `operation` after the calls before it, spaced by the interval.
  func run<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
    let previous = tail
    let (done, finish) = AsyncStream<Void>.makeStream()
    tail = Task { for await _ in done {} }
    defer {
      lastEnded = .now
      finish.finish()
    }
    await previous?.value
    if let lastEnded {
      let wait = interval - (ContinuousClock.now - lastEnded)
      if wait > .zero { try await Task.sleep(for: wait) }
    }
    try Task.checkCancellation()
    return try await operation()
  }
}

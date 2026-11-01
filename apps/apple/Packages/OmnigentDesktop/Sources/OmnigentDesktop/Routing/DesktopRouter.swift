import AppKit
public import Foundation

/// Opens deep links and notification taps in the right window, one request at a time.
///
/// macOS delivers `omnigent://` URLs to the running instance (LaunchServices keeps one instance
/// per bundle), including at cold start before any window exists. Requests queue until a window
/// attaches its `openWindow` action, then run serially so two links cannot race two consent
/// prompts or two windows onto one server.
public final class DesktopRouter {
  enum Request {
    case link(OmnigentDeepLink)
    case trusted(DeepLinkRoute, serverURL: URL, origin: ServerOrigin)
  }

  /// Servers the user connected to before: the default and recent servers, and typically the
  /// organization's managed servers. Links to these open without a prompt.
  public var knownServers: () -> [URL] = { [] }
  /// Records a server the user just consented to, so the next link opens without a prompt.
  public var rememberServer: (URL) -> Void = { _ in }
  /// Asks before trusting a never-used server with a window. Defaults to `DeepLinkConsentAlert`.
  public var confirmUnknownServer: (ServerOrigin) async -> Bool = { origin in
    DeepLinkConsentAlert.confirm(origin)
  }

  private let registry: ServerWindowRegistry
  private let acknowledger: any DeepLinkAcknowledging
  private let reportIssue: DesktopIssueReporter
  private var openWindow: ((ServerWindowID) -> Void)?
  private var queue: [Request] = []
  private(set) var drainTask: Task<Void, Never>?

  /// Creates a router.
  /// - Parameters:
  ///   - registry: The open windows.
  ///   - acknowledger: Completes the CLI handshake for `desktop_ack` links.
  ///   - reportIssue: Receives rejected links, declined consent and invalid URLs.
  public init(
    registry: ServerWindowRegistry,
    acknowledger: any DeepLinkAcknowledging = LoopbackDeepLinkAcknowledger(),
    reportIssue: @escaping DesktopIssueReporter = StandardErrorIssueReporter.report
  ) {
    self.registry = registry
    self.acknowledger = acknowledger
    self.reportIssue = reportIssue
  }

  /// Gives the router a way to open and focus windows, and runs queued requests. Called by
  /// `View.serverWindow(_:desktop:...)` with the scene's `openWindow(value:)`.
  /// - Parameter openWindow: Opens a window for a value, or brings an equal one to the front.
  public func attachWindowOpener(_ openWindow: @escaping (ServerWindowID) -> Void) {
    self.openWindow = openWindow
    drain()
  }

  /// Handles URLs from `application(_:open:)`. Unsupported URLs are reported and dropped.
  /// - Parameter urls: The opened URLs.
  public func open(_ urls: [URL]) {
    for url in urls {
      do {
        queue.append(.link(try OmnigentDeepLink(parsing: url.absoluteString)))
      } catch {
        reportIssue(.deepLinkRejected(url.absoluteString, error))
      }
    }
    drain()
  }

  /// Opens a route on a server the app already trusts, such as a notification's server.
  /// - Parameters:
  ///   - route: The destination.
  ///   - serverURL: The full server URL including any workspace mount.
  public func open(_ route: DeepLinkRoute, onServer serverURL: URL) {
    do {
      queue.append(.trusted(route, serverURL: serverURL, origin: try ServerOrigin(url: serverURL)))
    } catch {
      reportIssue(.invalidServerURL(serverURL, error))
    }
    drain()
  }

  private func drain() {
    guard drainTask == nil, !queue.isEmpty else { return }
    guard openWindow != nil else {
      reportIssue(.awaitingWindowOpener(pending: queue.count))
      return
    }
    drainTask = Task {
      while !queue.isEmpty {
        await process(queue.removeFirst())
      }
      drainTask = nil
    }
  }

  private func process(_ request: Request) async {
    switch request {
    case .link(let link):
      if let acknowledgment = link.acknowledgment {
        do {
          guard try await acknowledger.acknowledge(acknowledgment) else {
            reportIssue(.acknowledgmentDeclined(link))
            return
          }
        } catch {
          reportIssue(.acknowledgmentFailed(link, error))
          return
        }
      }
      await route(link.route, origin: link.origin, trustedURL: nil)
    case .trusted(let route, let serverURL, let origin):
      await self.route(route, origin: origin, trustedURL: serverURL)
    }
  }

  /// The first recorded URL per known origin, so a known workspace reopens at its mount.
  private func knownServerURLs() -> [ServerOrigin: URL] {
    var known: [ServerOrigin: URL] = [:]
    for url in knownServers() {
      do {
        let knownOrigin = try ServerOrigin(url: url)
        if known[knownOrigin] == nil { known[knownOrigin] = url }
      } catch {
        reportIssue(.invalidServerURL(url, error))
      }
    }
    return known
  }

  private func route(_ route: DeepLinkRoute, origin: ServerOrigin, trustedURL: URL?) async {
    var known = knownServerURLs()
    if let trustedURL { known[origin] = trustedURL }

    let strategy = DeepLinkRouting.strategy(
      target: origin, windows: registry.routingSnapshots, knownOrigins: Set(known.keys),
      focused: registry.keyWindow)
    switch strategy {
    case .navigate(let instance), .navigateWhenReady(let instance):
      guard let entry = registry.entry(instance) else {
        reportIssue(.routingFailed("window \(instance) closed while routing"))
        return
      }
      registry.deliver(route, to: instance)
      openWindow?(entry.id)
    case .openKnownServer:
      guard let serverURL = known[origin] else {
        reportIssue(.routingFailed("no known URL for \(origin)"))
        return
      }
      openNewWindow(serverURL, route: route)
    case .requireConsent:
      guard await confirmUnknownServer(origin) else {
        reportIssue(.consentDeclined(origin))
        return
      }
      guard let serverURL = origin.url else {
        reportIssue(.routingFailed("Foundation rejected \(origin)"))
        return
      }
      rememberServer(serverURL)
      openNewWindow(serverURL, route: route)
    }
  }

  private func openNewWindow(_ serverURL: URL, route: DeepLinkRoute) {
    let id = ServerWindowID.newWindow(serverURL: serverURL)
    registry.deliver(route, to: id.instance)
    openWindow?(id)
  }
}

/// The native confirmation before a link connects to a never-used server. Cancel is the default
/// because a window on a server can show notifications and badges.
public enum DeepLinkConsentAlert {
  /// Shows an app-modal alert.
  /// - Parameter origin: The server the link names.
  /// - Returns: Whether the user chose Open.
  public static func confirm(_ origin: ServerOrigin) -> Bool {
    NSApplication.shared.activate()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Open this Omnigent link?"
    alert.informativeText = """
      This link will connect Omnigent to \(origin.authority).

      Only open links from a server you trust. Once connected, it can show notifications.
      """
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Open")
    return alert.runModal() == .alertSecondButtonReturn
  }
}

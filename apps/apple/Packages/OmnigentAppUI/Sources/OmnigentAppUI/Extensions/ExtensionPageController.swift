import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// What an extension page's host methods do in the app.
@MainActor
protocol ExtensionHostServices: AnyObject {
  /// Runs `method` with `params` (JSON) and answers with its result as JSON; an
  /// ``ExtensionHostFault`` names the code the extension is told, anything else is `HostError`.
  func perform(_ method: String, params: String?) async throws -> String
}

/// The page's end of the channel: the frame's relay, or a stand-in in tests.
@MainActor
protocol ExtensionFramePort: AnyObject {
  /// Hands the page `init` with the channel's other port; whether it took it.
  func start(_ message: String) async -> Bool
  /// Sends the page a message.
  func send(_ message: String)
  /// Closes the channel.
  func close()
}

extension ExtensionFrameChannel: ExtensionFramePort {}

/// Where an extension page's bundle comes from.
struct ExtensionBundleSource {
  /// Reads one of an extension's assets.
  var read: @MainActor (_ extensionID: String, _ url: String) async throws -> ExtensionAsset
  /// Reads the catalog again, after an asset's digest went stale.
  var refresh: @MainActor () async -> [Extension]
}

/// One mount of an extension page, as the web's `ExtensionViewHost` runs it: it reads the bundle
/// (reading the catalog again once when a digest is stale), frames it, opens the channel when the
/// frame loads, waits up to ten seconds for the page to say it is ready, and answers the page's
/// requests with the host methods its permissions grant: at most 32 at once, each within ten
/// seconds, in the order they finish.
@MainActor
@Observable
final class ExtensionPageController {
  /// Where the page stands, for its view.
  private(set) var state: ExtensionPageState
  /// The relay to the page's frame.
  let channel: ExtensionFrameChannel
  @ObservationIgnored private let port: any ExtensionFramePort

  @ObservationIgnored private var extensionItem: Extension
  @ObservationIgnored private let page: ExtensionPage
  @ObservationIgnored private let bundle: ExtensionBundleSource
  @ObservationIgnored private let services: any ExtensionHostServices
  @ObservationIgnored private let timeout: Duration
  @ObservationIgnored private let makeNonce: () -> String
  @ObservationIgnored private var identity: ExtensionIdentity?
  @ObservationIgnored private var granted: Set<String> = []
  @ObservationIgnored private var pending:
    [String: (work: Task<Void, Never>, timer: Task<Void, Never>)] = [:]
  @ObservationIgnored private var loading: Task<Void, Never>?
  @ObservationIgnored private var activation: Task<Void, Never>?
  @ObservationIgnored private var handshakeDone = false
  @ObservationIgnored private var staleRetryDone = false
  @ObservationIgnored private(set) var isDark = false

  /// Creates a mount of `page`.
  /// - Parameters:
  ///   - extensionItem: The page's extension.
  ///   - page: The page.
  ///   - bundle: Where its bundle comes from.
  ///   - services: The host methods.
  ///   - timeout: How long activation and each request may take.
  ///   - makeNonce: A new mount's nonce.
  ///   - port: The page's end of the channel; the frame's relay when `nil`.
  init(
    extensionItem: Extension, page: ExtensionPage, bundle: ExtensionBundleSource,
    services: any ExtensionHostServices, timeout: Duration = .seconds(10),
    makeNonce: @escaping () -> String = ExtensionPageController.randomNonce,
    port: (any ExtensionFramePort)? = nil
  ) {
    let channel = ExtensionFrameChannel()
    self.channel = channel
    self.port = port ?? channel
    self.extensionItem = extensionItem
    self.page = page
    self.bundle = bundle
    self.services = services
    self.timeout = timeout
    self.makeNonce = makeNonce
    state = ExtensionPageState(title: page.title, phase: .loading)
    channel.loaded = { [weak self] in self?.frameLoaded() }
    channel.reloaded = { [weak self] in self?.fail("Extension frame reloaded during activation") }
    channel.stopped = { [weak self] in self?.fail("Extension frame stopped") }
    channel.received = { [weak self] in self?.receive($0) }
  }

  /// 24 random bytes as lowercase hex, as the web's nonce.
  nonisolated static func randomNonce() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<24).map { _ in
      let hex = String(UInt8.random(in: .min ... .max, using: &generator), radix: 16)
      return hex.count == 1 ? "0" + hex : hex
    }.joined()
  }

  /// Whether this mounts `page` of `item`.
  func matches(_ item: Extension, _ page: ExtensionPage) -> Bool {
    item.id == extensionItem.id && page == self.page
  }

  /// Reads the bundle and mounts the page; a mount already running is torn down first.
  func start() {
    closeRuntime()
    handshakeDone = false
    state = ExtensionPageState(title: page.title, phase: .loading)
    loading?.cancel()
    loading = Task { [weak self] in await self?.mount() }
  }

  /// Mounts the page again after a failure, and may read the catalog again.
  func retry() {
    staleRetryDone = false
    start()
  }

  /// Tears the mount down: the page is told to dispose and nothing more is answered.
  func stop() {
    loading?.cancel()
    loading = nil
    closeRuntime()
  }

  /// The appearance changed; a running page hears `theme.changed`.
  func themeChanged(dark: Bool) {
    let changed = dark != isDark
    isDark = dark
    if changed, state.phase == .ready { sendTheme() }
  }

  private func mount() async {
    let source: (script: String, styles: String)
    do {
      source = try await readBundle(extensionItem)
    } catch let failure as BundleFailure {
      if !Task.isCancelled { fail(failure.message) }
      return
    } catch {
      if !Task.isCancelled { fail("Extension bundle failed to load") }
      return
    }
    guard !Task.isCancelled else { return }
    let identity = ExtensionIdentity(
      extensionId: extensionItem.id, pageId: page.id, view: page.view, nonce: makeNonce(),
      apiVersion: 1)
    self.identity = identity
    granted = Set(extensionGrantedMethods(permissions: extensionItem.permissions))
    let document = extensionDocument(
      script: source.script, styles: source.styles, identity: identity)
    state = ExtensionPageState(
      title: page.title, phase: .activating,
      hostPage: extensionHostPage(document: document, title: page.title, nonce: identity.nonce),
      mountID: identity.nonce)
    activation = Task { [weak self, timeout] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      self?.fail("Extension activation timed out")
    }
  }

  private func frameLoaded() {
    guard let identity, state.phase == .activating else { return }
    guard !handshakeDone else {
      fail("Extension frame reloaded during activation")
      return
    }
    handshakeDone = true
    let message = extensionInitMessage(identity: identity, capabilities: granted.sorted())
    Task { [port] in _ = await port.start(message) }
  }

  /// A message from the page.
  func receive(_ text: String) {
    guard let identity, let message = extensionInbound(text: text, identity: identity) else {
      return
    }
    switch message {
    case .ready:
      guard state.phase == .activating else { return }
      activation?.cancel()
      activation = nil
      state.phase = .ready
      sendTheme()
    case .incompatible(let sdkApiVersion):
      let sdk =
        sdkApiVersion.rounded() == sdkApiVersion ? "\(Int(sdkApiVersion))" : "\(sdkApiVersion)"
      fail("Extension SDK API \(sdk) is incompatible with host API \(identity.apiVersion)")
    case .failed(let message):
      fail(message)
    case .cancel(let requestID):
      if let entry = pending.removeValue(forKey: requestID) {
        entry.timer.cancel()
        entry.work.cancel()
      }
    case .request(let requestID, let method, let params):
      handle(requestID, method: method, params: params, identity: identity)
    }
  }

  private func handle(
    _ requestID: String, method: String, params: String?, identity: ExtensionIdentity
  ) {
    let refusal: (code: String, message: String)? =
      if !granted.contains(method) {
        ("MethodNotFound", "Host method is not available")
      } else if pending[requestID] != nil {
        ("DuplicateRequest", "Request ID is already active")
      } else if pending.count >= 32 {
        ("Busy", "Too many extension host requests")
      } else {
        nil
      }
    if let refusal {
      port.send(
        extensionErrorMessage(
          identity: identity, requestId: requestID, code: refusal.code, message: refusal.message))
      return
    }
    let services = services
    let work = Task { [weak self] in
      let outcome: Result<String, ExtensionHostFault>
      do {
        outcome = .success(try await services.perform(method, params: params))
      } catch {
        outcome = .failure(Self.fault(error))
      }
      self?.finish(requestID, method: method, outcome: outcome, identity: identity)
    }
    let timer = Task { [weak self, timeout] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      self?.timedOut(requestID, identity: identity)
    }
    pending[requestID] = (work, timer)
  }

  private func finish(
    _ requestID: String, method: String, outcome: Result<String, ExtensionHostFault>,
    identity: ExtensionIdentity
  ) {
    guard identity == self.identity, let entry = pending.removeValue(forKey: requestID) else {
      return
    }
    entry.timer.cancel()
    switch outcome {
    case .success(let result):
      port.send(
        extensionResponseMessage(
          identity: identity, requestId: requestID, method: method, resultJson: result))
    case .failure(.Failed(let code, let message)):
      port.send(
        extensionErrorMessage(
          identity: identity, requestId: requestID, code: code, message: message))
    }
  }

  /// What the extension is told of a failed call.
  nonisolated static func fault(_ error: any Error) -> ExtensionHostFault {
    switch error {
    case let fault as ExtensionHostFault: fault
    case is CancellationError: .Failed(code: "Cancelled", message: "Host operation cancelled")
    case let core as CoreError: .Failed(code: "HostError", message: core.message)
    default: .Failed(code: "HostError", message: "Host call failed")
    }
  }

  private func timedOut(_ requestID: String, identity: ExtensionIdentity) {
    guard identity == self.identity, let entry = pending.removeValue(forKey: requestID) else {
      return
    }
    entry.work.cancel()
    port.send(
      extensionErrorMessage(
        identity: identity, requestId: requestID, code: "RequestTimeout",
        message: "Host request timed out"))
  }

  private func sendTheme() {
    guard let identity,
      let event = extensionEventMessage(
        identity: identity, event: "theme.changed", valueJson: extensionThemeResult(dark: isDark))
    else { return }
    port.send(event)
  }

  private func fail(_ message: String) {
    closeRuntime()
    state = ExtensionPageState(title: page.title, phase: .failed(String(message.prefix(512))))
  }

  /// Stops every timer and request and tells the page to dispose.
  private func closeRuntime() {
    activation?.cancel()
    activation = nil
    for entry in pending.values {
      entry.timer.cancel()
      entry.work.cancel()
    }
    pending = [:]
    if let identity {
      port.send(extensionDisposeMessage(identity: identity))
      port.close()
    }
    identity = nil
  }
}

// MARK: The bundle

extension ExtensionPageController {
  fileprivate struct BundleFailure: Error {
    let message: String
    let isStale: Bool
  }

  /// The bundle's script and styles; a stale digest reads the catalog again, once.
  fileprivate func readBundle(_ item: Extension) async throws -> (script: String, styles: String) {
    do {
      return try await readAssets(item)
    } catch let failure as BundleFailure where failure.isStale && !staleRetryDone {
      staleRetryDone = true
      guard let refreshed = await bundle.refresh().first(where: { $0.id == item.id }) else {
        throw failure
      }
      extensionItem = refreshed
      return try await readAssets(refreshed)
    }
  }

  private func readAssets(_ item: Extension) async throws -> (script: String, styles: String) {
    guard let assets = item.bundle else {
      throw BundleFailure(message: "Extension bundle is unavailable", isStale: false)
    }
    let script = try await asset(item.id, assets.scriptUrl, kind: "script")
    var styles = ""
    if let styleURL = assets.styleUrl {
      styles = try await asset(item.id, styleURL, kind: "styles")
    }
    return (script, styles)
  }

  private func asset(_ extensionID: String, _ url: String, kind: String) async throws -> String {
    let read: ExtensionAsset
    do {
      read = try await bundle.read(extensionID, url)
    } catch {
      let reason = (error as? CoreError)?.message ?? String(describing: error)
      throw BundleFailure(message: "Extension \(kind) failed to load: \(reason)", isStale: false)
    }
    switch read {
    case .loaded(let text): return text
    case .stale:
      throw BundleFailure(message: "Extension \(kind) failed to load (404)", isStale: true)
    }
  }
}

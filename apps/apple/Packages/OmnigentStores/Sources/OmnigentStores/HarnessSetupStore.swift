import Foundation
public import Observation
public import OmnigentCoreFFI

/// Harness setup on one server: the server's setup steps, the hosts' readiness, installing a
/// harness and writing its credential. Writes are never retried; their failures are kept for
/// the sheet. A successful write replaces the host's readiness with the server's answer.
@Observable
public final class HarnessSetupStore {
  /// The setup features, steps and hosts.
  public private(set) var catalog: CreationLoad<HarnessSetupCatalog> = .idle
  /// `host/harness` keys with an install in flight.
  public private(set) var installing: Set<String> = []
  /// A credential write is in flight.
  public private(set) var isSavingCredential = false
  /// Credentials found on each host, by host id.
  public private(set) var detected: [String: CreationLoad<[DetectedCredential]>] = [:]
  /// The last write's failure.
  public private(set) var error: CoreError?
  /// What the last write did, for the sheet ("Codex is ready on Mac.").
  public private(set) var notice: String?

  private let core: ClientCore

  init(core: ClientCore) {
    self.core = core
  }

  /// Reads the catalog; the hosts' readiness comes with it.
  public func load() async {
    if catalog.value == nil { catalog = .loading }
    do {
      catalog = .loaded(try await core.harnessSetupCatalog())
    } catch {
      catalog = .failed(coreError(error))
    }
  }

  /// The setup sheet for `harness` on `hostID`, once the catalog loaded.
  /// - Parameters:
  ///   - harness: The harness id.
  ///   - hostID: The host.
  /// - Returns: The plan, or `nil` before the catalog loads.
  public func plan(harness: String, hostID: String) -> HarnessSetupPlan? {
    catalog.value.map { harnessSetupPlan(catalog: $0, harness: harness, hostId: hostID) }
  }

  /// The Settings harness list for `hostID`.
  /// - Parameter hostID: The host.
  /// - Returns: Every harness, or none before the catalog loads.
  public func inventory(hostID: String) -> [HarnessInventoryRow] {
    catalog.value.map { harnessInventory(catalog: $0, hostId: hostID) } ?? []
  }

  /// Whether `harness` is installing on `hostID`.
  public func isInstalling(harness: String, hostID: String) -> Bool {
    installing.contains(Self.key(hostID, harness))
  }

  /// Installs `harness` on `hostID`, then applies the host's refreshed readiness.
  /// - Parameters:
  ///   - harness: The harness id.
  ///   - label: Its name, for the notice.
  ///   - hostID: The host.
  public func install(harness: String, label: String, hostID: String) async {
    let key = Self.key(hostID, harness)
    guard !installing.contains(key) else { return }
    installing.insert(key)
    error = nil
    notice = nil
    defer { installing.remove(key) }
    do {
      let readiness = try await core.installHarness(hostId: hostID, harness: harness)
      apply(readiness, hostID: hostID)
      notice =
        isReady(harness, in: readiness)
        ? "\(label) is ready on \(hostName(hostID))."
        : "\(label) is installed on \(hostName(hostID)). One more step to finish setup."
    } catch {
      self.error = coreError(error)
    }
  }

  /// Writes a credential for `harness` on `hostID`, then applies the refreshed readiness.
  /// - Parameters:
  ///   - input: The key, gateway or detected credential.
  ///   - harness: The harness id.
  ///   - label: Its name, for the notice.
  ///   - hostID: The host.
  /// - Returns: Whether the harness is ready now (a saved credential can leave it not ready).
  @discardableResult
  public func storeCredential(
    _ input: HarnessCredentialInput, harness: String, label: String, hostID: String
  ) async -> Bool {
    guard !isSavingCredential else { return false }
    isSavingCredential = true
    error = nil
    notice = nil
    defer { isSavingCredential = false }
    do {
      let readiness = try await core.storeHarnessCredential(
        hostId: hostID, harness: harness, input: input)
      apply(readiness, hostID: hostID)
      detected[hostID] = nil
      let ready = isReady(harness, in: readiness)
      notice =
        ready
        ? "\(label) is ready on \(hostName(hostID))."
        : "Saved, but \(label) still needs setup on \(hostName(hostID)). Try another option."
      return ready
    } catch {
      self.error = coreError(error)
      return false
    }
  }

  /// Reads the credentials already on `hostID`, once per host until a credential is saved.
  /// - Parameter hostID: The host.
  public func loadDetected(hostID: String) async {
    if detected[hostID] != nil { return }
    detected[hostID] = .loading
    do {
      detected[hostID] = .loaded(try await core.detectedCredentials(hostId: hostID))
    } catch {
      detected[hostID] = .failed(coreError(error))
    }
  }

  /// Clears the last write's failure and notice (the sheet closed).
  public func dismissMessages() {
    error = nil
    notice = nil
  }

  private func apply(_ readiness: [HarnessAvailabilityEntry], hostID: String) {
    guard let current = catalog.value else { return }
    catalog = .loaded(
      harnessSetupCatalogApplying(catalog: current, hostId: hostID, harnesses: readiness))
  }

  private func isReady(_ harness: String, in readiness: [HarnessAvailabilityEntry]) -> Bool {
    readiness.first { $0.harness == harness }?.availability == .ready
  }

  private func hostName(_ hostID: String) -> String {
    catalog.value?.hosts.first { $0.hostId == hostID }?.name ?? "the host"
  }

  private static func key(_ hostID: String, _ harness: String) -> String {
    "\(hostID)/\(harness)"
  }
}

extension ConnectionStore {
  /// Harness setup for this server: a new store each time a setup sheet or Settings opens.
  /// - Returns: The store, or `nil` without a core.
  public func harnessSetup() -> HarnessSetupStore? {
    core.map { HarnessSetupStore(core: $0) }
  }
}

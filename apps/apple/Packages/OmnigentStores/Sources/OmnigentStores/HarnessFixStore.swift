import Foundation
public import Observation
public import OmnigentCoreFFI
import os

/// Where fixing a harness stands, as the web's `HarnessFixDialog` phases.
public enum HarnessFixPhase: Equatable, Sendable {
  /// Nothing running.
  case idle
  /// Asking before signing the host out of `account` to switch accounts.
  case confirmSwitch(account: String?)
  /// Signing out, updating or starting a sign-in.
  case working(String)
  /// Waiting for the user to enter `login`'s code at its link.
  case deviceCode(HarnessLoginStart)
  /// Another sign-in is in progress on the host; waiting for it.
  case waitingForOtherSignIn
  /// Run `command` on the host, then Check Again. `stillNotReady` after a check that failed.
  case runCommand(String, stillNotReady: Bool)
  /// Updated, but the harness still needs sign-in: continue with the setup sheet.
  case needsSetup(String)
  /// Failed; nothing changed on the host.
  case failed(String)
  /// Done, with what changed.
  case done(String)
}

/// Fixes one harness on one host beyond first setup: switching accounts, Codex's device
/// sign-in, updating an outdated harness and checking again after a command run on the host.
/// Each successful step applies the host's reported readiness to the ``HarnessSetupStore``.
/// Writes are never retried; a closed sheet cancels a pending sign-in.
@Observable
public final class HarnessFixStore {
  /// The flow's phase.
  public private(set) var phase: HarnessFixPhase = .idle
  /// A Check Again is in flight.
  public private(set) var isChecking = false
  /// The harness's startup command on each `host/harness`.
  public private(set) var startup: [String: CreationLoad<HarnessStartupRead>] = [:]

  @ObservationIgnored private let core: ClientCore
  @ObservationIgnored private let setup: HarnessSetupStore
  @ObservationIgnored private let pollInterval: Duration
  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var activeLogin: PendingLogin?
  @ObservationIgnored private var run = 0

  init(core: ClientCore, setup: HarnessSetupStore, pollInterval: Duration = .seconds(2)) {
    self.core = core
    self.setup = setup
    self.pollInterval = pollInterval
  }

  /// Starts fixing `harness` on `hostID` in `mode`. Switching asks first; Update installs the
  /// latest version; Reconfigure runs Codex's device sign-in when the host supports it.
  /// - Parameters:
  ///   - mode: What to do.
  ///   - detail: The harness's details on the host.
  ///   - hostID: The host.
  public func begin(_ mode: HarnessFixMode, detail: HarnessDetail, hostID: String) async {
    cancel()
    switch mode {
    case .switch:
      phase = .confirmSwitch(account: detail.account?.identity)
    case .update, .install:
      await install(detail: detail, hostID: hostID, updating: mode == .update)
    case .reconfigure:
      if detail.supportsDeviceLogin {
        await startDeviceLogin(detail: detail, hostID: hostID)
      } else if let command = detail.personalLoginCommand {
        phase = .runCommand(command, stillNotReady: false)
      } else {
        phase = .needsSetup("Set up \(detail.name) on \(detail.hostName).")
      }
    }
  }

  /// Signs the host out, then signs in again: Codex with a device code, others with a command
  /// to run on the host. `email` picks Claude's account.
  public func confirmSwitch(detail: HarnessDetail, hostID: String, email: String?) async {
    let id = nextRun()
    phase = .working("Signing out of \(detail.name) on \(detail.hostName)\u{2026}")
    do {
      let snapshot = try await core.signOutHarness(hostId: hostID, harness: detail.harness)
      guard id == run else { return }
      setup.apply(snapshot, hostID: hostID)
      if detail.supportsDeviceLogin {
        await startDeviceLogin(detail: detail, hostID: hostID)
      } else if let catalog = setup.catalog.value,
        let command = harnessPersonalLoginCommand(
          catalog: catalog, harness: detail.harness, email: email)
      {
        phase = .runCommand(command, stillNotReady: false)
      } else {
        phase = .needsSetup("Sign in to \(detail.name) on \(detail.hostName).")
      }
    } catch {
      fail(error, run: id)
    }
  }

  /// Starts Codex's device sign-in and polls it until it finishes.
  public func startDeviceLogin(detail: HarnessDetail, hostID: String) async {
    let id = nextRun()
    phase = .working("Starting sign-in on \(detail.hostName)\u{2026}")
    do {
      let outcome = try await core.startHarnessLogin(hostId: hostID, harness: detail.harness)
      let loginID: String
      switch outcome {
      case .started(let login):
        loginID = login.loginId
        if id == run { phase = .deviceCode(login) }
      case .busy(let busyID):
        loginID = busyID
        if id == run { phase = .waitingForOtherSignIn }
      }
      guard id == run else {
        await cancelLogin(hostID: hostID, harness: detail.harness, loginID: loginID)
        return
      }
      activeLogin = PendingLogin(hostID: hostID, harness: detail.harness, id: loginID)
      poll = Task { [weak self] in
        await self?.pollLogin(loginID, detail: detail, hostID: hostID, run: id)
      }
    } catch {
      fail(error, run: id)
    }
  }

  /// Asks the host to check the harness again after a command run there.
  public func checkAgain(detail: HarnessDetail, hostID: String) async {
    guard !isChecking else { return }
    let id = run
    isChecking = true
    defer { isChecking = false }
    do {
      let snapshot = try await core.refreshHarnesses(hostId: hostID)
      guard id == run else { return }
      setup.apply(snapshot, hostID: hostID)
      if harnessSnapshotIsReady(snapshot: snapshot, harness: detail.harness) {
        phase = .done("\(detail.name) is ready on \(detail.hostName).")
      } else if case .runCommand(let command, _) = phase {
        phase = .runCommand(command, stillNotReady: true)
      }
    } catch {
      fail(error, run: id)
    }
  }

  /// Reads `harness`'s startup command on `hostID` once.
  public func loadStartup(harness: String, hostID: String, hostName: String) async {
    let key = "\(hostID)/\(harness)"
    if startup[key] != nil { return }
    startup[key] = .loading
    do {
      startup[key] = .loaded(
        try await core.harnessStartup(hostId: hostID, harness: harness, hostName: hostName))
    } catch {
      startup[key] = .failed(coreError(error))
    }
  }

  /// Stops the flow: stops polling and cancels a pending sign-in on the host.
  public func cancel() {
    run += 1
    poll?.cancel()
    poll = nil
    if let login = activeLogin {
      activeLogin = nil
      Task { await cancelLogin(hostID: login.hostID, harness: login.harness, loginID: login.id) }
    }
    if phase != .idle { phase = .idle }
  }

  private func install(detail: HarnessDetail, hostID: String, updating: Bool) async {
    let id = nextRun()
    phase = .working(
      updating
        ? "Updating \(detail.name) to the latest version on \(detail.hostName)\u{2026}"
        : "Installing \(detail.name) on \(detail.hostName)\u{2026}")
    do {
      let outcome = try await core.installHarnessReporting(hostId: hostID, harness: detail.harness)
      guard id == run else { return }
      setup.apply(outcome.snapshot, hostID: hostID)
      if harnessSnapshotIsReady(snapshot: outcome.snapshot, harness: detail.harness) {
        let version = outcome.version.map { " \($0)" } ?? ""
        phase = .done("\(detail.name)\(version) is ready on \(detail.hostName).")
      } else {
        phase = .needsSetup(
          "\(detail.name) was \(updating ? "updated" : "installed") but still needs to be set up on \(detail.hostName)."
        )
      }
    } catch {
      fail(error, run: id)
    }
  }

  private func pollLogin(_ loginID: String, detail: HarnessDetail, hostID: String, run id: Int)
    async
  {
    while !Task.isCancelled, id == run {
      do {
        try await Task.sleep(for: pollInterval)
        let status = try await core.harnessLoginStatus(
          hostId: hostID, harness: detail.harness, loginId: loginID)
        guard id == run else { return }
        switch status.state {
        case .pending:
          continue
        case .succeeded:
          activeLogin = nil
          await finishLogin(status.snapshot, detail: detail, hostID: hostID, run: id)
        case .failed, .cancelled, .expired:
          activeLogin = nil
          phase = .failed(status.error ?? "The sign-in did not complete.")
        }
        return
      } catch is CancellationError {
        return
      } catch {
        activeLogin = nil
        fail(error, run: id)
        return
      }
    }
  }

  private func finishLogin(
    _ reported: HarnessHostSnapshot, detail: HarnessDetail, hostID: String, run id: Int
  ) async {
    var snapshot = reported
    if snapshot.harnesses == nil {
      do {
        snapshot = try await core.refreshHarnesses(hostId: hostID)
      } catch {
        fail(error, run: id)
        return
      }
    }
    guard id == run else { return }
    setup.apply(snapshot, hostID: hostID)
    let identity = setup.detail(harness: detail.harness, name: detail.name, hostID: hostID)?
      .account?.identity
    phase = .done(
      "\(detail.name) is ready on \(detail.hostName)."
        + (identity.map { " Signed in as \($0)." } ?? ""))
  }

  private func cancelLogin(hostID: String, harness: String, loginID: String) async {
    do {
      try await core.cancelHarnessLogin(hostId: hostID, harness: harness, loginId: loginID)
    } catch {
      // The sign-in may already have finished on the host; nothing is waiting on it.
      Self.logger.error("Cancelling sign-in \(loginID) failed: \(coreError(error).message)")
    }
  }

  private func nextRun() -> Int {
    poll?.cancel()
    poll = nil
    run += 1
    return run
  }

  private func fail(_ error: any Error, run id: Int) {
    guard id == run else { return }
    phase = .failed(coreError(error).message)
  }

  private static let logger = Logger(subsystem: "ai.omnigent", category: "harness-fix")
}

/// A device sign-in the host is running for the flow, cancelled when the flow stops.
private struct PendingLogin {
  let hostID: String
  let harness: String
  let id: String
}

extension ConnectionStore {
  /// Fixes for harnesses beyond setup, over `setup`'s catalog.
  /// - Parameter setup: The harness setup store the fixes update.
  /// - Returns: The store, or `nil` without a core.
  public func harnessFix(setup: HarnessSetupStore) -> HarnessFixStore? {
    core.map { HarnessFixStore(core: $0, setup: setup) }
  }
}

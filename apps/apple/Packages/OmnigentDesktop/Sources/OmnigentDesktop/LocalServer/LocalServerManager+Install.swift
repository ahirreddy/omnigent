import Foundation

/// Installing the `omnigent` CLI from onboarding.
nonisolated public enum LocalCLIInstallState: Equatable, Sendable {
  /// Not installing.
  case idle
  /// The installer is running.
  case installing
  /// The installer failed, with why.
  case failed(String)
}

/// Installs the CLI the way the Electron shell's `cli_install.js` does: makes sure `uv` is
/// installed (the installer's non-interactive mode will not), then runs the published installer
/// (`scripts/install_oss.sh --non-interactive`), which runs `uv tool install omnigent` and wires
/// up `PATH`. Output goes to the server log, which the setup screens show.
extension LocalServerManager {
  /// The published installer, the one the install guide gives.
  static let installScriptURL =
    "https://raw.githubusercontent.com/omnigent-ai/omnigent/main/scripts/install_oss.sh"
  /// uv's official installer, the one `install_oss.sh` offers interactively.
  static let uvInstallCommand = "curl -LsSf https://astral.sh/uv/install.sh | sh"
  /// Installing pulls uv, a Python toolchain and the package.
  static let installTimeout: Duration = .seconds(600)

  /// Installs the CLI, then looks for it again. A failure stays in ``cliInstall``.
  public func installCLI() async {
    guard capability.isAvailable, cliInstall != .installing else { return }
    cliInstall = .installing
    let environment = await installEnvironment()
    if !hasUV(environment) {
      serverLog.appendEvent("Installing uv, which the Omnigent installer requires\u{2026}")
      guard await runInstallStep(Self.uvInstallCommand, environment: environment),
        hasUV(environment)
      else {
        failInstall(
          "Couldn\u{2019}t install uv, which the Omnigent installer requires. Install it from "
            + "https://docs.astral.sh/uv/getting-started/installation/ and try again.")
        return
      }
    }
    serverLog.appendEvent("Installing the Omnigent CLI\u{2026}")
    let script = "curl -fsSL \(Self.installScriptURL) | sh -s -- --non-interactive"
    guard await runInstallStep(script, environment: environment) else {
      failInstall("The installer did not finish. Its output is in the server log.")
      return
    }
    cliInstall = .idle
    await refreshCLI()
  }

  /// The app's environment with the login shell's `PATH` and the directories uv installs to,
  /// so a just-installed uv is found by the next step.
  private func installEnvironment() async -> [String: String] {
    var environment = dependencies.environment
    var directories: [String] = []
    do {
      let path = try await dependencies.cliSystem.loginShellPath()
      directories = path.split(separator: ":").map(String.init)
    } catch {
      serverLog.appendEvent("Could not read your login shell's PATH: \(error.message)")
      directories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }
    let known = LocalCLIDiscovery(
      configuredPath: nil, developmentCheckout: nil, system: dependencies.cliSystem
    ).knownDirectories
    for directory in known.reversed() where !directories.contains(directory) {
      directories.insert(directory, at: 0)
    }
    environment["PATH"] = directories.joined(separator: ":")
    environment["HOME"] = environment["HOME"] ?? dependencies.homeDirectory.path
    environment["NO_COLOR"] = "1"
    return environment
  }

  private func hasUV(_ environment: [String: String]) -> Bool {
    (environment["PATH"] ?? "").split(separator: ":").contains {
      dependencies.cliSystem.isExecutableFile("\($0)/uv")
    }
  }

  /// Runs `command` with `/bin/sh -c`, logging its output; whether it exited cleanly.
  private func runInstallStep(_ command: String, environment: [String: String]) async -> Bool {
    let launch = LocalProcessLaunch(
      executable: URL(filePath: "/bin/sh"), arguments: ["-c", command],
      environment: environment, workingDirectory: dependencies.homeDirectory)
    serverLog.appendEvent("$ \(command)")
    do {
      let result = try await LocalCommand.run(
        launch, runner: dependencies.runner, clock: dependencies.clock,
        timeout: Self.installTimeout)
      for line in result.combinedOutput.split(whereSeparator: \.isNewline) {
        serverLog.appendEvent(String(line))
      }
      if !result.exit.isSuccess { serverLog.appendEvent("The installer \(result.exit.summary).") }
      return result.exit.isSuccess
    } catch {
      serverLog.appendEvent(error.message)
      return false
    }
  }

  private func failInstall(_ message: String) {
    cliInstall = .failed(message)
    serverLog.appendEvent(message)
  }
}

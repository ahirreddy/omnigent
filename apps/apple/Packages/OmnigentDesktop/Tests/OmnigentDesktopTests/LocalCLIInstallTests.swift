import Foundation
import Testing

@testable import OmnigentDesktop

/// Ports web/electron/src/cli_install.test.js: uv first, then the published installer.
@MainActor
@Suite("Installing the CLI")
struct LocalCLIInstallTests {
  @Test("with uv installed, runs the installer non-interactively and finds the CLI")
  func installs() async throws {
    let harness = try LocalServerHarness(executables: [LocalServerHarness.cliPath, "/fake/bin/uv"])
    defer { harness.cleanUp() }
    harness.runner.script({ process in
      process.print("installed omnigent")
      process.exit(.exited(0))
    })
    await harness.manager.installCLI()
    let launch = try #require(harness.runner.launches.first)
    #expect(harness.runner.launches.count == 1)
    #expect(launch.executable.path == "/bin/sh")
    #expect(
      launch.arguments == [
        "-c", "curl -fsSL \(LocalServerManager.installScriptURL) | sh -s -- --non-interactive",
      ])
    let path = launch.environment["PATH"] ?? ""
    #expect(path.hasPrefix("\(harness.root.path)/.local/bin:"), "uv's directories come first")
    #expect(harness.manager.cliInstall == .idle)
    #expect(harness.manager.cli.resolution != nil)
    #expect(harness.manager.serverLog.lines.contains { $0.text == "installed omnigent" })
  }

  @Test("installs uv first, and stops when uv is still missing")
  func uvMissing() async throws {
    let harness = try LocalServerHarness()
    defer { harness.cleanUp() }
    harness.runner.script({ process in process.exit(.exited(0)) })
    await harness.manager.installCLI()
    #expect(
      harness.runner.launches.map(\.arguments) == [["-c", LocalServerManager.uvInstallCommand]])
    guard case .failed(let message) = harness.manager.cliInstall else {
      Issue.record("expected a failure, got \(harness.manager.cliInstall)")
      return
    }
    #expect(message.contains("uv"))
  }

  @Test("a failed installer is reported")
  func installerFails() async throws {
    let harness = try LocalServerHarness(executables: [LocalServerHarness.cliPath, "/fake/bin/uv"])
    defer { harness.cleanUp() }
    harness.runner.script({ process in
      process.print("error: no network", stream: .standardError)
      process.exit(.exited(1))
    })
    await harness.manager.installCLI()
    #expect(harness.manager.cliInstall != .idle)
    #expect(harness.manager.serverLog.lines.contains { $0.text == "error: no network" })
  }
}

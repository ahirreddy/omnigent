public import Foundation

/// How to invoke the `omnigent` CLI: an executable plus any fixed leading arguments, so both
/// `/Users/me/.local/bin/omnigent` and `uv run --project <repo> omnigent` work.
nonisolated public struct LocalCLICommand: Equatable, Sendable {
  /// Where the command was found.
  public enum Source: Equatable, Sendable {
    /// The path set in Settings.
    case configured
    /// A directory on the user's login-shell `PATH`.
    case loginShellPath
    /// A well-known install directory (`uv tool`, pipx, Homebrew, Cargo).
    case knownLocation
    /// The `.venv` of the source checkout a development build came from.
    case developmentCheckout
    /// Constructed by the caller, for example `uv run` in tests.
    case explicit
  }

  /// The executable.
  public var executable: URL
  /// Arguments placed before the subcommand.
  public var prefixArguments: [String]
  /// Where it came from.
  public var source: Source

  /// Creates a command.
  /// - Parameters:
  ///   - executable: The executable.
  ///   - prefixArguments: Arguments placed before the subcommand.
  ///   - source: Where it came from.
  public init(executable: URL, prefixArguments: [String] = [], source: Source) {
    self.executable = executable
    self.prefixArguments = prefixArguments
    self.source = source
  }

  /// The full argument list for a subcommand.
  /// - Parameter subcommand: For example `["server", "--no-open"]`.
  /// - Returns: `prefixArguments + subcommand`.
  public func arguments(_ subcommand: [String]) -> [String] {
    prefixArguments + subcommand
  }

  /// The command as typed in a terminal, for Settings.
  public var displayString: String {
    ([executable.path] + prefixArguments).joined(separator: " ")
  }
}

/// A discovered CLI and the `PATH` its children should get.
nonisolated public struct LocalCLIResolution: Equatable, Sendable {
  /// The command.
  public var command: LocalCLICommand
  /// The user's login-shell `PATH`, or `nil` when it could not be read.
  public var loginShellPath: String?
  /// Problems that did not stop discovery, such as an unreadable shell profile.
  public var warnings: [String]

  /// Creates a resolution.
  /// - Parameters:
  ///   - command: The command.
  ///   - loginShellPath: The login-shell `PATH`.
  ///   - warnings: Non-fatal problems.
  public init(command: LocalCLICommand, loginShellPath: String?, warnings: [String] = []) {
    self.command = command
    self.loginShellPath = loginShellPath
    self.warnings = warnings
  }
}

/// Finds the `omnigent` CLI the way a terminal would, for a GUI app that inherits launchd's
/// minimal `PATH`.
///
/// Order: the path set in Settings (an invalid one is an error, never silently replaced), then
/// each directory on the user's login-shell `PATH`, then well-known install directories, then the
/// development checkout's `.venv`. Each directory is tried for `omnigent`, then its `omni` alias.
nonisolated public struct LocalCLIDiscovery: Sendable {
  /// What `discover()` reads from the system, injected for tests.
  public struct System: Sendable {
    /// The user's home directory.
    public var homeDirectory: URL
    /// Whether a path is an executable regular file.
    public var isExecutableFile: @Sendable (String) -> Bool
    /// The login shell's `PATH`.
    public var loginShellPath: @Sendable () async throws(LocalServerError) -> String

    /// Creates a system description.
    /// - Parameters:
    ///   - homeDirectory: Home.
    ///   - isExecutableFile: Executable check.
    ///   - loginShellPath: Reads the login shell's `PATH`.
    public init(
      homeDirectory: URL, isExecutableFile: @escaping @Sendable (String) -> Bool,
      loginShellPath: @escaping @Sendable () async throws(LocalServerError) -> String
    ) {
      self.homeDirectory = homeDirectory
      self.isExecutableFile = isExecutableFile
      self.loginShellPath = loginShellPath
    }

    /// The real file system and `$SHELL -l -i`.
    /// - Parameters:
    ///   - runner: Runs the shell.
    ///   - clock: Times it out.
    /// - Returns: The live system.
    public static func live(
      runner: any LocalProcessRunning = PosixSpawnProcessRunner(),
      clock: any LocalServerClock = SystemLocalServerClock()
    ) -> Self {
      Self(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        isExecutableFile: { path in
          var isDirectory: ObjCBool = false
          return unsafe FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        },
        loginShellPath: { () throws(LocalServerError) in
          try await LoginShell.path(runner: runner, clock: clock)
        })
    }
  }

  /// The names the CLI installs, canonical first.
  public static let executableNames = ["omnigent", "omni"]

  /// Shown when nothing is found.
  public static let installGuidance =
    "Install it with `uv tool install omnigent` (or `brew install omnigent-ai/tap/omnigent`), "
    + "then choose Refresh, or set its path in Settings > Local Server."

  /// The path set in Settings, if any.
  public var configuredPath: String?
  /// The source checkout of a development build, whose `.venv/bin` is tried last.
  public var developmentCheckout: URL?
  /// The system.
  public var system: System

  /// Creates a discovery.
  /// - Parameters:
  ///   - configuredPath: The path set in Settings.
  ///   - developmentCheckout: A development build's source checkout.
  ///   - system: The system.
  public init(configuredPath: String?, developmentCheckout: URL?, system: System) {
    self.configuredPath = configuredPath
    self.developmentCheckout = developmentCheckout
    self.system = system
  }

  /// Well-known install directories: `uv tool` and pipx (`~/.local/bin`), Homebrew, then Cargo.
  public var knownDirectories: [String] {
    let home = system.homeDirectory.path
    return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin"]
  }

  /// Finds the CLI.
  /// - Returns: The command, the login-shell `PATH` and any warnings.
  /// - Throws: `.configuredCLIInvalid` or `.cliNotFound`.
  public func discover() async throws(LocalServerError) -> LocalCLIResolution {
    var warnings: [String] = []
    var loginPath: String?
    do {
      loginPath = try await system.loginShellPath()
    } catch {
      warnings.append("Could not read your login shell's PATH: \(error.message)")
    }
    if let configuredPath, !configuredPath.isEmpty {
      guard system.isExecutableFile(configuredPath) else {
        throw .configuredCLIInvalid(path: configuredPath)
      }
      return LocalCLIResolution(
        command: LocalCLICommand(executable: URL(filePath: configuredPath), source: .configured),
        loginShellPath: loginPath, warnings: warnings)
    }
    var searched: [String] = []
    let shellDirectories = (loginPath ?? "").split(separator: ":").map(String.init)
    let groups: [(LocalCLICommand.Source, [String])] = [
      (.loginShellPath, shellDirectories),
      (.knownLocation, knownDirectories.filter { !shellDirectories.contains($0) }),
      (
        .developmentCheckout,
        developmentCheckout.map { [$0.appending(path: ".venv/bin").path] } ?? []
      ),
    ]
    for (source, directories) in groups {
      for directory in directories where !directory.isEmpty {
        for name in Self.executableNames {
          let candidate = URL(filePath: directory, directoryHint: .isDirectory)
            .appending(path: name).path
          searched.append(candidate)
          if system.isExecutableFile(candidate) {
            return LocalCLIResolution(
              command: LocalCLICommand(executable: URL(filePath: candidate), source: source),
              loginShellPath: loginPath, warnings: warnings)
          }
        }
      }
    }
    throw .cliNotFound(searched: searched)
  }
}

/// Reads the user's login-shell `PATH` by running `$SHELL -l -i -c`, as a terminal would.
nonisolated enum LoginShell {
  static let marker = "__OMNIGENT_LOGIN_PATH__"

  static func path(runner: any LocalProcessRunning, clock: any LocalServerClock)
    async throws(LocalServerError) -> String
  {
    let environment = ProcessInfo.processInfo.environment
    let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    let home = FileManager.default.homeDirectoryForCurrentUser
    var childEnvironment = [
      "HOME": home.path, "SHELL": shell, "TERM": "dumb",
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    for key in ["USER", "LOGNAME", "LANG", "TMPDIR"] { childEnvironment[key] = environment[key] }
    let launch = LocalProcessLaunch(
      executable: URL(filePath: shell),
      arguments: ["-l", "-i", "-c", "printf '\\n%s%s%s\\n' \(marker) \"$PATH\" \(marker)"],
      environment: childEnvironment, workingDirectory: home)
    let result = try await LocalCommand.run(
      launch, runner: runner, clock: clock, timeout: .seconds(10))
    guard let path = parse(result.standardOutput) else {
      throw .commandFailed(
        command: launch.commandLine, exit: result.exit,
        output: "no PATH in its output. \(result.combinedOutput.suffix(300))")
    }
    return path
  }

  /// Extracts the `PATH` printed between markers, ignoring whatever the profile printed.
  static func parse(_ output: String) -> String? {
    guard let start = output.range(of: marker),
      let end = output.range(of: marker, range: start.upperBound..<output.endIndex)
    else { return nil }
    let path = String(output[start.upperBound..<end.lowerBound])
    return path.isEmpty ? nil : path
  }
}

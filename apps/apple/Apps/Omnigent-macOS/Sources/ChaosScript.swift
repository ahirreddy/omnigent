#if DEBUG
  import AppKit
  import OmnigentDesktop
  import OmnigentUIComponents

  /// Debug builds launched with `-OmnigentChaosScript <path>` run a fixed list of steps with the
  /// chaos driver's input and diagnostics, to replay a sequence a random walk found.
  ///
  /// One step per line; blank lines and lines starting with `#` are skipped:
  /// `session ID`, `resize WIDTH HEIGHT`, `click IDENTIFIER`, `doubleclick IDENTIFIER`,
  /// `shortcut NAME`, `twice NAME` (the shortcut pressed twice with no pause), `type TEXT` (with
  /// `\r` for Return), `wait SECONDS`,
  /// where an identifier is a control's accessibility identifier and a name is one in
  /// ``ChaosMenu/shortcuts``.
  @MainActor
  final class ChaosScript {
    enum Step: Equatable {
      case session(String)
      case resize(width: CGFloat, height: CGFloat)
      case click(String, count: Int)
      case wait(TimeInterval)
      case shortcut(String, count: Int)
      case type(String)
    }

    struct Malformed: Error, Equatable {
      let line: String
    }

    private static var shared: ChaosScript?
    /// The pause after each step, so layout settles as it does between a person's actions.
    private static let pause: Duration = .milliseconds(300)

    private let steps: [Step]
    private let log: ChaosLogFile?
    private let router: DesktopRouter
    private let serverURL: () -> URL?

    private init(
      steps: [Step], log: ChaosLogFile?, router: DesktopRouter, serverURL: @escaping () -> URL?
    ) {
      self.steps = steps
      self.log = log
      self.router = router
      self.serverURL = serverURL
    }

    nonisolated static func parse(_ text: String) throws(Malformed) -> [Step] {
      var steps: [Step] = []
      for line in text.split(whereSeparator: \.isNewline) {
        let words = line.split(separator: " ").map(String.init)
        guard let command = words.first, !command.hasPrefix("#") else { continue }
        guard let step = step(command, Array(words.dropFirst())) else {
          throw Malformed(line: String(line))
        }
        steps.append(step)
      }
      return steps
    }

    nonisolated private static func step(_ command: String, _ arguments: [String]) -> Step? {
      switch (command, arguments.count) {
      case ("session", 1): .session(arguments[0])
      case ("click", 1): .click(arguments[0], count: 1)
      case ("doubleclick", 1): .click(arguments[0], count: 2)
      case ("shortcut", 1...): .shortcut(arguments.joined(separator: " "), count: 1)
      case ("twice", 1...): .shortcut(arguments.joined(separator: " "), count: 2)
      case ("wait", 1): TimeInterval(arguments[0]).map(Step.wait)
      case ("type", 1...):
        .type(arguments.joined(separator: " ").replacingOccurrences(of: "\\r", with: "\r"))
      case ("resize", 2):
        Double(arguments[0]).flatMap { width in
          Double(arguments[1]).map { .resize(width: width, height: $0) }
        }
      default: nil
      }
    }

    /// Starts the script when the launch names one.
    /// - Returns: Whether it names one, so no random walk starts as well.
    static func startIfRequested(router: DesktopRouter, serverURL: @escaping () -> URL?) -> Bool {
      let defaults = UserDefaults.standard
      guard shared == nil, let path = defaults.string(forKey: "OmnigentChaosScript") else {
        return false
      }
      let log = defaults.string(forKey: "OmnigentChaosLog").flatMap(ChaosLogFile.init)
      let steps: [Step]
      do {
        steps = try parse(try String(contentsOfFile: path, encoding: .utf8))
      } catch {
        log?.write("SCRIPT \(path) cannot run: \(error)")
        exit(2)
      }
      let script = ChaosScript(steps: steps, log: log, router: router, serverURL: serverURL)
      shared = script
      ChaosLog.startDiagnostics()
      LoopProbe.sink = { [log] line in log?.write("\(line)\n  \(ChaosWindows.frames())") }
      Task { await script.run() }
      return true
    }

    private func run() async {
      NSApp.activate()
      do {
        // The first window takes a moment, as it does for a random walk.
        while visibleWindow == nil {
          try await Task.sleep(for: .milliseconds(500))
        }
        try await Task.sleep(for: .seconds(2))
        for (number, step) in steps.enumerated() {
          log?.write("\(number + 1) \(step)")
          try await perform(step)
          try await Task.sleep(for: Self.pause)
        }
      } catch {
        log?.write("SCRIPT stopped: \(error)")
        exit(2)
      }
      log?.write("DONE steps=\(steps.count) windows=\(NSApp.windows.count)")
      exit(0)
    }

    private func perform(_ step: Step) async throws {
      switch step {
      case .wait(let seconds):
        try await Task.sleep(for: .seconds(seconds))
      case .session(let id):
        guard let server = serverURL() else {
          log?.write("session: no server")
          return
        }
        router.open(.conversation(sessionID: id), onServer: server)
      case .resize, .click, .shortcut, .type:
        guard let window = visibleWindow else {
          log?.write("\(step): no window")
          return
        }
        // Keys only reach a key window, and a launch in the background may have none.
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        act(step, in: window)
        log?.write(
          "\(step), focus \(ChaosLog.focus(in: window)), in \(ChaosLog.describe(window)),"
            + " key \(window.isKeyWindow)")
      }
    }

    private func act(_ step: Step, in window: NSWindow) {
      switch step {
      case .resize(let width, let height):
        var frame = window.frame
        frame.size = CGSize(width: width, height: height)
        window.setFrame(frame, display: true)
      case .click(let identifier, let count):
        let controls = ChaosTargets.controls(in: window)
        guard let control = controls.first(where: { Self.names($0, identifier) }) else {
          let named = controls.map(\.name).filter { $0.contains("#") }.prefix(40)
          log?.write(
            "click: no control \(identifier) among \(controls.count) in "
              + "\(ChaosLog.describe(window)): \(named.joined(separator: "; "))")
          return
        }
        ChaosInput.click(at: control.point, in: window, count: count)
      case .shortcut(let name, let count):
        guard let shortcut = ChaosMenu.shortcuts.first(where: { $0.name == name }) else {
          log?.write("shortcut: no shortcut \(name)")
          return
        }
        for _ in 0..<count { ChaosInput.press(shortcut.key, shortcut.modifiers, in: window) }
      case .type(let text):
        ChaosInput.type(text, in: window)
      case .session, .wait:
        break
      }
    }

    private static func names(_ control: ChaosTargets.Control, _ identifier: String) -> Bool {
      control.name.split(separator: " ").contains("#\(identifier)")
    }

    private var visibleWindow: NSWindow? {
      NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
    }
  }
#endif

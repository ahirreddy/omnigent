#if DEBUG
  import AppKit
  import OSLog
  import OmnigentDesktop

  /// Debug builds launched with `-OmnigentChaos <seed>` drive themselves through a seeded random
  /// walk of everyday input to find crashes and hangs: menu commands, the app's shortcuts,
  /// clicks, drags, typing, pastes, scrolling, window resizes and session switches, all queued
  /// in-process (``ChaosInput``), so it needs neither Accessibility nor automation mode. Each step
  /// is written to `-OmnigentChaosLog <path>` before it runs, so a crash's last line names its
  /// step. Run it in a VM with `Tools/chaos-mac.sh`.
  ///
  /// Options: `-OmnigentChaosSteps` (default 400), `-OmnigentChaosInterval` seconds between steps
  /// (default 0.2), `-OmnigentChaosSessions id,id` to switch between (default: the demo's).
  @MainActor
  final class ChaosDriver {
    private static var shared: ChaosDriver?
    private static let logger = Logger(subsystem: "ai.omnigent.chaos", category: "driver")
    private static let demoSessions = ["demo-notes", "demo-design", "demo-question"]

    private var random: SplitMix
    private let seed: UInt64
    private let steps: Int
    private let interval: Duration
    private let sessions: [String]
    private let serverURL: () -> URL?
    private let router: DesktopRouter
    private let log: FileHandle?
    private var step = 0

    private init(
      seed: UInt64, defaults: UserDefaults, router: DesktopRouter, serverURL: @escaping () -> URL?
    ) {
      self.seed = seed
      random = SplitMix(seed: seed)
      steps =
        defaults.object(forKey: "OmnigentChaosSteps") == nil
        ? 400 : defaults.integer(forKey: "OmnigentChaosSteps")
      let seconds =
        defaults.object(forKey: "OmnigentChaosInterval") == nil
        ? 0.2 : defaults.double(forKey: "OmnigentChaosInterval")
      interval = .milliseconds(Int(max(0.01, seconds) * 1000))
      let listed = (defaults.string(forKey: "OmnigentChaosSessions") ?? "")
        .split(separator: ",").map(String.init)
      sessions = listed.isEmpty ? Self.demoSessions : listed
      self.router = router
      self.serverURL = serverURL
      log = defaults.string(forKey: "OmnigentChaosLog").flatMap(Self.openLog)
    }

    /// Starts the walk when the launch asks for one.
    static func startIfRequested(router: DesktopRouter, serverURL: @escaping () -> URL?) {
      let defaults = UserDefaults.standard
      guard shared == nil, let text = defaults.string(forKey: "OmnigentChaos"),
        let seed = UInt64(text)
      else { return }
      let driver = ChaosDriver(seed: seed, defaults: defaults, router: router, serverURL: serverURL)
      shared = driver
      NSSetUncaughtExceptionHandler { exception in recordUncaughtException(exception) }
      Task { await driver.run() }
    }

    private static func openLog(_ path: String) -> FileHandle? {
      guard FileManager.default.createFile(atPath: path, contents: nil) else {
        logger.error("Cannot write the chaos log at \(path, privacy: .public)")
        return nil
      }
      return FileHandle(forWritingAtPath: path)
    }

    private func write(_ line: String) {
      Self.logger.notice("\(line, privacy: .public)")
      guard let log else { return }
      do {
        try log.write(contentsOf: Data((line + "\n").utf8))
      } catch {
        Self.logger.error("Chaos log write failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    private func run() async {
      write("start seed=\(seed) steps=\(steps) sessions=\(sessions.joined(separator: ","))")
      NSApp.activate()
      do {
        try await waitForWindow()
        try await Task.sleep(for: .seconds(2))
        while step < steps {
          step += 1
          performStep()
          try await Task.sleep(for: interval)
        }
      } catch {
        write("STOPPED step=\(step): \(error)")
        exit(2)
      }
      write("DONE steps=\(step) windows=\(visibleWindows.count)")
      exit(0)
    }

    private struct NoWindow: Error {}

    private func waitForWindow() async throws {
      for _ in 0..<120 {
        if !visibleWindows.isEmpty { return }
        try await Task.sleep(for: .milliseconds(500))
      }
      throw NoWindow()
    }

    private var visibleWindows: [NSWindow] {
      NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
    }

    /// The window input goes to: the key window, else any visible one.
    private var window: NSWindow? { NSApp.keyWindow ?? visibleWindows.first }

    // MARK: Steps

    private enum Action: CaseIterable {
      case menu, shortcut, click, doubleClick, rightClick, drag, type, paste, key, scroll, resize
      case session, window

      var weight: Int {
        switch self {
        case .click: 20
        case .shortcut: 16
        case .menu, .type, .scroll: 11
        case .key: 9
        case .drag, .session: 4
        case .doubleClick, .rightClick, .paste, .resize: 3
        case .window: 1
        }
      }
    }

    private func performStep() {
      guard let window else {
        write("\(step) reopen")
        openSession()
        return
      }
      let action = pickAction()
      switch action {
      case .menu: invokeMenuItem()
      case .shortcut, .key: pressKeys(action, in: window)
      case .click, .doubleClick, .rightClick, .drag: point(action, in: window)
      case .type, .paste: enterText(action, in: window)
      case .scroll: scroll(in: window)
      case .resize, .session, .window: arrange(action, window)
      }
    }

    private func pressKeys(_ action: Action, in window: NSWindow) {
      if action == .shortcut { pressShortcut(in: window) } else { pressKey(in: window) }
    }

    private func point(_ action: Action, in window: NSWindow) {
      if action == .drag { drag(in: window) } else { click(action, in: window) }
    }

    private func enterText(_ action: Action, in window: NSWindow) {
      if action == .paste { paste(in: window) } else { type(in: window) }
    }

    private func arrange(_ action: Action, _ window: NSWindow) {
      switch action {
      case .resize: resize(window)
      case .session: openSession()
      default: changeWindow(window)
      }
    }

    private func pickAction() -> Action {
      let total = Action.allCases.reduce(0) { $0 + $1.weight }
      var roll = random.int(below: total)
      for action in Action.allCases {
        if roll < action.weight { return action }
        roll -= action.weight
      }
      return .click
    }

    private func invokeMenuItem() {
      let items = ChaosMenu.items()
      guard !items.isEmpty else {
        write("\(step) menu none")
        return
      }
      let choice = items[random.int(below: items.count)]
      write("\(step) menu \(choice.path)")
      // Asynchronously: an item may run a modal panel, which later steps then dismiss.
      DispatchQueue.main.async { choice.menu.performActionForItem(at: choice.index) }
    }

    private func pressShortcut(in window: NSWindow) {
      let shortcut = ChaosMenu.shortcuts[random.int(below: ChaosMenu.shortcuts.count)]
      write("\(step) shortcut \(shortcut.name)")
      ChaosInput.press(shortcut.key, shortcut.modifiers, in: window)
    }

    private func randomPoint(in window: NSWindow) -> CGPoint {
      let bounds = window.contentView?.bounds ?? .zero
      // A third of the clicks land in the titlebar row: the tab strip and toolbar.
      let top = random.int(below: 3) == 0
      let pointY =
        top ? bounds.height - CGFloat(random.int(below: 52)) : random.unit * bounds.height
      return CGPoint(x: random.unit * bounds.width, y: pointY)
    }

    private func click(_ action: Action, in window: NSWindow) {
      let point = randomPoint(in: window)
      let name = "\(action)".lowercased()
      write("\(step) \(name) \(Int(point.x)),\(Int(point.y)) in \(window.title)")
      switch action {
      case .doubleClick: ChaosInput.click(at: point, in: window, count: 2)
      case .rightClick: ChaosInput.click(at: point, in: window, right: true)
      default:
        let modifiers: NSEvent.ModifierFlags = random.int(below: 10) == 0 ? .command : []
        ChaosInput.click(at: point, in: window, modifiers: modifiers)
      }
    }

    private func drag(in window: NSWindow) {
      let start = randomPoint(in: window)
      let end = randomPoint(in: window)
      write("\(step) drag \(Int(start.x)),\(Int(start.y)) to \(Int(end.x)),\(Int(end.y))")
      ChaosInput.drag(from: start, to: end, steps: 4 + random.int(below: 12), in: window)
    }

    private func type(in window: NSWindow) {
      var text = ChaosText.snippets[random.int(below: ChaosText.snippets.count)]
      if random.int(below: 4) == 0 { text += "\r" }
      write("\(step) type \(text.debugDescription)")
      ChaosInput.type(text, in: window)
    }

    private func paste(in window: NSWindow) {
      let text = ChaosText.paste(lines: 1 + random.int(below: 800), seed: random.next())
      write("\(step) paste \(text.count) characters")
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      ChaosInput.press(.shortcut("v"), .command, in: window)
    }

    private func pressKey(in window: NSWindow) {
      let keys: [(String, ChaosKey)] = [
        ("escape", .escape), ("return", .returnKey), ("tab", .tab), ("delete", .delete),
        ("up", .upArrow), ("down", .downArrow), ("left", .leftArrow), ("right", .rightArrow),
        ("pageUp", .pageUp), ("pageDown", .pageDown), ("home", .home), ("end", .end),
      ]
      let (name, key) = keys[random.int(below: keys.count)]
      let modifiers: NSEvent.ModifierFlags = random.int(below: 4) == 0 ? .shift : []
      write("\(step) key \(name)\(modifiers.isEmpty ? "" : " shift")")
      ChaosInput.press(key, modifiers, in: window)
    }

    private func scroll(in window: NSWindow) {
      let point = randomPoint(in: window)
      let upward = random.int(below: 3) != 0
      let speed = CGFloat(20 + random.int(below: 400))
      let ticks = 1 + random.int(below: 30)
      write(
        "\(step) scroll \(upward ? "up" : "down") \(Int(speed))x\(ticks) at \(Int(point.x)),\(Int(point.y))"
      )
      ChaosInput.scroll(
        at: point, by: CGVector(dx: 0, dy: upward ? speed : -speed), ticks: ticks, in: window)
    }

    private func resize(_ window: NSWindow) {
      guard let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
      let minimum = window.minSize
      let width = minimum.width + random.unit * max(0, screen.width - minimum.width)
      let height = minimum.height + random.unit * max(0, screen.height - minimum.height)
      let frame = CGRect(x: screen.minX, y: screen.maxY - height, width: width, height: height)
      write("\(step) resize \(Int(width))x\(Int(height))")
      window.setFrame(frame, display: true, animate: random.int(below: 4) == 0)
    }

    private func openSession() {
      guard let server = serverURL() else {
        write("\(step) session: no server")
        return
      }
      let session = sessions[random.int(below: sessions.count)]
      write("\(step) session \(session)")
      router.open(.conversation(sessionID: session), onServer: server)
    }
  }

  extension ChaosDriver {
    /// Minimizes and restores, zooms, enters or leaves full screen, or opens a new window.
    fileprivate func changeWindow(_ window: NSWindow) {
      switch random.int(below: 4) {
      case 0:
        write("\(step) window minimize and restore")
        window.miniaturize(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { window.deminiaturize(nil) }
      case 1:
        write("\(step) window zoom")
        window.zoom(nil)
      case 2:
        write("\(step) window full screen")
        window.toggleFullScreen(nil)
      default:
        write("\(step) window new")
        ChaosInput.press(.shortcut("n"), [.command, .shift], in: window)
      }
    }
  }

  /// Appends an uncaught Objective-C exception to the chaos log, since the system log keeps its
  /// reason private.
  nonisolated private func recordUncaughtException(_ exception: NSException) {
    guard let path = UserDefaults.standard.string(forKey: "OmnigentChaosLog"),
      let log = FileHandle(forWritingAtPath: path)
    else { return }
    let stack = exception.callStackSymbols.prefix(40).joined(separator: "\n")
    let text =
      "EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "no reason")\n\(stack)\n"
    do {
      try log.seekToEnd()
      try log.write(contentsOf: Data(text.utf8))
    } catch {
      return
    }
  }

  /// SplitMix64: a small seeded generator, so a seed replays the same choices.
  struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var mixed = state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
      return mixed ^ (mixed >> 31)
    }

    /// A number in 0..<bound; 0 when `bound` is not positive.
    mutating func int(below bound: Int) -> Int {
      bound > 0 ? Int(next() % UInt64(bound)) : 0
    }

    /// A number in 0...1.
    var unit: CGFloat {
      mutating get { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }
    }
  }
#endif

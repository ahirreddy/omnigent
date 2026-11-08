#if DEBUG
  import AppKit
  import ObjectiveC
  import OSLog
  import OmnigentDesktop
  import OmnigentUIComponents

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
    /// Seconds between steps.
    private let interval: TimeInterval
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
      interval = max(0.01, seconds)
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
      if !ChaosToolbarProbe.install(write: { [driver] line in driver.write(line) }) {
        driver.write("TOOLBAR probe not installed")
      }
      ChaosLog.recordExceptions()
      LoopProbe.sink = { [driver] line in driver.write(line) }
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
        try log.seekToEnd()
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
      } catch {
        write("STOPPED before the first step: \(error)")
        exit(2)
      }
      // A timer in the common modes keeps stepping inside modal loops (an alert's runModal, a
      // menu's tracking), which hold the main actor; later steps then dismiss them.
      let timer = Timer(timeInterval: interval, repeats: true) { [self] _ in
        MainActor.assumeIsolated { tick() }
      }
      RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
      guard step < steps else {
        write("DONE steps=\(step) windows=\(visibleWindows.count)")
        exit(0)
      }
      if let field = ChaosLog.changedEditedField() { write(field) }
      step += 1
      performStep()
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
      case session, window, hover, compose, sweep

      var weight: Int {
        switch self {
        case .click: 20
        case .shortcut: 16
        case .menu, .type, .scroll: 11
        case .key: 9
        case .drag, .session, .hover: 4
        case .doubleClick, .rightClick, .paste, .resize, .compose, .sweep: 3
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
      case .click, .doubleClick, .rightClick, .drag, .hover: point(action, in: window)
      case .type, .paste, .compose: enterText(action, in: window)
      case .scroll: scroll(in: window)
      case .resize, .session, .window, .sweep: arrange(action, window)
      }
    }

    private func pressKeys(_ action: Action, in window: NSWindow) {
      if action == .shortcut { pressShortcut(in: window) } else { pressKey(in: window) }
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
      let (point, target) = clickTarget(in: window)
      let name = "\(action)".lowercased()
      write(
        "\(step) \(name) \(Int(point.x)),\(Int(point.y)) \(target) in \(ChaosLog.describe(window))")
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
      // A drag on a divider resizes the columns beside it while it moves.
      LoopProbe.quiet(for: 1)
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
          + " in \(ChaosLog.describe(window))"
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
      LoopProbe.quiet(for: 1)
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
    private func point(_ action: Action, in window: NSWindow) {
      switch action {
      case .drag: drag(in: window)
      case .hover: hover(in: window)
      default: click(action, in: window)
      }
    }

    private func enterText(_ action: Action, in window: NSWindow) {
      switch action {
      case .paste: paste(in: window)
      case .compose: compose(in: window)
      default: type(in: window)
      }
    }

    private func arrange(_ action: Action, _ window: NSWindow) {
      switch action {
      case .resize: resize(window)
      case .session: openSession()
      case .sweep: sweepHeight(window)
      default: changeWindow(window)
      }
    }

    /// Half the time a control from the window's accessibility tree, else any point.
    fileprivate func clickTarget(in window: NSWindow) -> (CGPoint, String) {
      if random.int(below: 2) == 0 {
        let controls = ChaosTargets.controls(in: window)
        if !controls.isEmpty {
          let control = controls[random.int(below: controls.count)]
          return (control.point, "on \(control.name)")
        }
      }
      return (randomPoint(in: window), "")
    }

    fileprivate func hover(in window: NSWindow) {
      let start = randomPoint(in: window)
      let end = randomPoint(in: window)
      write("\(step) hover \(Int(start.x)),\(Int(start.y)) to \(Int(end.x)),\(Int(end.y))")
      ChaosInput.hover(from: start, to: end, steps: 4 + random.int(below: 20), in: window)
    }

    /// Input-method text, a stage every few tenths of a second; a fifth of it abandoned. With
    /// nothing focused that takes text, it clicks a text field or area first, or with none on
    /// screen asks for the composer.
    fileprivate func compose(in window: NSWindow) {
      let words = ["かんじ", "漢字かな", "한국어", "中文输入法", "ㅎㅏㄴ", "にほんご"]
      let word = words[random.int(below: words.count)]
      let abandons = random.int(below: 5) == 0
      let pause = 0.02 + 0.3 * random.unit
      write("\(step) compose \(word)\(abandons ? " abandoned" : "")")
      if ChaosInput.compose(word, abandons: abandons, pause: pause, in: window) { return }
      let fields = ChaosTargets.textControls(in: window)
      if fields.isEmpty {
        ChaosInput.press(.shortcut("l"), [.control, .shift], in: window)
      } else {
        let field = fields[random.int(below: fields.count)]
        write("\(step) compose: click \(Int(field.point.x)),\(Int(field.point.y)) on \(field.name)")
        ChaosInput.click(at: field.point, in: window)
      }
      let step = step
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
        if !ChaosInput.compose(word, abandons: abandons, pause: pause, in: window) {
          write("\(step) compose: \(ChaosLog.describeTextFocus(in: window))")
        }
      }
    }

    fileprivate func changeWindow(_ window: NSWindow) {
      let choice = random.int(below: ChaosWindows.changes)
      let step = step
      LoopProbe.quiet(for: 2)
      ChaosWindows.change(window, choice: choice, look: random.int(below: 3)) {
        write("\(step) \($0)")
      }
    }

    /// Steps the window's height up or down across most of its range, a few tenths of a second
    /// a step, at a random width.
    fileprivate func sweepHeight(_ window: NSWindow) {
      guard let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
      let minimum = window.minSize
      let width = (minimum.width + random.unit * max(0, screen.width - minimum.width)).rounded()
      let tallest =
        minimum.height + (0.3 + 0.7 * random.unit) * max(0, screen.height - minimum.height)
      let upward = random.int(below: 2) == 0
      let steps = 10 + random.int(below: 40)
      let heights = ChaosWindows.sweepHeights(
        from: upward ? minimum.height : tallest, to: upward ? tallest : minimum.height, steps: steps
      )
      guard let first = heights.first, let last = heights.last else { return }
      let pause = 0.05 + 0.3 * random.unit
      write("\(step) sweep \(Int(width)) wide, \(Int(first)) to \(Int(last)) high")
      LoopProbe.quiet(for: pause * Double(heights.count) + 1)
      ChaosWindows.sweep(window, width: width, heights: heights, pause: pause)
    }
  }
#endif

internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// A frozen page leaves a line that says which kind of freeze it was. See DESIGN.md, "Freeze
/// diagnostics". The lines checked here are the ones written to the unified log.
extension Proofs {
  static let freezePages: [String: String] = [
    "freeze": """
    <!doctype html><title>OWL freeze</title>\(pageStyle)<h2>Freeze diagnostics</h2>
    <button id=hang>Hang</button> <button id=paint>Paint</button>
    <p id=result>none</p><div id=blank style="height: 240px"></div>
    <script>
    window.hangMilliseconds = 7000;
    document.querySelector('#hang').addEventListener('click', () => {
      const end = performance.now() + window.hangMilliseconds;
      while (performance.now() < end) {}
      document.querySelector('#result').textContent = 'hung ' + window.hangMilliseconds;
    });
    document.querySelector('#paint').addEventListener('click', () => {
      document.querySelector('#result').textContent = 'painted ' + performance.now();
    });
    </script>
    """,
    // A spinner the compositor animates by itself, so frames keep coming while a script hangs.
    "freeze-spinner": """
    <!doctype html><title>OWL spinner</title>\(pageStyle)<h2>Drawing while hung</h2>
    <style>@keyframes spin { to { transform: rotate(360deg) } }
    #spinner { width: 80px; height: 80px; background: linear-gradient(45deg, #36f, #f63);
      animation: spin 1s linear infinite; will-change: transform; margin: 24px }</style>
    <button id=hang>Hang</button><div id=spinner></div><p id=result>none</p>
    <script>
    document.querySelector('#hang').addEventListener('click', () => {
      const end = performance.now() + 8000;
      while (performance.now() < end) {}
      document.querySelector('#result').textContent = 'hung';
    });
    </script>
    """,
    // Changes its title fast enough to fill the channel while the app is not reading it.
    "freeze-flood": """
    <!doctype html><title>OWL flood</title>\(pageStyle)<h2>Channel backlog</h2>
    <p id=result>none</p>
    <script>
    window.flood = (delay, milliseconds) => setTimeout(() => {
      const end = performance.now() + milliseconds;
      let count = 0;
      const timer = setInterval(() => {
        for (let index = 0; index < 30; index++) document.title = 'OWL flood ' + (++count);
        if (performance.now() > end) {
          clearInterval(timer);
          document.querySelector('#result').textContent = 'flooded ' + count;
        }
      }, 0);
    }, delay);
    </script>
    """,
  ]

  /// The freeze scenarios by name, for running one alone (`--proof freeze-hung`).
  static let freezeScenarios: [String: (Proofs) -> () async throws -> Void] = [
    "freeze-hung": { $0.hungRenderer }, "freeze-hidden": { $0.viewLeftHidden },
    "freeze-idle": { $0.clickThatDrawsNothing }, "freeze-long": { $0.longHang },
    "freeze-drawing": { $0.hungWhileDrawing }, "freeze-backlog": { $0.channelBacklog },
    "freeze-late-input": { $0.inputHeldUpInTheApp },
  ]

  func freezeDiagnostics() async throws {
    try await hungRenderer()
    try await viewLeftHidden()
    try await clickThatDrawsNothing()
    try await longHang()
    try await hungWhileDrawing()
    try await channelBacklog()
    try await inputHeldUpInTheApp()
  }

  private func loadFreezePage() async throws {
    try await load(try await pageURL("freeze"), title: "OWL freeze")
    try await settle(OWLTiming.quietSeconds)
  }

  /// The page's script does not return: the host's question to the renderer goes unanswered,
  /// and is answered when the script ends.
  private func hungRenderer() async throws {
    try await loadFreezePage()
    let mark = freezeMark()
    let view = "view=\(webView.id) "
    // Located first: a hung page cannot be asked where its elements are.
    let hang = try await center(of: "#hang")
    let blank = try await center(of: "#blank")
    click(at: hang)
    // What a user does with a page that does not react: tries again.
    try await settle(0.4)
    click(at: blank)
    try await freezeLine("the host sees the stall", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=view-stall \(view)reason=input ")
    }
    try await freezeLine("the app sees it too", after: mark, timeout: 15) {
      $0.hasPrefix("kind=client-stall \(view)") && $0.contains("told_host=visible:1")
    }
    try await freezeLine("the renderer does not answer", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=renderer-probe \(view)renderer=hung ")
    }
    try await freezeLine("the renderer answers once the script ends", after: mark, timeout: 20) {
      $0.hasPrefix("from=host kind=renderer-probe \(view)renderer=recovered ")
    }
    try await freezeLine("the host sees frames again", after: mark, timeout: 20) {
      $0.hasPrefix("from=host kind=view-recovered \(view)")
    }
    try await freezeLine("the app sees frames again", after: mark, timeout: 20) {
      $0.hasPrefix("kind=client-recovered \(view)")
    }
    let result = try await resultText(webView)
    guard result == "hung 7000" else { throw ProofFailure("The page says \(result).") }
  }

  /// The renderer is fine but the view was left marked hidden, so nothing is drawn: the host
  /// reports input into a hidden view, and the renderer says its page is hidden.
  private func viewLeftHidden() async throws {
    try await loadFreezePage()
    let mark = freezeMark()
    let view = "view=\(webView.id) "
    let paint = try await center(of: "#paint")
    webView.setVisible(false)
    click(at: paint)
    try await freezeLine("input into a hidden view", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=view-stall \(view)reason=input-while-hidden ")
        && $0.contains(" visible=0 ")
    }
    try await freezeLine("the app says it told the host so", after: mark, timeout: 15) {
      $0.hasPrefix("kind=client-stall \(view)") && $0.contains("told_host=visible:0")
    }
    try await freezeLine("the renderer is alive and its page hidden", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=renderer-probe \(view)renderer=alive ")
        && $0.contains(" page=hidden/")
    }
    webView.setVisible(true)
    try await freezeLine("frames come back when it is shown", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=view-recovered \(view)")
    }
  }

  /// A click that changes nothing also goes without a frame. The renderer answers and runs
  /// animation frames, which is what tells this from a hung page.
  private func clickThatDrawsNothing() async throws {
    try await loadFreezePage()
    let mark = freezeMark()
    let view = "view=\(webView.id) "
    let blank = try await center(of: "#blank")
    // The first click takes the focus ring off the button, which is drawn; the second changes
    // nothing at all.
    click(at: blank)
    try await settle(1)
    click(at: blank)
    try await freezeLine("a stall is reported", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=view-stall \(view)reason=input ")
    }
    try await freezeLine("the renderer answers and draws", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=renderer-probe \(view)renderer=alive ")
        && $0.contains(" page=visible/") && $0.contains(" frames=alive ")
    }
    click(at: try await center(of: "#paint"))
    try await freezeLine("the next frame ends it", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=view-recovered \(view)")
    }
  }

  /// A stall that goes on is written again at ten seconds while somebody keeps trying, without
  /// a second question to the renderer. Long enough for Chromium's own hang monitor (15 s
  /// without handling input); whether that reports is logged, not required.
  private func longHang() async throws {
    try await loadFreezePage()
    let mark = freezeMark()
    _ = try await webView.evaluateJavaScript("window.hangMilliseconds = 19000; true")
    let hang = try await center(of: "#hang")
    let blank = try await center(of: "#blank")
    click(at: hang)
    try await settle(0.4)
    click(at: blank)
    try await freezeLine("the long stall is reported", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=view-stall ") && $0.contains(" line=1 ")
    }
    click(at: blank)
    try await freezeLine("and followed up at ten seconds", after: mark, timeout: 20) {
      $0.hasPrefix("from=host kind=view-stall ") && $0.contains(" line=2 ")
    }
    try await freezeLine("the first question still stands", after: mark, timeout: 20) {
      $0.hasPrefix("from=host kind=renderer-probe ") && $0.contains("renderer=hung asked=earlier")
    }
    try await freezeLine("the long hang ends", after: mark, timeout: 30) {
      $0.hasPrefix("from=host kind=view-recovered ")
    }
    let lines = model.session.freezeLines
    let began = lines.contains { $0.contains("kind=renderer-unresponsive") }
    let ended = lines.contains { $0.contains("kind=renderer-responsive") }
    Clock.log(
      "Chromium's hang monitor: start \(began ? "" : "not ")reported, end \(ended ? "" : "not ")reported"
    )
  }

  /// The script hangs while the compositor keeps animating: no frame is missing, so only the
  /// question the host asks a page in use shows the renderer is stuck.
  private func hungWhileDrawing() async throws {
    try await load(try await pageURL("freeze-spinner"), title: "OWL spinner")
    try await settle(OWLTiming.quietSeconds)
    let mark = freezeMark()
    let view = "view=\(webView.id) "
    let hang = try await center(of: "#hang")
    let frames = webView.statistics.framesPresented
    click(at: hang)
    try await freezeLine("a page in use does not answer", after: mark, timeout: 15) {
      $0.hasPrefix("from=host kind=renderer-probe \(view)renderer=hung ")
        && $0.contains("asked=while-in-use")
    }
    Clock.log(
      "frames presented while the script hung: \(webView.statistics.framesPresented - frames)")
    try await freezeLine("and answers when the script ends", after: mark, timeout: 20) {
      $0.hasPrefix("from=host kind=renderer-probe \(view)renderer=recovered ")
    }
  }

  /// The app stops reading the channel while the page keeps the host sending: the host's sends
  /// time out, its main thread spends its time waiting on them, and it says so when the app
  /// reads again. The host's lines from the blocked stretch are only in the unified log.
  private func channelBacklog() async throws {
    try await load(try await pageURL("freeze-flood"), title: "OWL flood")
    try await settle(OWLTiming.quietSeconds)
    let mark = freezeMark()
    // The flood starts after any ping in flight is answered: a lost answer ends the host.
    _ = try await webView.evaluateJavaScript("window.flood(600, 3000); true")
    click(at: CGPoint(x: 40, y: 200))
    blockMainThread(seconds: 5)
    Clock.log("after the block: title '\(webView.title)', page \(try await resultText(webView))")
    try await freezeLine("the app notices its own stall", after: mark, timeout: 10) {
      $0.hasPrefix("kind=client-timer-late ")
    }
    try await freezeLine("the host says the channel drained", after: mark, timeout: 30) {
      $0.hasPrefix("from=host kind=channel-drained ")
    }
    guard model.session.isReady else { throw ProofFailure("The host did not survive the backlog.") }
    let result = try await resultText(webView)
    let stalled = model.session.freezeLines.contains {
      $0.hasPrefix("from=host kind=host-recovered ")
    }
    Clock.log(
      "the page \(result); the host \(stalled ? "reported" : "did not report") a stall of its own")
  }

  /// The app hands the page a click long after it happened, as it does when its main thread
  /// was busy meanwhile. The page answers at once, so only the app's line shows the wait.
  private func inputHeldUpInTheApp() async throws {
    try await loadFreezePage()
    let mark = freezeMark()
    let paint = try await center(of: "#paint")
    click(at: paint, happened: ProcessInfo.processInfo.systemUptime - 1.5)
    try await freezeLine("the app says the click was held up", after: mark, timeout: 5) {
      $0.hasPrefix("kind=client-input-late view=\(self.webView.id) late_ms=15")
    }
    try await settle(0.5)
    let result = try await resultText(webView)
    guard result.hasPrefix("painted ") else { throw ProofFailure("The page says \(result).") }
  }

  /// Keeps the app from reading the channel, as a long layout pass would.
  private func blockMainThread(seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
  }

  /// The newest diagnostic so far; lines after it belong to the scenario that follows.
  private func freezeMark() -> String? {
    model.session.freezeLines.last
  }

  /// Waits for a diagnostic line written after `mark` that satisfies `matches`, and logs it.
  @discardableResult
  private func freezeLine(
    _ what: String, after mark: String?, timeout: Double, _ matches: (String) -> Bool
  ) async throws -> String {
    var found: String?
    do {
      try await waitUntil(what, timeout: timeout) {
        let lines = self.model.session.freezeLines
        let start = mark.flatMap { lines.lastIndex(of: $0) }.map { $0 + 1 } ?? 0
        found = lines[start...].first(where: matches)
        return found != nil
      }
    } catch {
      for line in model.session.freezeLines { Clock.log("  had: \(line)") }
      throw error
    }
    guard let found else { throw ProofFailure("Timed out: \(what)") }
    Clock.log("\(what): \(found)")
    return found
  }
}

/// Waits the proof needs between scenarios.
private enum OWLTiming {
  /// Longer than the gap the watch leaves between the first lines of two stalls.
  static let quietSeconds = 6.0
}

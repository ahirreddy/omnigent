#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inspector: the fork sheet's options", .serialized)
  @MainActor
  struct InspectorForkOptionsTests {
    @Test("Picking a sandbox hides the directory and starts on Clone")
    func sandbox() throws {
      let log = SheetLog()
      let options = ForkOptions(hosts: [ForkHostOption(id: "h", name: "Box")], offersSandbox: true)
      let screen = forkSheet(forkState(options: options), forkActions(log))
      defer { screen.close() }
      try screen.pick("New sandbox", in: screen.pickers[1])
      #expect(log.calls.contains("sandbox -"))
      #expect(try !screen.shows("Directory"))
      try screen.clickBar()
      #expect(log.choices?.start == true)
      #expect(log.choices?.isSandbox == true)
      #expect(log.choices?.hostID == nil)
    }

    @Test("Named sandboxes report their provider")
    func namedSandbox() throws {
      let log = SheetLog()
      let options = ForkOptions(
        offersSandbox: true, sandboxes: [ForkSandboxOption(provider: "e2b", label: "E2B")])
      let screen = forkSheet(forkState(options: options), forkActions(log))
      defer { screen.close() }
      try screen.pick("E2B", in: screen.pickers[1])
      #expect(log.calls.last == "sandbox e2b")
    }

    @Test("A sandbox problem blocks Clone; checking branches says so")
    func sandboxProblem() throws {
      let log = SheetLog()
      var options = ForkOptions(offersSandbox: true)
      options.sandboxProblem = "Not a git repo"
      let screen = forkSheet(forkState(options: options), forkActions(log))
      defer { screen.close() }
      try screen.pick("New sandbox", in: screen.pickers[1])
      // Cancel is the last that still takes a click.
      try screen.clickBar()
      #expect(log.choices == nil)
      #expect(log.calls.last == "cancel")
      var checking = ForkOptions(offersSandbox: true)
      checking.isCheckingBranches = true
      let waiting = forkSheet(forkState(options: checking), forkActions(log))
      defer { waiting.close() }
      try waiting.pick("New sandbox", in: waiting.pickers[1])
      #expect(try waiting.shows("Checking current branches\u{2026}"))
    }

    @Test("The permission picker's title follows the harness")
    func modeTitle() {
      #expect(ForkOptionsSections.modeTitle(harness: "codex-native") == "Approval")
      #expect(ForkOptionsSections.modeTitle(harness: "Cursor") == "Mode")
      #expect(ForkOptionsSections.modeTitle(harness: "claude") == "Permissions")
      #expect(ForkOptionsSections.modeTitle(harness: nil) == "Permissions")
    }

    @Test(
      "Model, effort and permissions go into the choices, with a danger warning for full access")
    func runConfiguration() throws {
      let log = SheetLog()
      let options = ForkOptions(
        models: [
          ModelOption(id: "opus", displayName: "Opus", supportedReasoningEfforts: ["low", "high"]),
          ModelOption(id: "hidden", hidden: true),
          ModelOption(id: "plain"),
        ],
        approvalModes: [
          "a": [
            ApprovalModeOption(id: "ask", label: "Ask", detail: "Asks first"),
            ApprovalModeOption(id: "yolo", label: "Yolo", risk: .fullAccess),
          ]
        ])
      let screen = forkSheet(forkState(options: options), forkActions(log))
      defer { screen.close() }
      #expect(try screen.shows("Asks first"))
      // Agent, Model, Permissions.
      let modelMenu = try screen.openMenu(screen.pickers[1])
      #expect(modelMenu.item(named: "hidden") == nil)
      #expect(modelMenu.item(named: "plain") != nil)
      try screen.choose("Opus", in: modelMenu)
      // Agent, Model, Effort, Permissions.
      #expect(screen.pickers.count == 4)
      try screen.pick("High", in: screen.pickers[2])
      try screen.pick("Yolo", in: screen.pickers[3])
      #expect(try screen.shows(containing: "Danger: this fork runs the agent with Yolo"))
      try screen.clickBar(fromLast: 1)
      #expect(log.choices?.model == "opus")
      #expect(log.choices?.effort == "high")
      #expect(log.choices?.approvalMode == "yolo")
    }

    @Test("Advanced has title and, when it starts on a host, branch")
    func advanced() throws {
      let log = SheetLog()
      let screen = forkSheet(forkState(), forkActions(log))
      defer { screen.close() }
      #expect(try !screen.shows("Title"))
      let controls = screen.controlFrames
      try screen.clickControl(at: controls.count - 4)
      screen.settle(0.1)
      let branchHint = "Creates a git worktree for a new branch so the copy does not share files"
      #expect(try screen.shows(containing: branchHint))
    }
  }
#endif

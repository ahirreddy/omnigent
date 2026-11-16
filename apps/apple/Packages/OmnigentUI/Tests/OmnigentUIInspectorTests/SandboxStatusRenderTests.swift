#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What the sandbox control and its panel draw; the images are kept when
  /// `OMNIGENT_UI_RENDER_DIR` names a directory.
  @Suite("Sandbox status: renders", .serialized)
  @MainActor
  struct SandboxStatusRenderTests {
    private func icon(_ mark: SandboxStatusState.Mark) -> some View {
      Image(systemName: "shippingbox")
        .font(.title2)
        .accessibilityHidden(true)
        .overlay(alignment: .bottomTrailing) { SandboxStatusMark(mark: mark) }
        .padding(16)
    }

    @Test(
      "A running, a resting, a waiting and a failed sandbox each draw their own mark",
      arguments: [ColorScheme.light, .dark])
    func marks(scheme: ColorScheme) throws {
      var drawn: [Data] = []
      for mark in SandboxStatusState.Mark.allCases where mark != .progress {
        let rendered = try RenderSupport.render(
          icon(mark), width: 64, height: 64, scheme: scheme, layout: .regular)
        try RenderSupport.write(rendered, name: "sandbox-mark-\(mark.rawValue)-\(scheme)")
        drawn.append(try #require(rendered.image.representation(using: .png, properties: [:])))
      }
      #expect(Set(drawn).count == drawn.count, "two marks draw the same in \(scheme)")
    }

    @Test("The panel grows by what a state adds: what to do, the error, a refusal")
    func panels() throws {
      var asleep = SandboxFixture.state(.resting, "Asleep")
      asleep.profile = "GPU box"
      asleep.hint = "The next message wakes it."
      asleep.host = .offline
      asleep.runner = .offline
      asleep.operations[1].unavailableReason = "The agent is not running."
      var failed = SandboxFixture.state(.failed, "Sandbox launch failed")
      failed.error = "Managed sandbox launch failed: the workspace is out of quota."
      failed.operations[0].title = "Retry Launch"
      failed.operations[1].unavailableReason = "The agent is not running."
      var waiting = SandboxFixture.state(.attention, "Provisioning sandbox")
      waiting.details = "Sign in on your laptop."
      let states = [
        ("running", SandboxFixture.running), ("asleep", asleep), ("waiting", waiting),
        ("failed", failed),
      ]
      var heights: [String: CGFloat] = [:]
      for (name, state) in states {
        let panel = SandboxStatusPanel(
          state: state, actions: SandboxFixture.actions(HostLog()), model: SandboxPanelModel())
        for scheme in [ColorScheme.light, .dark] {
          let rendered = try RenderSupport.render(
            panel, width: 320, scheme: scheme, layout: .regular)
          try RenderSupport.write(rendered, name: "sandbox-panel-\(name)-\(scheme)")
          heights[name] = rendered.size.height
        }
      }
      let running = try #require(heights["running"])
      #expect(try #require(heights["asleep"]) > running, "the profile and the hint add lines")
      #expect(try #require(heights["waiting"]) > running, "what to do adds a row")
      #expect(try #require(heights["failed"]) > running, "the error adds a row")
    }
  }
#endif

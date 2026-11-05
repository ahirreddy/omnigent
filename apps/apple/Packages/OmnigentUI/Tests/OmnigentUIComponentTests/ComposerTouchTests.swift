import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// The touch composer (iPhone and iPad): no Escape, Stop in reach, and a compact bar.
@Suite("Touch composer", .serialized)
struct ComposerTouchTests {
  private func rules(_ state: ComposerViewState, draft: String = "", layout: ComposerLayoutStyle)
    -> ComposerSendRules
  {
    ComposerSendRules(state: state, draft: draft, canQueue: true, layout: layout)
  }

  @Test("touch placeholders say what a send does; the Mac's name the keys")
  func placeholders() {
    var running = ComposerSamples.running
    running.queue = []
    let touch = rules(running, layout: .touch)
    #expect(touch.placeholder == "Steer the agent\u{2026}")
    #expect(!touch.placeholder.contains("Esc"))
    #expect(
      rules(running, layout: .card).placeholder
        == "\u{21B5} to send now, \u{2325}\u{2318}\u{21B5} to queue for later")

    var queueing = ComposerSamples.running
    queueing.canSteer = false
    #expect(rules(queueing, layout: .touch).placeholder == "Queue a follow-up\u{2026}")
    #expect(rules(queueing, layout: .card).placeholder == "\u{21B5} to queue for later")
    // Queued messages keep their order, so Return queues and the alternative steers.
    #expect(
      rules(ComposerSamples.running, layout: .card).placeholder
        == "\u{21B5} to queue for later, \u{2325}\u{2318}\u{21B5} to send now")

    #expect(rules(ComposerSamples.idle, layout: .touch).placeholder == "Reply\u{2026}")
    #expect(
      rules(ComposerSamples.idle, layout: .card).placeholder
        == "\u{21B5} to send, \u{21E7}\u{21B5} for a new line")
    var commandReturn = ComposerSamples.idle
    commandReturn.submitWithCommandReturn = true
    #expect(
      rules(commandReturn, layout: .card).placeholder
        == "\u{2318}\u{21B5} to send, \u{21B5} for a new line")
    // A new session keeps its own prompt.
    #expect(!rules(ComposerSamples.start, layout: .touch).placeholder.contains("Reply"))
    #expect(
      rules(ComposerSamples.start, layout: .card).placeholder == "Describe what to build\u{2026}")
  }

  #if os(macOS)
    @Test("the Mac's pill is one 48 pt row; the controls row sits under it")
    func pillHeight() throws {
      // Running, with the task indicators in the row under the pill.
      var running = runningNoQueue
      running.tray?.indicators = ComposerTaskIndicators(
        backgroundTasks: 2,
        subagents: [
          SubagentChild(id: "a", sectionID: "child-a", title: "Tests", status: .needsYou),
          SubagentChild(id: "b", sectionID: "child-b", title: "Docs", status: .running),
        ],
        goal: ComposerGoal(objective: "Ship the token refresh fix", status: "active"))
      let states = [("idle", ComposerSamples.idle), ("running", running)]
      for (name, state) in states {
        for scheme in [ColorScheme.light, .dark] {
          let composer = ComposerView(
            draft: .constant(""), state: state, actions: ComposerActions(send: {}, interrupt: {})
          )
          .environment(\.composerLayoutStyle, .card)
          .environment(\.controlActiveState, .inactive)
          .omnigentTheme(.omni)
          let rendered = try RenderSupport.render(
            composer, width: 760, scheme: scheme, layout: .regular)
          try RenderSupport.write(rendered, name: "composer-pill-\(name)-\(scheme)")
          // Points: 12 pt margins, the 48 pt pill, the controls row, with rounding slack.
          let points = rendered.size.height / (NSScreen.main?.backingScaleFactor ?? 2)
          #expect(points <= 120, "\(name) composer is \(points) pt")
        }
      }
    }
  #endif

  #if os(macOS)
    @Test("the idle touch bar is about the competitors' height")
    func collapsedHeight() throws {
      for (name, state) in [("idle", ComposerSamples.idle), ("running", runningNoQueue)] {
        let bar = ComposerView(
          draft: .constant(""), state: state, actions: ComposerActions(send: {}, interrupt: {})
        )
        .environment(\.composerLayoutStyle, .touch)
        .omnigentTheme(.omni)
        let rendered = try RenderSupport.render(bar, width: 390, scheme: .light, layout: .compact)
        try RenderSupport.write(rendered, name: "composer-touch-\(name)")
        // Points: one 44 pt row, 2 pt card padding and 6 pt margins, with rounding slack.
        let points = rendered.size.height / (NSScreen.main?.backingScaleFactor ?? 2)
        #expect(points <= 64, "\(name) bar is \(points) pt")
      }
    }
  #endif

  private var runningNoQueue: ComposerViewState {
    var state = ComposerSamples.running
    state.queue = []
    return state
  }
}

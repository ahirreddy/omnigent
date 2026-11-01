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

  @Test("touch placeholders never mention Escape; the Mac keeps it")
  func placeholders() {
    var running = ComposerSamples.running
    running.queue = []
    let touch = rules(running, layout: .touch)
    #expect(touch.placeholder == "Steer the agent\u{2026}")
    #expect(!touch.placeholder.contains("Esc"))
    #expect(rules(running, layout: .card).placeholder == "Steer the agent \u{2014} Esc to stop")

    var queueing = ComposerSamples.running
    queueing.canSteer = false
    #expect(rules(queueing, layout: .touch).placeholder == "Queue a follow-up\u{2026}")

    #expect(rules(ComposerSamples.idle, layout: .touch).placeholder == "Reply\u{2026}")
    #expect(rules(ComposerSamples.idle, layout: .card).placeholder == "Send a message\u{2026}")
    // A new session keeps its own prompt.
    #expect(!rules(ComposerSamples.start, layout: .touch).placeholder.contains("Reply"))
  }

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

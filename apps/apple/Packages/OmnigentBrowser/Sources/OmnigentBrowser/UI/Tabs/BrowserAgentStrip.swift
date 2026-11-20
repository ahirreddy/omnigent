import SwiftUI

/// Above a page an agent drives: who is in control, with Take Over and Stop, or Hand Back.
struct BrowserAgentStrip: View {
  let model: BrowserTabModel

  var body: some View {
    if let control = model.agentControl {
      HStack(spacing: 8) {
        Image(systemName: control == .user ? "person.fill" : "cursorarrow.rays")
          .foregroundStyle(control == .active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .accessibilityHidden(true)
        Text(Self.message(control))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
        if control == .user {
          Button("Hand Back to Agent") { model.performAgentControl(.handBack) }
            .controlSize(.small)
            .accessibilityIdentifier("browser.agent.handBack")
        } else {
          Button("Take Over") { model.performAgentControl(.takeOver) }
            .controlSize(.small)
            .accessibilityIdentifier("browser.agent.takeOver")
          Button("Stop") { model.performAgentControl(.stop) }
            .controlSize(.small)
            .help("Take over and stop the agent's turn; the tab stays open")
            .accessibilityIdentifier("browser.agent.stop")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .background(.bar)
      .overlay(alignment: .bottom) { Divider() }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("browser.agent.control")
    }
  }

  /// The strip's text for `control`.
  static func message(_ control: BrowserAgentControl) -> String {
    switch control {
    case .active, .idle: "Agent is controlling this tab"
    case .user: "You're in control \u{00B7} the agent is waiting"
    }
  }
}

/// A thin accent border around a page while the agent acts on it.
struct BrowserAgentActivityBorder: View {
  let model: BrowserTabModel

  var body: some View {
    if model.agentControl == .active {
      Rectangle()
        .strokeBorder(.tint, lineWidth: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}

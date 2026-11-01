import SwiftUI

#Preview("Full layout", traits: .fixedLayout(width: 1_400, height: 860)) {
  PlaygroundView(model: PlaygroundModel(scenario: .streaming))
}

#Preview("Terminal mode", traits: .fixedLayout(width: 1_400, height: 860)) {
  PlaygroundView(model: PlaygroundModel(scenario: .terminal))
}

#Preview("Pending approvals", traits: .fixedLayout(width: 1_400, height: 860)) {
  PlaygroundView(model: PlaygroundModel(scenario: .approvals))
}

#Preview("Errors", traits: .fixedLayout(width: 1_400, height: 860)) {
  PlaygroundView(model: PlaygroundModel(scenario: .errors))
}

#Preview("Empty", traits: .fixedLayout(width: 1_400, height: 860)) {
  PlaygroundView(model: PlaygroundModel(scenario: .empty))
}

#Preview("Compact", traits: .fixedLayout(width: 480, height: 900)) {
  PlaygroundView(model: PlaygroundModel(scenario: .compact))
}

#Preview("New session", traits: .fixedLayout(width: 1_400, height: 860)) {
  PlaygroundView(model: PlaygroundModel(scenario: .newSession))
}

#Preview("Inbox", traits: .fixedLayout(width: 1_400, height: 860)) {
  PlaygroundView(model: PlaygroundModel(scenario: .inbox))
}

#Preview("Server settings", traits: .fixedLayout(width: 900, height: 600)) {
  PlaygroundView(model: PlaygroundModel(scenario: .serverSettings))
}

#Preview("Themes", traits: .fixedLayout(width: 1_000, height: 900)) {
  ThemeGalleryView()
}

import Foundation

extension SessionConfiguration {
  public static var demo: Self {
    var value = Self()
    value.agentID = "demo-codex"
    value.harness = "codex-native"
    value.wrapper = "codex-native-ui"
    value.modelOverride = "sample-balanced"
    value.modelReported = true
    value.effortReported = true
    value.hostID = "demo-host"
    value.hostOnline = true
    value.runnerOnline = true
    value.models = [
      ModelChoice(
        id: "sample-balanced", displayName: "Sample Balanced", description: "Offline preview only",
        isDefault: true,
        supportedReasoningEfforts: [
          ReasoningChoice(reasoningEffort: "low"), ReasoningChoice(reasoningEffort: "high"),
        ]),
      ModelChoice(
        id: "sample-fast", displayName: "Sample Fast", description: "Offline preview only",
        supportedReasoningEfforts: [ReasoningChoice(reasoningEffort: "low")]),
    ]
    return value
  }
}

extension ConfigurationCatalog {
  public static var demo: Self {
    ConfigurationCatalog(
      agents: [
        HarnessChoice(
          id: "demo-codex", name: "Sample Codex", harness: "codex-native", builtin: true),
        HarnessChoice(
          id: "demo-claude", name: "Sample Claude", harness: "claude-native", builtin: true),
      ],
      host: ConfigurationHost(
        hostID: "demo-host", name: "Offline demo host", status: "online",
        configuredHarnesses: ["codex-native": .bool(true), "claude-native": .bool(true)]))
  }
}

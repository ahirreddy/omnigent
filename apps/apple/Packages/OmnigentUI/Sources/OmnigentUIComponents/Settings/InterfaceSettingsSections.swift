import OmnigentWorkspaceUI
public import SwiftUI

/// Settings › General › Links and Sub-agents: in-app links and sub-agents in a new window.
public struct LinksAndSessionsSettingsSection: View {
  @AppStorage(InterfacePreferences.openLinksInAppKey) private var openLinksInApp = false
  @AppStorage(InterfacePreferences.openSubagentsInPanelKey) private var openSubagentsInPanel =
    false

  /// Creates the section.
  public init() {}

  /// The section.
  public var body: some View {
    Section("Links and Sub-agents") {
      Toggle(isOn: $openLinksInApp) {
        Text("Open links in the in-app browser")
        Text(
          "Web links from chat open in a browser tab in this window instead of your default "
            + "browser.")
      }
      .accessibilityIdentifier("settings.open-links-in-app")
      Toggle(isOn: $openSubagentsInPanel) {
        Text("Open sub-agents in a new window")
        Text(
          "On: a sub-agent opens in a window of its own, beside this one. Off: it replaces this "
            + "session in the window. On iPhone, sub-agents always open in place.")
      }
      .accessibilityIdentifier("settings.open-subagents-in-panel")
    }
  }
}

/// Settings › Appearance extras, as the web's: the new-session picker, the right panel's
/// defaults and code typography.
public struct InterfaceAppearanceSections: View {
  @AppStorage(InterfacePreferences.hideUnconfiguredHarnessesKey) private var hideUnconfigured =
    false
  @AppStorage(InterfacePreferences.workspacePanelKey) private var workspacePanel =
    WorkspacePanelDefault.collapsed
  @AppStorage(InterfacePreferences.defaultWorkspaceTabKey) private var workspaceTab =
    DefaultWorkspaceTab.files
  @AppStorage(TranscriptViewDefault.key) private var transcriptView = TranscriptViewDefault.chat
  @Environment(\.pickerVisibilitySource) private var pickerSource
  @Bindable private var code = CodeTypography.shared

  /// Creates the sections.
  public init() {}

  /// The sections.
  public var body: some View {
    Section("Chat defaults") {
      Toggle(isOn: $hideUnconfigured) {
        Text("Hide unconfigured harnesses")
        Text(
          "The new-session picker shows only harnesses set up on the selected host, instead of "
            + "badging the others.")
      }
      .accessibilityIdentifier("settings.hide-unconfigured-harnesses")
      if let pickerSource {
        PickerVisibilitySetting(source: pickerSource)
      }
      Picker(selection: $transcriptView) {
        ForEach(TranscriptViewDefault.allCases) { Text($0.title).tag($0) }
      } label: {
        Text("Default transcript view")
        Text(
          "Whether terminal-backed chats open in Chat or Terminal. A terminal you open in a "
            + "window stays open as its tab.")
      }
      .accessibilityIdentifier("settings.default-transcript-view")
    }
    Section {
      Picker("Workspace panel", selection: $workspacePanel) {
        ForEach(WorkspacePanelDefault.allCases) { Text($0.title).tag($0) }
      }
      .accessibilityIdentifier("settings.workspace-panel")
      Picker("Default tab", selection: $workspaceTab) {
        ForEach(DefaultWorkspaceTab.allCases) { Text($0.title).tag($0) }
      }
      .accessibilityIdentifier("settings.workspace-tab")
    } header: {
      Text("Workspace")
    } footer: {
      Text(
        "Whether chats open with the right panel shown, and its first tab. Showing or hiding "
          + "the panel updates this.")
    }
    Section("Code typography") {
      LabeledContent("Code font size") {
        Stepper(value: $code.size, in: CodeTypography.sizes, step: 1) {
          Text("\(Int(code.size)) pt").monospacedDigit()
        }
      }
      .accessibilityIdentifier("settings.code-font-size")
      TextField("Code font family", text: $code.family, prompt: Text("System monospaced"))
        .accessibilityIdentifier("settings.code-font-family")
      Toggle("Heavier code font", isOn: $code.isHeavier)
        .accessibilityIdentifier("settings.code-font-weight")
      Text("let answer = 42").font(CodeTypography.shared.font(size: 12))
        .foregroundStyle(.secondary)
    }
  }
}

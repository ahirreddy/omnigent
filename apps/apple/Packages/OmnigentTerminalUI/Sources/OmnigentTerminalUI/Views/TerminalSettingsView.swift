public import SwiftUI

/// Terminal appearance settings: font size, scrollback, Option as Alt and cursor blink. Colors
/// follow the system light or dark mode.
public struct TerminalSettingsView: View {
  @State private var appearance: TerminalAppearance
  @State private var error: String?
  @AppStorage(TerminalClipboardPolicy.key) private var clipboard = TerminalClipboardPolicy.ask

  /// Settings for the shared runtime's current appearance.
  public init() {
    do {
      _appearance = State(initialValue: try GhosttyRuntime.shared().appearance)
      _error = State(initialValue: nil)
    } catch {
      _appearance = State(initialValue: TerminalAppearance.system())
      _error = State(initialValue: error.description)
    }
  }

  /// The view's content.
  public var body: some View {
    Form {
      Section("Font") {
        Stepper(value: $appearance.fontSize, in: 8...32, step: 1) {
          LabeledContent("Size", value: "\(Int(appearance.fontSize)) pt")
        }
        LabeledContent(
          "Family", value: appearance.fontFamily ?? TerminalFonts.systemFamily ?? "Default")
      }
      Section("Behavior") {
        Picker("Scrollback", selection: $appearance.scrollback) {
          ForEach(TerminalScrollback.allCases) { option in
            Text(option.label).tag(option)
          }
        }
        #if os(macOS)
          Toggle("Use Option as Alt", isOn: $appearance.optionAsAlt)
        #endif
        Toggle("Blinking cursor", isOn: $appearance.cursorBlink)
      }
      Section {
        Picker("Copying from terminals", selection: $clipboard) {
          ForEach(TerminalClipboardPolicy.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("settings.terminal-clipboard")
      } header: {
        Text("Clipboard")
      } footer: {
        Text(
          "Allowing copying also lets terminal programs silently replace your clipboard with text or commands you didn\u{2019}t intend to paste."
        )
      }
      if let error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: appearance) { _, value in apply(value) }
  }

  private func apply(_ value: TerminalAppearance) {
    do {
      try GhosttyRuntime.shared().update(appearance: value)
      error = nil
    } catch let failure {
      error = failure.description
    }
  }
}

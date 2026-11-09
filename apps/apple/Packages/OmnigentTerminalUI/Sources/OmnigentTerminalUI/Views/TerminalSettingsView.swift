public import SwiftUI

/// Terminal settings: font, scrollback, Option as Alt and cursor blink, kept across launches
/// (``TerminalPreferences``). Colors follow the app, or Settings › Appearance's terminal theme.
public struct TerminalSettingsView: View {
  @State private var appearance: TerminalAppearance
  @State private var error: String?
  @State private var families: [String] = []
  @AppStorage(TerminalClipboardPolicy.key) private var clipboard = TerminalClipboardPolicy.ask

  private let runtimeSource: GhosttyRuntimeSource

  /// Settings for the shared runtime's current appearance.
  public init() {
    self.init(runtimeSource: GhosttyRuntime.shared)
  }

  init(runtimeSource: @escaping GhosttyRuntimeSource) {
    self.runtimeSource = runtimeSource
    do {
      _appearance = State(initialValue: try runtimeSource().appearance)
      _error = State(initialValue: nil)
    } catch {
      _appearance = State(initialValue: TerminalPreferences.load(over: .system()))
      _error = State(initialValue: error.description)
    }
  }

  /// The view's content.
  public var body: some View {
    Form {
      Section("Font") {
        Stepper(value: $appearance.fontSize, in: TerminalPreferences.fontSizes, step: 1) {
          LabeledContent("Size", value: "\(Int(appearance.fontSize)) pt")
        }
        if families.isEmpty {
          LabeledContent(
            "Family", value: appearance.fontFamily ?? TerminalFonts.systemFamily ?? "Default")
        } else {
          Picker("Family", selection: $appearance.fontFamily) {
            Text("System (\(TerminalFonts.systemFamily ?? "Default"))").tag(String?.none)
            ForEach(families, id: \.self) { Text($0).tag(Optional($0)) }
          }
          .accessibilityIdentifier("settings.terminal-font-family")
        }
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
    .task { families = TerminalFonts.monospacedFamilies() }
    .onChange(of: appearance) { _, value in apply(value) }
  }

  /// Applies `value` to every terminal, and keeps it only once libghostty accepts it.
  private func apply(_ value: TerminalAppearance) {
    do {
      let runtime = try runtimeSource()
      try runtime.update(appearance: TerminalPreferences.merge(value, into: runtime.appearance))
      TerminalPreferences.save(value)
      error = nil
    } catch let failure {
      error = failure.description
    }
  }
}

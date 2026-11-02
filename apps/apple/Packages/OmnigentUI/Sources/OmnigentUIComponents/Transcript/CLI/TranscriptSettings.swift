public import SwiftUI

/// Settings > Appearance > Transcript: Style (Chat or CLI), Output rendering and Content width
/// for that style, and the CLI font size.
public struct TranscriptSettingsSection: View {
  @Bindable private var preferences: TranscriptPreferences

  /// Creates the section.
  /// - Parameter preferences: The device's transcript preferences.
  public init(preferences: TranscriptPreferences) {
    self.preferences = preferences
  }

  /// The section.
  public var body: some View {
    Section {
      Picker("Style", selection: $preferences.style) {
        ForEach(TranscriptStyle.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("settings.transcript-style")
      Picker("Output rendering", selection: $preferences.outputRendering) {
        ForEach(OutputRendering.allCases) { Text($0.title).tag($0) }
      }
      .accessibilityIdentifier("settings.output-rendering")
      Picker("Content width", selection: $preferences.contentWidth) {
        ForEach(TranscriptContentWidth.allCases) { Text($0.title).tag($0) }
      }
      .accessibilityIdentifier("settings.content-width")
      if preferences.style == .cli {
        LabeledContent("CLI font size") {
          Stepper(
            "\(Int(preferences.fontSize)) pt", value: $preferences.fontSize,
            in: TranscriptAppearance.fontSizes, step: 1)
        }
        .accessibilityIdentifier("settings.cli-font-size")
      }
    } header: {
      Text("Transcript")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text(
          preferences.style == .cli
            ? "CLI shows the conversation like a terminal. Copy, Fork and other actions appear "
              + "on \(Self.revealGesture)."
            : "Chat shows your messages in bubbles on the right.")
        Text(preferences.outputRendering.detail)
        Text("Output rendering and width are remembered separately for each style.")
        ForEach(preferences.readErrors, id: \.description) { error in
          Label(error.description, systemImage: "exclamationmark.triangle")
            .foregroundStyle(Theme.warning)
        }
      }
    }
  }
}

extension TranscriptSettingsSection {
  /// How a CLI block's actions are revealed on this platform.
  static var revealGesture: String {
    #if os(macOS)
      "hover"
    #else
      "long press"
    #endif
  }
}

/// The key window's transcript controls, for the View menu and the session title menu. It holds
/// no closures, so a value published on every update compares equal to the last one; a fresh
/// closure each update kept the iPhone title menu rebuilding (a busy loop).
public struct TranscriptWindowControls: Equatable {
  /// The window's style.
  public var style: TranscriptStyle
  /// The device preferences (output rendering, width).
  public let preferences: TranscriptPreferences
  let window: TranscriptWindowStyleStore

  /// Sets the window's style without changing the device default.
  /// - Parameter style: The style.
  @MainActor public func setStyle(_ style: TranscriptStyle) {
    window.setStyle(style == preferences.style ? "" : style.rawValue)
  }

  /// Equal when they show the same style for the same window and preferences.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.style == rhs.style && lhs.preferences === rhs.preferences && lhs.window === rhs.window
  }
}

/// Writes a window's style to its scene storage; one per window, kept across updates.
@MainActor
final class TranscriptWindowStyleStore {
  /// The scene storage's binding, refreshed by the host on each update.
  var storage: Binding<String>?

  func setStyle(_ rawValue: String) { storage?.wrappedValue = rawValue }
}

extension FocusedValues {
  /// The key window's transcript controls.
  @Entry public var transcriptWindow: TranscriptWindowControls?
}

extension EnvironmentValues {
  /// This window's transcript controls, for in-window menus (the session title menu).
  @Entry var transcriptWindow: TranscriptWindowControls?
}

extension View {
  /// Applies the device's transcript preferences, with this window's own style when it chose
  /// one from the View menu (kept with the window's scene), and publishes the window's controls.
  /// - Parameter preferences: The device's transcript preferences.
  /// - Returns: The view.
  public func transcriptAppearance(from preferences: TranscriptPreferences) -> some View {
    modifier(TranscriptAppearanceHost(preferences: preferences))
  }
}

private struct TranscriptAppearanceHost: ViewModifier {
  let preferences: TranscriptPreferences
  /// The window's style; empty follows the device setting.
  @SceneStorage("omnigent.transcript-style") private var windowStyle = ""
  @State private var store = TranscriptWindowStyleStore()

  func body(content: Content) -> some View {
    let override = TranscriptStyle(rawValue: windowStyle)
    let appearance = preferences.appearance(style: override)
    store.storage = $windowStyle
    let controls = TranscriptWindowControls(
      style: appearance.style, preferences: preferences, window: store)
    return content
      .transcriptAppearance(appearance)
      .environment(\.transcriptWindow, controls)
      .focusedSceneValue(\.transcriptWindow, controls)
  }
}

/// View menu items: this window's transcript style, and the output rendering and content width
/// for that style. Add with `.commands { TranscriptCommands() }`.
public struct TranscriptCommands: Commands {
  @FocusedValue(\.transcriptWindow) private var window

  /// Creates the commands.
  public init() {}

  /// The menu items.
  public var body: some Commands {
    CommandGroup(before: .toolbar) {
      if let window {
        Picker(
          "Transcript Style",
          selection: Binding(get: { window.style }, set: { window.setStyle($0) })
        ) {
          ForEach(TranscriptStyle.allCases) { Text($0.title).tag($0) }
        }
        Picker(
          "Output Rendering",
          selection: Binding(
            get: { window.preferences.outputRendering(for: window.style) },
            set: { window.preferences.setOutputRendering($0, for: window.style) })
        ) {
          ForEach(OutputRendering.allCases) { Text($0.title).tag($0) }
        }
        Picker(
          "Content Width",
          selection: Binding(
            get: { window.preferences.contentWidth(for: window.style) },
            set: { window.preferences.setContentWidth($0, for: window.style) })
        ) {
          ForEach(TranscriptContentWidth.allCases) { Text($0.title).tag($0) }
        }
        Divider()
      }
    }
  }
}

/// Settings › Appearance as its own screen, for iPhone and iPad (the Mac has a Settings window):
/// Mode, Terminal theme, Transcript and Color theme.
public struct AppearanceSettingsView: View {
  private let preferences: ThemePreferences
  @Environment(\.dismiss) private var dismiss

  /// Creates the screen.
  /// - Parameter preferences: The device's appearance preferences.
  public init(preferences: ThemePreferences) {
    self.preferences = preferences
  }

  /// The screen.
  public var body: some View {
    NavigationStack {
      Form { ThemeSettingsView(preferences: preferences) }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
              .accessibilityIdentifier("appearance-done")
          }
        }
    }
    .accessibilityIdentifier("appearance-settings")
  }
}

/// Opens Settings › Appearance: a sheet on iPhone and iPad, the Settings window on the Mac.
/// Like ``TranscriptWindowControls`` it holds no closure, so it stays equal across updates.
public struct OpenAppearanceSettingsAction: Equatable {
  let presenter: AppearanceSettingsPresenter

  /// Opens the settings.
  @MainActor public func callAsFunction() { presenter.open?() }

  /// Equal for the same scene's presenter.
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.presenter === rhs.presenter }
}

/// Presents a scene's Appearance settings; the host refreshes ``open`` on each update.
@MainActor
final class AppearanceSettingsPresenter {
  var open: (@MainActor () -> Void)?
}

extension EnvironmentValues {
  /// Opens Settings › Appearance. Set by ``SwiftUICore/View/appearanceSettings(_:)``; `nil`
  /// hides the menu items.
  @Entry public var openAppearanceSettings: OpenAppearanceSettingsAction?
}

extension View {
  /// Applies the device's transcript preferences (see ``transcriptAppearance(from:)``) and
  /// makes Settings › Appearance reachable from the menus below.
  /// - Parameter preferences: The device's appearance preferences.
  /// - Returns: The view.
  public func appearanceSettings(_ preferences: ThemePreferences) -> some View {
    modifier(AppearanceSettingsHost(preferences: preferences))
  }
}

private struct AppearanceSettingsHost: ViewModifier {
  let preferences: ThemePreferences
  @State private var isPresented = false
  @State private var presenter = AppearanceSettingsPresenter()
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif

  func body(content: Content) -> some View {
    presenter.open = open
    return content
      .transcriptAppearance(from: preferences.transcript)
      .environment(\.openAppearanceSettings, OpenAppearanceSettingsAction(presenter: presenter))
      .sheet(isPresented: $isPresented) {
        AppearanceSettingsView(preferences: preferences)
      }
  }

  private var open: @MainActor () -> Void {
    #if os(macOS)
      { openSettings() }
    #else
      { isPresented = true }
    #endif
  }
}

/// What the session title menu's transcript items need, from the hosts above.
struct TranscriptTitleMenu: Equatable {
  let window: TranscriptWindowControls?
  let openAppearance: OpenAppearanceSettingsAction?
}

extension EnvironmentValues {
  /// This window's transcript controls and Appearance action, for the session title menu.
  var transcriptTitleMenu: TranscriptTitleMenu {
    TranscriptTitleMenu(window: transcriptWindow, openAppearance: openAppearanceSettings)
  }
}

/// The session title menu's Transcript Style switch and Appearance item, as plain buttons in
/// the caller's builder: a picker, or a view of its own, in the navigation bar's title menu
/// keeps UIKit rebuilding the menu on iPhone (a busy loop).
/// - Parameter menu: This window's controls.
/// - Returns: The items.
@MainActor @ViewBuilder
func transcriptTitleMenuItems(_ menu: TranscriptTitleMenu) -> some View {
  if let window = menu.window {
    let next = window.style.toggled
    Button(
      next == .cli ? "Use CLI Style" : "Use Chat Style",
      systemImage: next == .cli ? "apple.terminal" : "bubble.left.and.text.bubble.right"
    ) {
      window.setStyle(next)
    }
    .accessibilityIdentifier("title-menu-transcript-style")
  }
  if let openAppearance = menu.openAppearance {
    Button("Appearance\u{2026}", systemImage: "paintpalette") { openAppearance() }
      .accessibilityIdentifier("title-menu-appearance")
  }
}

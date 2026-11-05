public import SwiftUI

/// What the key window's conversation can do from the menu bar. Published by
/// ``ConversationScreen`` with `focusedSceneValue`; a `nil` action disables its item.
public struct SessionCommandActions {
  /// Send the draft (Return, or Command-Return).
  public var send: (@MainActor () -> Void)?
  /// Stop the running turn (Esc, or Command-Period).
  public var interrupt: (@MainActor () -> Void)?
  /// Scroll to the newest message (Command-Down Arrow).
  public var jumpToLatest: (@MainActor () -> Void)?
  /// Focus the composer (Control-Shift-L).
  public var focusComposer: (@MainActor () -> Void)?
  /// Show or hide the right panel (Option-Command-I).
  public var toggleInspector: (@MainActor () -> Void)?
  /// Select the previous session (Command-[).
  public var previousSession: (@MainActor () -> Void)?
  /// Select the next session (Command-]).
  public var nextSession: (@MainActor () -> Void)?
  /// Switch between chat and the harness terminal (Option-Command-\\).
  public var toggleViewMode: (@MainActor () -> Void)?

  /// Open the Changes tab in the right panel.
  public var openChanges: (@MainActor () -> Void)?
  /// Rename the session (Option-Command-R).
  public var rename: (@MainActor () -> Void)?
  /// Open the model picker (Control-Shift-M).
  public var chooseModel: (@MainActor () -> Void)?
  /// Switch to the next model (Control-Option-M).
  public var cycleModel: (@MainActor () -> Void)?
  /// Switch to the next reasoning effort (Control-Option-E).
  public var cycleEffort: (@MainActor () -> Void)?
  /// A pending request's Approve owns Command-Return, so Send Message shows no shortcut.
  public var approveOwnsCommandReturn = false

  /// Creates command actions.
  /// - Parameters:
  ///   - send: Send.
  ///   - interrupt: Stop.
  ///   - jumpToLatest: Scroll to latest.
  ///   - focusComposer: Focus the composer.
  ///   - toggleInspector: Toggle the inspector.
  ///   - previousSession: Previous session.
  ///   - nextSession: Next session.
  ///   - toggleViewMode: Switch chat and terminal.
  ///   - openChanges: Open the Changes tab.
  public init(
    send: (@MainActor () -> Void)? = nil, interrupt: (@MainActor () -> Void)? = nil,
    jumpToLatest: (@MainActor () -> Void)? = nil, focusComposer: (@MainActor () -> Void)? = nil,
    toggleInspector: (@MainActor () -> Void)? = nil,
    previousSession: (@MainActor () -> Void)? = nil,
    nextSession: (@MainActor () -> Void)? = nil, toggleViewMode: (@MainActor () -> Void)? = nil,
    openChanges: (@MainActor () -> Void)? = nil
  ) {
    self.send = send
    self.interrupt = interrupt
    self.jumpToLatest = jumpToLatest
    self.focusComposer = focusComposer
    self.toggleInspector = toggleInspector
    self.previousSession = previousSession
    self.nextSession = nextSession
    self.toggleViewMode = toggleViewMode
    self.openChanges = openChanges
  }
}

extension FocusedValues {
  /// The key window's conversation commands.
  @Entry public var sessionCommands: SessionCommandActions?
}

/// A Conversation menu for the menu bar: send, stop, jump to latest, focus the composer, the
/// inspector and session navigation. Add it with `.commands { OmnigentSessionCommands() }`.
public struct OmnigentSessionCommands: Commands {
  @FocusedValue(\.sessionCommands) private var actions
  @FocusedValue(\.paletteCommands) private var palette

  /// Creates the commands.
  public init() {}

  /// The menu.
  public var body: some Commands {
    CommandMenu("Navigate") {
      Button("Command Palette…") { palette?.openPalette() }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(palette == nil)
      Button("Keyboard Shortcuts…") { palette?.openShortcuts() }
        .keyboardShortcut("/", modifiers: .command)
        .disabled(palette == nil)
    }
    CommandMenu("Conversation") {
      Button("Send Message") { actions?.send?() }
        .keyboardShortcut(
          actions?.approveOwnsCommandReturn == true
            ? nil : KeyboardShortcut(.return, modifiers: .command)
        )
        .disabled(actions?.send == nil)
      Button("Stop Agent") { actions?.interrupt?() }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(actions?.interrupt == nil)
      Divider()
      Button("Rename Session\u{2026}") { actions?.rename?() }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(actions?.rename == nil)
      Button("Focus Composer") { actions?.focusComposer?() }
        .keyboardShortcut("l", modifiers: [.control, .shift])
        .disabled(actions?.focusComposer == nil)
      Button("Jump to Latest") { actions?.jumpToLatest?() }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .disabled(actions?.jumpToLatest == nil)
      Divider()
      Button("Choose Model\u{2026}") { actions?.chooseModel?() }
        .keyboardShortcut("m", modifiers: [.control, .shift])
        .disabled(actions?.chooseModel == nil)
      Button("Next Model") { actions?.cycleModel?() }
        .keyboardShortcut("m", modifiers: [.control, .option])
        .disabled(actions?.cycleModel == nil)
      Button("Next Reasoning Effort") { actions?.cycleEffort?() }
        .keyboardShortcut("e", modifiers: [.control, .option])
        .disabled(actions?.cycleEffort == nil)
      Divider()
      Button("Toggle Chat and Terminal") { actions?.toggleViewMode?() }
        .keyboardShortcut("\\", modifiers: [.command, .option])
        .disabled(actions?.toggleViewMode == nil)
      Button("Toggle Right Panel") { actions?.toggleInspector?() }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(actions?.toggleInspector == nil)
      Divider()
      Button("Previous Session") { actions?.previousSession?() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(actions?.previousSession == nil)
      Button("Next Session") { actions?.nextSession?() }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(actions?.nextSession == nil)
    }
  }
}

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
  public init(
    send: (@MainActor () -> Void)? = nil, interrupt: (@MainActor () -> Void)? = nil,
    jumpToLatest: (@MainActor () -> Void)? = nil, focusComposer: (@MainActor () -> Void)? = nil,
    toggleInspector: (@MainActor () -> Void)? = nil,
    previousSession: (@MainActor () -> Void)? = nil,
    nextSession: (@MainActor () -> Void)? = nil, toggleViewMode: (@MainActor () -> Void)? = nil
  ) {
    self.send = send
    self.interrupt = interrupt
    self.jumpToLatest = jumpToLatest
    self.focusComposer = focusComposer
    self.toggleInspector = toggleInspector
    self.previousSession = previousSession
    self.nextSession = nextSession
    self.toggleViewMode = toggleViewMode
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

  /// Creates the commands.
  public init() {}

  /// The menu.
  public var body: some Commands {
    CommandMenu("Conversation") {
      Button("Send Message") { actions?.send?() }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(actions?.send == nil)
      Button("Stop Agent") { actions?.interrupt?() }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(actions?.interrupt == nil)
      Divider()
      Button("Focus Composer") { actions?.focusComposer?() }
        .keyboardShortcut("l", modifiers: [.control, .shift])
        .disabled(actions?.focusComposer == nil)
      Button("Jump to Latest") { actions?.jumpToLatest?() }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .disabled(actions?.jumpToLatest == nil)
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

public import SwiftUI

/// Palette presentation actions for the focused window or iPad scene.
public struct PaletteCommandActions {
  /// Open the command palette.
  public var openPalette: @MainActor () -> Void
  /// Open grouped keyboard help.
  public var openShortcuts: @MainActor () -> Void

  /// Creates scene-local presentation actions.
  public init(
    openPalette: @escaping @MainActor () -> Void, openShortcuts: @escaping @MainActor () -> Void
  ) {
    self.openPalette = openPalette
    self.openShortcuts = openShortcuts
  }
}

extension FocusedValues {
  /// The focused scene's palette and shortcut help.
  @Entry public var paletteCommands: PaletteCommandActions?
}

extension View {
  /// Adds the palette and shortcut sheet to a window's root.
  /// - Parameters:
  ///   - state: Loaded sessions and configured servers.
  ///   - actions: Window-local navigation.
  ///   - initiallyPresented: Show the palette immediately, for component scenarios.
  /// - Returns: The root with scene commands and presentation attached.
  public func commandPalette(
    state: PaletteViewState, actions: PaletteActions, initiallyPresented: Bool = false
  ) -> some View {
    modifier(
      PalettePresentation(state: state, actions: actions, initiallyPresented: initiallyPresented))
  }
}

private struct PalettePresentation: ViewModifier {
  let state: PaletteViewState
  let actions: PaletteActions
  let initiallyPresented: Bool
  @State private var showsPalette = false
  @State private var showsShortcuts = false
  @State private var focusedCommands = FocusedSessionCommandsBox()
  @State private var capturedCommands = SessionCommandActions()
  @State private var pendingTarget: PaletteTarget?
  @State private var paletteRelay = FocusedActionsRelay<PaletteCommandActions>()

  func body(content: Content) -> some View {
    content
      // Reading the focused session commands here would re-render this modifier whenever it
      // republishes its own focused value, which never settles; a leaf view records them instead.
      .background { FocusedSessionCommandsReader(box: focusedCommands) }
      .focusedSceneValue(
        \.paletteCommands,
        paletteRelay.publish(
          PaletteCommandActions(openPalette: open, openShortcuts: { showsShortcuts = true }))
      )
      .sheet(isPresented: $showsPalette, onDismiss: executePending) {
        CommandPalette(state: state, commands: entries, search: actions.search) { target in
          pendingTarget = target
          showsPalette = false
        }
      }
      .sheet(isPresented: $showsShortcuts) { KeyboardShortcutsSheet() }
      .onAppear { if initiallyPresented { open() } }
      .onChange(of: initiallyPresented) { _, presented in if presented { open() } }
  }

  private func open() {
    capturedCommands = focusedCommands.commands ?? SessionCommandActions()
    showsPalette = true
  }

  private func executePending() {
    guard let target = pendingTarget else { return }
    pendingTarget = nil
    switch target {
    case .composer: capturedCommands.focusComposer?()
    case .toggleTerminal: capturedCommands.toggleViewMode?()
    case .changes: capturedCommands.openChanges?()
    case .toggleInspector: capturedCommands.toggleInspector?()
    default: actions.perform(target)
    }
  }

  private var entries: [PaletteEntry] {
    PaletteCatalog.entries(state: state, commands: capturedCommands)
  }
}

/// The latest focused session commands, deliberately unobserved so updates don't re-render the root.
@MainActor
private final class FocusedSessionCommandsBox {
  var commands: SessionCommandActions?
}

private struct FocusedSessionCommandsReader: View {
  let box: FocusedSessionCommandsBox
  @FocusedValue(\.sessionCommands) private var sessionCommands

  var body: some View {
    box.commands = sessionCommands
    return Color.clear.accessibilityHidden(true)
  }
}

import OmnigentPlatform
public import SwiftUI

/// Palette presentation actions for the focused window or iPad scene.
public struct PaletteCommandActions {
  /// Open the command palette.
  public var openPalette: @MainActor () -> Void
  /// Open grouped keyboard help.
  public var openShortcuts: @MainActor () -> Void
  /// Open the palette scoped to sessions, searching by name (Option-Command-S).
  public var findSession: @MainActor () -> Void

  /// Creates scene-local presentation actions.
  public init(
    openPalette: @escaping @MainActor () -> Void, openShortcuts: @escaping @MainActor () -> Void,
    findSession: @escaping @MainActor () -> Void = {}
  ) {
    self.openPalette = openPalette
    self.openShortcuts = openShortcuts
    self.findSession = findSession
  }
}

extension FocusedValues {
  /// The focused scene's palette and shortcut help.
  @Entry public var paletteCommands: PaletteCommandActions?
}

/// Opens the window's command palette (the sidebar's Search). It holds no closure, so it stays
/// equal across updates.
public struct OpenCommandPaletteAction: Equatable {
  let presenter: PalettePresenter

  /// Opens the palette.
  @MainActor public func callAsFunction() { presenter.open?() }

  /// Equal for the same window's presenter.
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.presenter === rhs.presenter }
}

/// Presents a window's palette; the modifier refreshes ``open`` on each update.
@MainActor
final class PalettePresenter {
  var open: (@MainActor () -> Void)?
}

extension EnvironmentValues {
  /// Opens the command palette; `nil` outside a window with one.
  @Entry public var openCommandPalette: OpenCommandPaletteAction?
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
    commandPalette(
      state: { state }, actions: actions, initiallyPresented: initiallyPresented)
  }

  /// Adds the palette and shortcut sheet to a window's root, making its state only while the
  /// palette shows, so the root does not rebuild every session's entry on each list change.
  /// - Parameters:
  ///   - state: Makes the loaded sessions and configured servers.
  ///   - actions: Window-local navigation.
  ///   - initiallyPresented: Show the palette immediately, for component scenarios.
  /// - Returns: The root with scene commands and presentation attached.
  public func commandPalette(
    state: @escaping @MainActor () -> PaletteViewState, actions: PaletteActions,
    initiallyPresented: Bool = false
  ) -> some View {
    modifier(
      PalettePresentation(state: state, actions: actions, initiallyPresented: initiallyPresented))
  }
}

/// One showing of the palette: its starting scope and the commands focused when it opened. An
/// item, so the sheet is built from these rather than from state written just before it.
private struct PaletteOpening: Identifiable {
  let scope: PaletteScope
  let commands: SessionCommandActions

  var id: PaletteScope { scope }
}

private struct PalettePresentation: ViewModifier {
  let state: @MainActor () -> PaletteViewState
  let actions: PaletteActions
  let initiallyPresented: Bool
  @State private var palette: PaletteOpening?
  @State private var showsShortcuts = false
  @State private var focusedCommands = FocusedSessionCommandsBox()
  @State private var capturedCommands = SessionCommandActions()
  @State private var pendingTarget: PaletteTarget?
  @State private var paletteRelay = FocusedActionsRelay<PaletteCommandActions>()
  @State private var presenter = PalettePresenter()

  func body(content: Content) -> some View {
    presenter.open = { open(.all) }
    return
      content
      .environment(\.openCommandPalette, OpenCommandPaletteAction(presenter: presenter))
      // Reading the focused session commands here would re-render this modifier whenever it
      // republishes its own focused value, which never settles; a leaf view records them instead.
      .background { FocusedSessionCommandsReader(box: focusedCommands) }
      .background { ShortcutAliases(perform: actions.perform) }
      #if DEBUG
        .perfHooks(["palette", "palette.close"]) { hook in
          if hook == "palette" { open(.all) } else { palette = nil }
        }
      #endif
      .focusedSceneValue(
        \.paletteCommands,
        paletteRelay.publish(
          PaletteCommandActions(
            openPalette: { open(.all) }, openShortcuts: { showsShortcuts = true },
            findSession: { open(.sessions) }))
      )
      .sheet(item: $palette, onDismiss: executePending) { opening in
        let state = state()
        CommandPalette(
          state: state, commands: PaletteCatalog.entries(state: state, commands: opening.commands),
          findsSessions: opening.scope == .sessions, search: actions.search
        ) { target in
          pendingTarget = target
          palette = nil
        }
      }
      .sheet(isPresented: $showsShortcuts) { KeyboardShortcutsSheet() }
      .onAppear { if initiallyPresented { open(.all) } }
      .onChange(of: initiallyPresented) { _, presented in if presented { open(.all) } }
  }

  private func open(_ scope: PaletteScope) {
    capturedCommands = focusedCommands.commands ?? SessionCommandActions()
    palette = PaletteOpening(scope: scope, commands: capturedCommands)
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

/// The web's keys for actions whose menu items keep the Mac's own keys: Option-Command-[ for the
/// sidebar and Option-Shift-Command-[ and ] for the split view's panes. A leaf, so reading the
/// focused tab commands re-renders only it.
private struct ShortcutAliases: View {
  let perform: @MainActor (PaletteTarget) -> Void
  @FocusedValue(\.tabCommands) private var tabs

  var body: some View {
    // iPad binds them too, for a hardware keyboard.
    Group {
      Button("Toggle Sidebar") { perform(.toggleSidebar) }
        .keyboardShortcut(AppShortcuts.toggleSidebarAlias)
      // Shift turns [ into {, and a binding on [ itself also takes Option-Command-[, which would
      // leave a split window with no way to toggle its sidebar.
      focus(.leading, KeyboardShortcut("{", modifiers: [.command, .option]))
      focus(.trailing, KeyboardShortcut("}", modifiers: [.command, .option]))
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private func focus(_ pane: TabPane, _ shortcut: KeyboardShortcut) -> some View {
    Button(pane == .leading ? "Focus Previous Pane" : "Focus Next Pane") {
      tabs?.focusPane?(pane)
    }
    .keyboardShortcut(shortcut)
    .disabled(tabs?.focusPane == nil)
  }
}

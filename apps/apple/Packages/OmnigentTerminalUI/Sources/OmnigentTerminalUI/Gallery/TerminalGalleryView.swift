public import SwiftUI

/// Every terminal surface state against fake connections, for previews, screenshots and manual
/// testing. Nothing here talks to a server.
public struct TerminalGalleryView: View {
  /// A gallery page.
  public enum Page: String, CaseIterable, Identifiable, Sendable {
    /// An interactive echo shell.
    case echo
    /// A synthesized harness TUI (alternate screen, mouse, truecolor).
    case harnessTUI
    /// The recorded embedded Omnigent REPL TUI.
    case recordedTUI
    /// Connecting, reconnecting, closed, failed and read-only states.
    case states
    /// The terminal list with create, close and attach.
    case list
    /// Appearance settings.
    case settings

    /// The stable identity.
    public var id: String { rawValue }

    /// The tab title.
    public var title: String {
      switch self {
      case .echo: "Echo shell"
      case .harnessTUI: "Harness TUI"
      case .recordedTUI: "Recorded REPL"
      case .states: "States"
      case .list: "Terminals"
      case .settings: "Settings"
      }
    }
  }

  @State private var page: Page
  /// Created once the view appears, not in `init`: SwiftUI re-runs `init` often, and each
  /// model owns live surfaces.
  @State private var model: TerminalGalleryModel?

  /// A gallery opened on `initialPage`.
  public init(initialPage: Page = .echo) {
    _page = State(initialValue: initialPage)
  }

  /// The view's content.
  public var body: some View {
    VStack(spacing: 0) {
      Picker("Page", selection: $page) {
        ForEach(Page.allCases) { page in Text(page.title).tag(page) }
      }
      .pickerStyle(.segmented)
      .padding(8)
      if let model {
        content(model)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .task { model = TerminalGalleryModel() }
      }
    }
  }

  @ViewBuilder
  private func content(_ model: TerminalGalleryModel) -> some View {
    switch page {
    case .echo:
      gallerySurface(model.echo)
    case .harnessTUI:
      gallerySurface(model.harness)
    case .recordedTUI:
      gallerySurface(model.recorded)
    case .states:
      TerminalStatesGrid(model: model)
    case .list:
      TerminalListDemo(model: model)
    case .settings:
      TerminalSettingsView()
    }
  }

  @ViewBuilder
  private func gallerySurface(_ result: Result<TerminalSurfaceController, GhosttyError>)
    -> some View
  {
    switch result {
    case .success(let controller): SessionTerminalView(controller: controller)
    case .failure(let error): TerminalUnavailableView(message: error.description)
    }
  }
}

/// The gallery's fake connections and their surfaces, created once.
@MainActor
@Observable
final class TerminalGalleryModel {
  let echoConnection = EchoTerminalConnection()
  let harnessConnection = EchoTerminalConnection(prompt: "$ ", banner: "harness")
  // Every surface is created exactly once, here. A connection's output stream has a single
  // consumer, so a second controller for the same connection would steal its bytes.
  @ObservationIgnored private(set) var echo: Result<TerminalSurfaceController, GhosttyError>
  @ObservationIgnored private(set) var harness: Result<TerminalSurfaceController, GhosttyError>
  @ObservationIgnored private(set) var recorded: Result<TerminalSurfaceController, GhosttyError>
  @ObservationIgnored private(set) var states:
    [(String, Result<TerminalSurfaceController, GhosttyError>)]

  init() {
    echo = .failure(.surfaceCreationFailed)
    harness = .failure(.surfaceCreationFailed)
    recorded = .failure(.surfaceCreationFailed)
    states = []
    echo = make(echoConnection)
    harness = makeHarness()
    recorded = makeRecorded()
    states = makeStates()
    for item in listItems { listControllers[item.id] = makeListController(for: item) }
  }

  var listItems: [TerminalListItem] = [
    TerminalListItem(
      id: "terminal_claude_main", title: "claude · main", status: .active, isAgentTerminal: true),
    TerminalListItem(
      id: "terminal_zsh_u-4f2k9q", title: "zsh · u-4f2k9q", status: .idle, isAgentTerminal: false),
    TerminalListItem(
      id: "terminal_bash_u-0c1d2e", title: "bash · u-0c1d2e", status: .exited,
      isAgentTerminal: false),
  ]
  var listSelection: TerminalListItem.ID? = "terminal_zsh_u-4f2k9q"
  @ObservationIgnored private var listControllers:
    [String: Result<TerminalSurfaceController, GhosttyError>] =
      [:]

  func listController(for id: String) -> Result<TerminalSurfaceController, GhosttyError> {
    listControllers[id] ?? .failure(.surfaceCreationFailed)
  }

  private func makeListController(for item: TerminalListItem) -> Result<
    TerminalSurfaceController, GhosttyError
  > {
    let connection = EchoTerminalConnection(
      prompt: "\(item.title.split(separator: " ").first ?? "sh")$ ",
      banner: "Attached to \(item.title)")
    let controller = make(connection)
    if item.status == .exited { connection.simulateExit() }
    return controller
  }

  func create(_ shell: String) {
    let digits = String(UInt64.random(in: 0..<2_176_782_336), radix: 36)
    let key = "u-" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    let item = TerminalListItem(
      id: "terminal_\(shell)_\(key)", title: "\(shell) · \(key)", status: .idle,
      isAgentTerminal: false)
    listItems.append(item)
    listControllers[item.id] = makeListController(for: item)
    listSelection = item.id
  }

  func close(_ id: String) {
    listItems.removeAll { $0.id == id }
    listControllers[id] = nil
    if listSelection == id { listSelection = listItems.first?.id }
  }

  private func make(_ connection: any TerminalConnection) -> Result<
    TerminalSurfaceController, GhosttyError
  > {
    do {
      return .success(try TerminalSurfaceController(connection: connection))
    } catch {
      return .failure(error)
    }
  }

  private func makeHarness() -> Result<TerminalSurfaceController, GhosttyError> {
    let result = make(harnessConnection)
    guard case .success(let controller) = result else { return result }
    let connection = harnessConnection
    // Draw the full-screen demo once the view has laid out, at the real grid size, as a TUI
    // redraws on its first resize.
    Task {
      while controller.gridSize == nil {
        do {
          try await Task.sleep(for: .milliseconds(50))
        } catch {
          return
        }
      }
      let grid = controller.gridSize
      connection.emit(
        Array(
          TerminalDemoContent.harnessTUI(columns: grid?.columns ?? 80, rows: grid?.rows ?? 24)
            .utf8))
    }
    return result
  }

  private func makeRecorded() -> Result<TerminalSurfaceController, GhosttyError> {
    do {
      return make(try ReplayTerminalConnection.recordedReplTUI())
    } catch {
      return .failure(.invalidConfiguration(["\(error)"]))
    }
  }

  private func makeStates() -> [(String, Result<TerminalSurfaceController, GhosttyError>)] {
    let reconnecting = EchoTerminalConnection()
    let ended = EchoTerminalConnection()
    let failed = EchoTerminalConnection()
    let viewer = EchoTerminalConnection(readOnly: true)
    let results = [
      ("Reconnecting", make(reconnecting)),
      ("Terminal ended", make(ended)),
      ("Sign-in required", make(failed)),
      ("Read-only viewer", make(viewer)),
    ]
    reconnecting.simulateDrop()
    ended.simulateExit()
    failed.simulateFailure(
      TerminalFailure(
        message: "Sign in again to attach to this terminal: the server answered HTTP 401",
        requiresSignIn: true))
    viewer.emit(Array("\r\nOnly the session owner can type here.\r\n".utf8))
    return results
  }
}

/// Four small terminals, one per non-happy state.
private struct TerminalStatesGrid: View {
  let model: TerminalGalleryModel

  var body: some View {
    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
      let states = model.states
      ForEach(0..<2, id: \.self) { row in
        GridRow {
          ForEach(0..<2, id: \.self) { column in
            let index = row * 2 + column
            if index < states.count {
              VStack(alignment: .leading, spacing: 4) {
                Text(states[index].0).font(.caption.weight(.semibold))
                switch states[index].1 {
                case .success(let controller): SessionTerminalView(controller: controller)
                case .failure(let error): TerminalUnavailableView(message: error.description)
                }
              }
            }
          }
        }
      }
    }
    .padding(8)
  }
}

/// The terminal list beside the attached terminal.
private struct TerminalListDemo: View {
  @Bindable var model: TerminalGalleryModel

  var body: some View {
    NavigationSplitView {
      TerminalListView(
        items: model.listItems, shellChoices: ["zsh", "bash"], canEdit: true, errorMessage: nil,
        selection: $model.listSelection, onCreate: { model.create($0) },
        onClose: { model.close($0) }
      )
      .navigationTitle("Terminals")
      .navigationSplitViewColumnWidth(min: 240, ideal: 280)
    } detail: {
      if let id = model.listSelection {
        switch model.listController(for: id) {
        case .success(let controller): SessionTerminalView(controller: controller).id(id)
        case .failure(let error): TerminalUnavailableView(message: error.description)
        }
      } else {
        ContentUnavailableView("No terminal selected", systemImage: "terminal")
      }
    }
  }
}

#Preview("Echo shell") {
  TerminalGalleryView(initialPage: .echo).frame(width: 800, height: 520)
}

#Preview("Harness TUI") {
  TerminalGalleryView(initialPage: .harnessTUI).frame(width: 900, height: 600)
}

#Preview("States") {
  TerminalGalleryView(initialPage: .states).frame(width: 900, height: 600)
}

#Preview("Terminal list") {
  TerminalGalleryView(initialPage: .list).frame(width: 1000, height: 600)
}

public import SwiftUI

/// Hosts the controller's platform view in SwiftUI. The same view instance is reused, so the
/// screen and scrollback survive SwiftUI re-renders.
struct TerminalSurfaceRepresentable {
  let controller: TerminalSurfaceController
}

#if os(macOS)
  extension TerminalSurfaceRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalSurfaceNSView { controller.view }
    func updateNSView(_ view: TerminalSurfaceNSView, context: Context) {}
  }
#else
  extension TerminalSurfaceRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalSurfaceUIView { controller.view }
    func updateUIView(_ view: TerminalSurfaceUIView, context: Context) {}
  }
#endif

/// Creates a surface controller once per view identity.
@MainActor
@Observable
final class TerminalControllerHolder {
  var result: Result<TerminalSurfaceController, GhosttyError>?

  func load(_ connection: any TerminalConnection) {
    guard result == nil else { return }
    do {
      result = .success(try TerminalSurfaceController(connection: connection))
    } catch {
      result = .failure(error)
    }
  }
}

/// An attached terminal: the libghostty surface plus its connection status, find bar, read-only
/// badge and clipboard consent. Drops into any SwiftUI container; the session view shows it as
/// the "Terminal" mode of a native-harness session, and the terminal list shows it for shells.
///
/// Prefer ``init(controller:)`` with a controller the session store keeps: switching away and
/// back then keeps the screen and scrollback. ``init(connection:)`` owns its controller and
/// starts blank each time the view is recreated.
public struct SessionTerminalView: View {
  private enum Source {
    case controller(TerminalSurfaceController)
    case connection(any TerminalConnection)
  }

  private let source: Source
  @State private var holder = TerminalControllerHolder()
  @Environment(\.colorScheme) private var colorScheme

  /// A view of an existing controller.
  public init(controller: TerminalSurfaceController) {
    source = .controller(controller)
  }

  /// A view that creates its own controller for `connection`.
  public init(connection: any TerminalConnection) {
    source = .connection(connection)
  }

  /// The view's content.
  public var body: some View {
    Group {
      switch source {
      case .controller(let controller):
        AttachedTerminal(controller: controller)
      case .connection(let connection):
        switch holder.result {
        case .success(let controller):
          AttachedTerminal(controller: controller)
        case .failure(let error):
          TerminalUnavailableView(message: error.description)
        case nil:
          ProgressView().onAppear { holder.load(connection) }
        }
      }
    }
    .onChange(of: colorScheme, initial: true) { _, scheme in
      applyColorScheme(scheme)
    }
  }

  private func applyColorScheme(_ scheme: ColorScheme) {
    let controller: TerminalSurfaceController
    switch (source, holder.result) {
    case (.controller(let value), _): controller = value
    case (.connection, .success(let value)): controller = value
    case (.connection, .failure), (.connection, nil): return
    }
    var appearance = controller.runtime.appearance
    appearance.colorScheme = scheme == .dark ? .dark : .light
    do {
      try controller.runtime.update(appearance: appearance)
    } catch {
      controller.report(error.description)
    }
  }
}

/// The surface with its overlays.
private struct AttachedTerminal: View {
  let controller: TerminalSurfaceController

  var body: some View {
    TerminalSurfaceRepresentable(controller: controller)
      .background(Color(white: controller.runtime.appearance.colorScheme == .dark ? 0.04 : 1))
      .overlay(alignment: .top) {
        VStack(spacing: 8) {
          if controller.search != nil {
            TerminalFindBar(controller: controller)
          }
          if let pending = controller.pendingClipboard {
            ClipboardConsentBanner(controller: controller, pending: pending)
          }
          if let error = controller.lastError {
            TerminalErrorBanner(message: error) { controller.clearError() }
          }
        }
        .padding(8)
      }
      .overlay(alignment: .topTrailing) {
        if case .attached(readOnly: true) = controller.state {
          Label("Read-only", systemImage: "eye")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(8)
            .accessibilityLabel("Read-only terminal")
        }
      }
      .overlay {
        TerminalStatusOverlay(state: controller.state) {
          controller.connection.start()
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(controller.title ?? "Terminal")
  }
}

/// Shown when libghostty cannot start. Never a silent blank view.
struct TerminalUnavailableView: View {
  let message: String

  var body: some View {
    ContentUnavailableView(
      "Terminal unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
  }
}

/// A dismissible error line.
struct TerminalErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(message).font(.callout).lineLimit(3)
      Spacer(minLength: 0)
      Button("Dismiss", action: dismiss).buttonStyle(.borderless)
    }
    .padding(10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
  }
}

/// Asks before the remote program writes the local clipboard.
struct ClipboardConsentBanner: View {
  let controller: TerminalSurfaceController
  let pending: PendingClipboardWrite

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.on.clipboard")
        .accessibilityHidden(true)
      Text("The terminal copied \(pending.text.count) characters.")
        .font(.callout)
      Spacer(minLength: 0)
      Button("Copy") { controller.acceptPendingClipboard() }
        .buttonStyle(.borderedProminent)
      Button("Ignore") { controller.declinePendingClipboard() }
        .buttonStyle(.bordered)
    }
    .padding(10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
  }
}

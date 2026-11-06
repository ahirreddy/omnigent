public import SwiftUI

#if os(iOS)
  import UIKit
#endif

extension View {
  /// Presents the tab overview while `isPresented`: on iPhone and iPad the shown tab zooms out
  /// into Safari's grid of cards (``TabGridOverview``); on the Mac, the list sheet.
  /// - Parameters:
  ///   - isPresented: Whether the overview shows.
  ///   - state: The shown session's tabs.
  ///   - actions: What the tabs do.
  /// - Returns: The view, presenting the overview.
  public func tabOverview(
    isPresented: Binding<Bool>, state: TabsState, actions: TabActions
  ) -> some View {
    modifier(TabOverviewPresentation(isPresented: isPresented, state: state, actions: actions))
  }
}

/// Opens a window's tab overview from any tab-count button in it. The window presents the
/// overview above its tabs, so closing the tab whose button opened it keeps the overview open.
@MainActor
public final class TabOverviewPresenter {
  /// Shows the overview; the window sets it.
  public var open: (@MainActor () -> Void)?

  /// Creates a presenter.
  public init() {}
}

extension EnvironmentValues {
  /// The window's tab overview; `nil` lets ``TabSwitcherButton`` present its own.
  @Entry public var tabOverviewPresenter: TabOverviewPresenter?
}

struct TabOverviewPresentation: ViewModifier {
  @Binding var isPresented: Bool
  let state: TabsState
  let actions: TabActions

  #if os(iOS)
    @State private var showsGrid = false
    @State private var window = WindowReference()

    func body(content: Content) -> some View {
      content
        .background { WindowReader(reference: window) }
        .onChange(of: isPresented, initial: true) { _, shows in present(shows) }
        .fullScreenCover(isPresented: Binding(get: { showsGrid }, set: { if !$0 { close() } })) {
          TabGridOverview(state: state, actions: actions, dismiss: close)
            // The theme's control tint, set here: a full-screen cover does not inherit it.
            .tint(ThemeColor.controlTint)
        }
    }

    /// The grid covers the window at once, over a picture of the shown tab taken just before,
    /// so the zoom starts from what was on screen.
    private func present(_ shows: Bool) {
      guard shows != showsGrid else { return }
      if shows, let selected = state.selectedID, let window = window.window,
        let image = Self.picture(of: window)
      {
        TabThumbnails.shared.store(image, for: selected)
      }
      withoutAnimation { showsGrid = shows }
    }

    private func close() {
      withoutAnimation {
        showsGrid = false
        isPresented = false
      }
    }

    private func withoutAnimation(_ change: () -> Void) {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction, change)
    }

    /// The window as it shows now, small enough to keep (``TabThumbnails/scale(for:screenScale:)``).
    private static func picture(of window: UIWindow) -> CGImage? {
      let format = UIGraphicsImageRendererFormat()
      format.scale = TabThumbnails.shared.scale(
        for: window.bounds.size, screenScale: window.traitCollection.displayScale)
      format.opaque = true
      let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
        _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
      }
      return image.cgImage
    }
  #else
    func body(content: Content) -> some View {
      content.sheet(isPresented: $isPresented) {
        TabOverviewSheet(state: state, actions: actions) { isPresented = false }
      }
    }
  #endif
}

#if os(iOS)
  /// The window a view is in, read without touching any observed state.
  @MainActor
  final class WindowReference {
    weak var window: UIWindow?
  }

  /// Keeps ``WindowReference`` pointing at the window its view moves into.
  private struct WindowReader: UIViewRepresentable {
    let reference: WindowReference

    func makeUIView(context: Context) -> ReaderView { ReaderView(reference: reference) }

    func updateUIView(_ view: ReaderView, context: Context) {}

    final class ReaderView: UIView {
      private let reference: WindowReference

      init(reference: WindowReference) {
        self.reference = reference
        super.init(frame: .zero)
        isUserInteractionEnabled = false
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) { nil }

      override func didMoveToWindow() {
        super.didMoveToWindow()
        reference.window = window
      }
    }
  }
#endif

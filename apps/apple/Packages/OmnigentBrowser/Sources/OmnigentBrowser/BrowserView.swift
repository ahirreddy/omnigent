public import SwiftUI

/// A browser surface: optional toolbar plus the active engine's content, or an explicit
/// "engine unavailable" panel that offers the system engine.
public struct BrowserView: View {
  private let controller: BrowserController
  private let showsToolbar: Bool

  /// Creates the view. It activates the controller when it appears.
  public init(controller: BrowserController, showsToolbar: Bool = true) {
    self.controller = controller
    self.showsToolbar = showsToolbar
  }

  /// The view body.
  public var body: some View {
    VStack(spacing: 0) {
      if showsToolbar {
        BrowserToolbar(controller: controller)
        Divider()
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear { controller.activate() }
    .onChange(of: controller.preferences.engine) { controller.activate() }
  }

  private var content: some View {
    BrowserPageView(controller: controller)
  }
}

/// The page of a controller's tab with its interstitial and banners, or the engine-unavailable
/// panel.
struct BrowserPageView: View {
  let controller: BrowserController

  var body: some View {
    switch controller.content {
    case .idle:
      Color.clear
    case .tab(let tab):
      BrowserTabContent(tab: tab)
        .id(ObjectIdentifier(tab))
        .overlay {
          if let prompt = controller.presenter.interstitial(for: tab) {
            BrowserCertificateInterstitial(
              prompt: prompt, allowsProceeding: controller.presenter.allowsCertificateOverrides
            ) { proceed in
              controller.presenter.resolveInterstitial(for: tab, proceed: proceed)
            }
          }
        }
        .overlay(alignment: .top) {
          if let blocked = tab.state.lastBlockedPopup {
            BrowserBlockedPopupBanner(blocked: blocked) {
              controller.openBlockedPopup(blocked)
            } dismiss: {
              tab.state.dismissBlockedPopup()
            }
          }
        }
        .overlay(alignment: .bottom) {
          if let error = tab.state.lastError, !error.isCancellation {
            BrowserErrorBanner(error: error)
          }
        }
    case .engineUnavailable(let requested, let error):
      BrowserEngineUnavailableView(requested: requested, error: error, controller: controller)
    }
  }
}

/// Back, forward, reload/stop, address field, progress and engine picker.
struct BrowserToolbar: View {
  let controller: BrowserController
  @State private var address = ""
  @State private var addressError: BrowserError?

  var body: some View {
    let state = controller.tab?.state
    VStack(spacing: 4) {
      HStack(spacing: 8) {
        Button("Back", systemImage: "chevron.backward") { controller.tab?.goBack() }
          .disabled(state?.canGoBack != true)
        Button("Forward", systemImage: "chevron.forward") { controller.tab?.goForward() }
          .disabled(state?.canGoForward != true)
        if state?.isLoading == true {
          Button("Stop", systemImage: "xmark") { controller.tab?.stopLoading() }
        } else {
          Button("Reload", systemImage: "arrow.clockwise") { controller.tab?.reload() }
            .disabled(controller.tab == nil)
        }
        TextField("Address", text: $address)
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .onSubmit(submitAddress)
          .accessibilityIdentifier("browser.address")
        BrowserDownloadsButton(presenter: controller.presenter)
        BrowserEnginePicker(controller: controller)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      if let addressError {
        Text(addressError.localizedDescription)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      ProgressView(value: state?.isLoading == true ? state?.estimatedProgress ?? 0 : 0)
        .progressViewStyle(.linear)
        .opacity(state?.isLoading == true ? 1 : 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .onChange(of: state?.url, initial: true) { _, url in
      address = url?.absoluteString ?? controller.requestedURL?.absoluteString ?? ""
    }
  }

  private func submitAddress() {
    do {
      try controller.load(addressText: address)
      addressError = nil
    } catch {
      addressError = error
    }
  }
}

/// Menu for choosing the engine; unavailable engines are listed with their reason.
public struct BrowserEnginePicker: View {
  private let controller: BrowserController

  /// Creates the picker.
  public init(controller: BrowserController) {
    self.controller = controller
  }

  /// The view body.
  public var body: some View {
    Menu {
      ForEach(controller.offeredEngines) { kind in
        Button {
          controller.switchEngine(to: kind)
        } label: {
          if controller.activeEngine == kind {
            Label(kind.displayName, systemImage: "checkmark")
          } else {
            Text(kind.displayName)
          }
        }
      }
    } label: {
      Text(controller.activeEngine?.displayName ?? controller.preferences.engine.displayName)
    }
    .fixedSize()
    .accessibilityIdentifier("browser.enginePicker")
  }
}

/// Settings row for the persisted engine choice.
public struct BrowserEngineSettingsView: View {
  @Bindable private var preferences: BrowserPreferences
  private let provider: any BrowserEngineProvider

  /// Creates the settings row.
  public init(preferences: BrowserPreferences, provider: any BrowserEngineProvider) {
    self.preferences = preferences
    self.provider = provider
  }

  /// The view body.
  public var body: some View {
    Section {
      Picker("Browser engine", selection: $preferences.engine) {
        ForEach(provider.offeredEngines) { kind in
          Text(kind.displayName).tag(kind)
        }
      }
      .accessibilityIdentifier("settings.browserEngine")
      if case .unavailable(let error) = provider.availability(of: preferences.engine) {
        Text(error.localizedDescription)
          .font(.caption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Browser")
    } footer: {
      Text("Default: \(preferences.defaultEngine.displayName). Open browser panes switch too.")
    }
  }
}

struct BrowserEngineUnavailableView: View {
  let requested: BrowserEngineKind
  let error: BrowserError
  let controller: BrowserController

  var body: some View {
    ContentUnavailableView {
      Label("\(requested.displayName) is unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text(error.localizedDescription)
        .textSelection(.enabled)
    } actions: {
      if requested != .system {
        Button("Use \(BrowserEngineKind.system.displayName)") {
          controller.switchEngine(to: .system)
        }
        .buttonStyle(.borderedProminent)
      }
      Button("Retry") { controller.retry() }
    }
    .accessibilityIdentifier("browser.engineUnavailable")
  }
}

struct BrowserErrorBanner: View {
  let error: BrowserError

  var body: some View {
    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
      .font(.callout)
      .padding(8)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      .padding()
      .accessibilityIdentifier("browser.errorBanner")
  }
}

#if os(macOS)
  struct BrowserTabContent: NSViewRepresentable {
    let tab: any BrowserTab

    func makeNSView(context: Context) -> BrowserPageContainer {
      BrowserPageContainer(page: tab.platformView)
    }

    func updateNSView(_ nsView: BrowserPageContainer, context: Context) {}

    static func dismantleNSView(_ nsView: BrowserPageContainer, coordinator: ()) {
      nsView.release()
    }
  }
#else
  struct BrowserTabContent: UIViewRepresentable {
    let tab: any BrowserTab

    func makeUIView(context: Context) -> BrowserPageContainer {
      BrowserPageContainer(page: tab.platformView)
    }

    func updateUIView(_ uiView: BrowserPageContainer, context: Context) {}

    static func dismantleUIView(_ uiView: BrowserPageContainer, coordinator: ()) {
      uiView.release()
    }
  }
#endif

/// Holds a tab's page view for one host. A rebuild can briefly make a second host for the same
/// tab, which takes the page; when that host goes, the page returns to a host still in use
/// instead of leaving the screen blank.
final class BrowserPageContainer: BrowserPlatformView {
  private struct Weak { weak var container: BrowserPageContainer? }
  /// Each page's containers, the newest last.
  private static var containers: [ObjectIdentifier: [Weak]] = [:]

  private let page: BrowserPlatformView

  init(page: BrowserPlatformView) {
    self.page = page
    super.init(frame: .zero)
    Self.containers[ObjectIdentifier(page), default: []].append(Weak(container: self))
    adopt()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// Leaves the page's containers, handing the page to the newest other one.
  func release() {
    let key = ObjectIdentifier(page)
    let others = (Self.containers[key] ?? []).compactMap(\.container).filter { $0 !== self }
    Self.containers[key] = others.isEmpty ? nil : others.map { Weak(container: $0) }
    if page.superview === self { others.last?.adopt() }
  }

  private func adopt() {
    page.removeFromSuperview()
    page.frame = bounds
    #if os(macOS)
      page.autoresizingMask = [.width, .height]
    #else
      page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    #endif
    addSubview(page)
  }
}

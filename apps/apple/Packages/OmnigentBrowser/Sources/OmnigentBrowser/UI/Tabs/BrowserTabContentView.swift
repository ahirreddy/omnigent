public import SwiftUI

/// The content of one browser tab for the app's tab strip: toolbar (navigation, omnibox,
/// bookmark star, mute, zoom, downloads, profile chip, menu), bookmarks bar, find bar and the
/// page. Activates the model (creating or restoring its engine tab) when it appears.
public struct BrowserTabContentView: View {
  private let model: BrowserTabModel
  private let environment: BrowserEnvironment
  private let keyboardShortcuts: Bool
  @State private var sheet: BrowserTabSheet?
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  /// Creates the view.
  /// - Parameters:
  ///   - model: The tab.
  ///   - environment: The shared browser environment.
  ///   - keyboardShortcuts: Installs ⌘L, ⌘F, ⌘G, ⌘+/−/0, ⌘R, ⇧⌘R, ⌥⌘I, ⌘P, ⌥⌘U, ⌘D and ⌘Y
  ///     while the view is in a window. Turn off when `BrowserTabCommands` provides them.
  public init(
    model: BrowserTabModel, environment: BrowserEnvironment, keyboardShortcuts: Bool = true
  ) {
    self.model = model
    self.environment = environment
    self.keyboardShortcuts = keyboardShortcuts
  }

  /// The view body.
  public var body: some View {
    VStack(spacing: 0) {
      toolbar
        .zIndex(1)  // Omnibox suggestions draw over the page below.
      progress
      if environment.settings.showsBookmarksBar,
        !(environment.bookmarks(for: model.profileID).bar.children ?? []).isEmpty
      {
        BrowserBookmarksBar(
          store: environment.bookmarks(for: model.profileID), open: open,
          report: { model.lastError = $0 })
      }
      Divider()
      if model.find.isVisible {
        BrowserFindBar(model: model)
        Divider()
      }
      BrowserPageView(controller: model.controller)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
          if let error = model.lastError {
            BrowserTabErrorBanner(error: error) { model.dismissError() }
          }
        }
        #if os(iOS)
          .safeAreaInset(edge: .bottom, spacing: 0) {
            if sizeClass == .compact {
              BrowserTouchBottomBar(model: model, environment: environment, sheet: $sheet)
            }
          }
        #endif
    }
    .background {
      if keyboardShortcuts { BrowserTabShortcuts(model: model, sheet: $sheet) }
    }
    // Keyed by the model object: a reopened tab keeps its ID, so the view may be reused.
    .task(id: ObjectIdentifier(model)) { model.activate() }
    .onChange(of: environment.preferences.engine) { model.activate() }
    .focusedSceneValue(\.browserTab, model)
    .focusedSceneValue(\.browserTabSheet, $sheet)
    .sheet(item: $sheet) { sheet in sheetContent(sheet) }
    .accessibilityIdentifier("browser.tab")
  }

  @ViewBuilder private var toolbar: some View {
    #if os(iOS)
      BrowserTouchTopBar(
        model: model, environment: environment, sheet: $sheet, isCompact: sizeClass == .compact)
    #else
      BrowserTabToolbar(model: model, environment: environment, sheet: $sheet)
    #endif
  }

  @ViewBuilder private var progress: some View {
    ProgressView(value: model.isLoading ? max(0.05, model.estimatedProgress) : 0)
      .progressViewStyle(.linear)
      .frame(height: 2)
      .opacity(model.isLoading ? 1 : 0)
      .accessibilityIdentifier("browser.progress")
  }

  private func open(_ url: URL, newTab: Bool) {
    if newTab {
      environment.openTab(url: url, profileID: model.profileID, opener: model)
    } else {
      model.load(url)
    }
  }

  @ViewBuilder private func sheetContent(_ sheet: BrowserTabSheet) -> some View {
    switch sheet {
    case .history:
      BrowserHistoryView(store: environment.history(for: model.profileID), open: open) {
        self.sheet = .clearData
      }
    case .bookmarks:
      BrowserBookmarksManagerView(store: environment.bookmarks(for: model.profileID), open: open)
    case .clearData:
      BrowserClearDataView(environment: environment, profileID: model.profileID)
    case .profiles:
      BrowserProfileManagerView(environment: environment)
    case .siteSettings:
      BrowserSiteSettingsView(
        store: environment.presenter.permissionStore, profile: model.browserProfile)
    case .downloads:
      VStack(spacing: 0) {
        BrowserDownloadsView(
          center: environment.presenter.downloadCenter,
          settings: environment.presenter.downloadSettings,
          profileIdentifier: model.browserProfile.identifier)
        BrowserSheetDoneButton()
      }
      .browserSheetFrame(width: 420, height: 360)
    }
  }
}

/// Sheets a browser tab shows.
public enum BrowserTabSheet: String, Identifiable, Sendable {
  case history, bookmarks, clearData, profiles, siteSettings, downloads

  /// Identity.
  public var id: String { rawValue }
}

struct BrowserSheetDoneButton: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    HStack {
      Spacer()
      Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
    }
    .padding(10)
  }
}

struct BrowserTabErrorBanner: View {
  let error: BrowserError
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
        .lineLimit(3)
      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .font(.callout)
    .padding(8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .padding()
    .accessibilityIdentifier("browser.tab.errorBanner")
  }
}

/// The find bar: field, match count, previous/next, case toggle, done.
struct BrowserFindBar: View {
  let model: BrowserTabModel
  @FocusState private var focused: Bool

  var body: some View {
    @Bindable var find = model.find
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
      TextField("Find in page", text: $find.query)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 280)
        .focused($focused)
        .onSubmit { Task { await model.findNext(forward: true) } }
        .onChange(of: find.query) { Task { await model.findNext(forward: true) } }
        .accessibilityIdentifier("browser.find.field")
      Text(matchText)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("browser.find.count")
      Button("Previous", systemImage: "chevron.up") {
        Task { await model.findNext(forward: false) }
      }
      Button("Next", systemImage: "chevron.down") { Task { await model.findNext(forward: true) } }
      Toggle("Match Case", isOn: $find.caseSensitive)
        .toggleStyle(.button)
      Spacer()
      Button("Done") { model.hideFindBar() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("browser.find.done")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .onAppear { focused = true }
    .onChange(of: model.find.focusRequest) { focused = true }
    .accessibilityIdentifier("browser.find")
  }

  private var matchText: String {
    guard !model.find.query.isEmpty, let result = model.find.result else { return "" }
    guard result.matchFound else { return "No matches" }
    if let count = result.matchCount {
      return "\(result.activeMatch ?? 1) of \(count)"
    }
    return "Found"
  }
}

/// Hidden buttons that carry the tab's keyboard shortcuts.
struct BrowserTabShortcuts: View {
  let model: BrowserTabModel
  @Binding var sheet: BrowserTabSheet?

  var body: some View {
    ZStack {
      shortcut("Open Location", "l") { model.focusOmnibox() }
      shortcut("Find", "f") { model.showFindBar() }
      shortcut("Find Next", "g") { Task { await model.findNext(forward: true) } }
      shortcut("Find Previous", "g", [.command, .shift]) {
        Task { await model.findNext(forward: false) }
      }
      shortcut("Zoom In", "=") { model.zoomIn() }
      shortcut("Zoom In", "+") { model.zoomIn() }
      shortcut("Zoom Out", "-") { model.zoomOut() }
      shortcut("Actual Size", "0") { model.resetZoom() }
      shortcut("Reload", "r") { model.reload() }
      shortcut("Hard Reload", "r", [.command, .shift]) { model.reloadIgnoringCache() }
      shortcut("Developer Tools", "i", [.command, .option]) { model.showDevTools() }
      shortcut("Print", "p") { model.printPage() }
      shortcut("View Source", "u", [.command, .option]) { model.viewSource() }
      shortcut("Bookmark", "d") { model.toggleBookmark() }
      shortcut("History", "y") { sheet = .history }
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
  }

  private func shortcut(
    _ title: String, _ key: Character, _ modifiers: EventModifiers = .command,
    action: @escaping () -> Void
  ) -> some View {
    Button(title, action: action)
      .keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
  }
}

extension FocusedValues {
  /// The browser tab whose content has focus, for `BrowserTabCommands`.
  @Entry public var browserTab: BrowserTabModel?
  /// The focused browser tab's sheet, for `BrowserTabCommands`.
  @Entry public var browserTabSheet: Binding<BrowserTabSheet?>?
}

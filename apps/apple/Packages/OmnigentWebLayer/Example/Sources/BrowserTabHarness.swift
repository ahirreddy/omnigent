internal import AppKit
internal import Foundation
internal import Observation
internal import OmnigentBrowser
internal import SwiftUI

/// A window hosting `BrowserTabModel`s the way the app's tab strip will: one
/// `BrowserTabContentView` for the selected tab, plus a plain row of tab chips so screenshots
/// show each tab's favicon, title, profile and audio state. Proof scaffolding, not app UI.
@Observable
final class BrowserTabHarness {
  let environment: BrowserEnvironment
  @ObservationIgnored let window: NSWindow
  @ObservationIgnored let defaults: UserDefaults
  private(set) var tabs: [BrowserTabModel] = []
  var selectedID: UUID?
  @ObservationIgnored private let suiteName =
    "ai.omnigent.weblayer-example.tabs.\(UUID().uuidString)"

  init(kind: BrowserEngineKind, provider: any BrowserEngineProvider, directory: URL, title: String)
    throws
  {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw ProofFailure("Cannot create a defaults suite for the tab harness.")
    }
    self.defaults = defaults
    let presenter = BrowserPromptPresenter(
      permissionStore: BrowserPermissionStore(defaults: defaults),
      credentialStore: InMemoryBrowserCredentialStore(),
      downloadSettings: BrowserDownloadSettings(defaults: defaults),
      downloadCenter: BrowserDownloadCenter())
    environment = BrowserEnvironment(
      directory: directory, provider: provider,
      preferences: BrowserPreferences(defaults: defaults, defaultEngine: kind),
      presenter: presenter, defaults: defaults)
    window = NSWindow(
      contentRect: NSRect(x: 60, y: 60, width: 1100, height: 760),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    environment.onOpenTab = { [weak self] model, _ in self?.add(model) }
    environment.onSwitchToTab = { [weak self] id in self?.selectedID = id }
    environment.onCloseTab = { [weak self] model in self?.close(model) }
    window.contentView = NSHostingView(rootView: BrowserTabHarnessRoot(harness: self))
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
  }

  var selected: BrowserTabModel? { tabs.first { $0.id == selectedID } }

  func requireSelected() throws -> BrowserTabModel {
    guard let selected else { throw ProofFailure("The harness has no selected tab.") }
    return selected
  }

  @discardableResult
  func add(_ model: BrowserTabModel, select: Bool = true) -> BrowserTabModel {
    tabs.append(model)
    if select { selectedID = model.id }
    return model
  }

  @discardableResult
  func close(_ model: BrowserTabModel) -> BrowserTabRestoreState {
    let state = model.close()
    tabs.removeAll { $0.id == model.id }
    if selectedID == model.id { selectedID = tabs.last?.id }
    return state
  }

  func snapshot() -> BrowserSessionSnapshot {
    BrowserSessionSnapshot(tabs: tabs.map { $0.snapshotForRestore() }, selectedTabID: selectedID)
  }

  func tearDown() {
    for tab in tabs { tab.close() }
    tabs = []
    window.close()
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
  }
}

struct BrowserTabHarnessRoot: View {
  let harness: BrowserTabHarness

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        ForEach(harness.tabs) { tab in
          Button {
            harness.selectedID = tab.id
          } label: {
            HStack(spacing: 6) {
              if let image = tab.favicon?.image {
                image.resizable().frame(width: 14, height: 14).accessibilityHidden(true)
              } else {
                Image(systemName: "globe").frame(width: 14, height: 14).accessibilityHidden(true)
              }
              Text(tab.displayTitle).lineLimit(1).frame(maxWidth: 140)
              if tab.isAudible || tab.isMuted {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                  .accessibilityLabel(tab.isMuted ? "Muted" : "Playing audio")
              }
              if tab.isPinned {
                Image(systemName: "pin.fill").font(.caption2).accessibilityLabel("Pinned")
              }
              BrowserProfileAvatarView(profile: tab.profile, size: 14)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
              tab.id == harness.selectedID ? Color.primary.opacity(0.1) : Color.clear,
              in: RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
        }
        Spacer()
      }
      .padding(6)
      Divider()
      if let selected = harness.selected {
        BrowserTabContentView(model: selected, environment: harness.environment)
          .id(selected.id)
      } else {
        Color.clear
      }
    }
  }
}

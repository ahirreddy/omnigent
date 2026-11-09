public import SwiftUI

/// Back, forward, reload, omnibox with suggestions and bookmark star, mute, zoom, downloads,
/// profile chip and the tab menu.
struct BrowserTabToolbar: View {
  let model: BrowserTabModel
  let environment: BrowserEnvironment
  @Binding var sheet: BrowserTabSheet?

  var body: some View {
    HStack(spacing: 6) {
      BrowserBackButton(model: model)
      BrowserForwardButton(model: model)
      BrowserReloadButton(model: model)
      BrowserOmniboxField(model: model, environment: environment)
      if model.isAudible || model.isMuted {
        Button(
          model.isMuted ? "Unmute Tab" : "Mute Tab",
          systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        ) {
          model.toggleMute()
        }
        .accessibilityIdentifier("browser.mute")
      }
      if abs(model.zoomFactor - 1) > 0.001 {
        Button("\(Int((model.zoomFactor * 100).rounded()))%") { model.resetZoom() }
          .labelStyle(.titleOnly)
          .font(.caption.monospacedDigit())
          .help("Reset zoom")
          .accessibilityIdentifier("browser.zoom")
      }
      BrowserTabDownloadsButton(
        presenter: environment.presenter, profileIdentifier: model.browserProfile.identifier)
      BrowserProfileMenu(model: model, environment: environment, sheet: $sheet)
      BrowserTabMenu(model: model, environment: environment, sheet: $sheet)
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  }
}

/// The profile chip; it opens a list of profiles for "New Tab in Profile" and "Manage
/// Profiles…". A button with a popover, because menu labels cannot draw the chip.
struct BrowserProfileMenu: View {
  let model: BrowserTabModel
  let environment: BrowserEnvironment
  @Binding var sheet: BrowserTabSheet?
  @State private var showing = false

  var body: some View {
    Button {
      showing.toggle()
    } label: {
      BrowserProfileChip(profile: model.profile)
    }
    .buttonStyle(.plain)
    .help("Profile: \(model.profile?.name ?? "deleted")")
    .popover(isPresented: $showing, arrowEdge: .bottom) {
      BrowserProfileMenuContent(
        model: model, environment: environment, sheet: $sheet, close: { showing = false })
    }
    .accessibilityIdentifier("browser.profileChip")
  }
}

/// The profile chip's popover: a new tab in any profile, or the profile manager.
struct BrowserProfileMenuContent: View {
  let model: BrowserTabModel
  let environment: BrowserEnvironment
  @Binding var sheet: BrowserTabSheet?
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("New Tab in Profile").font(.caption).foregroundStyle(.secondary)
      ForEach(environment.profiles.profiles) { profile in
        Button {
          close()
          environment.openTab(url: nil, profileID: profile.id, opener: model)
        } label: {
          HStack {
            BrowserProfileAvatarView(profile: profile, size: 18)
            Text(profile.name)
            if profile.id == environment.profiles.defaultProfileID {
              Text("default").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("browser.profileMenu.\(profile.name)")
      }
      Divider()
      Button("Manage Profiles…") {
        close()
        sheet = .profiles
      }
      .buttonStyle(.plain)
    }
    .padding(12)
    .frame(minWidth: 220)
  }
}

/// Toolbar button for this profile's downloads.
struct BrowserTabDownloadsButton: View {
  let presenter: BrowserPromptPresenter
  let profileIdentifier: String
  @State private var showing = false

  var body: some View {
    let active = presenter.downloadCenter.items(profileIdentifier: profileIdentifier)
      .contains { !$0.state.isFinal }
    Button("Downloads", systemImage: active ? "arrow.down.circle.fill" : "arrow.down.circle") {
      showing.toggle()
    }
    .popover(isPresented: $showing) {
      BrowserDownloadsView(
        center: presenter.downloadCenter, settings: presenter.downloadSettings,
        profileIdentifier: profileIdentifier
      )
      .frame(width: 380, height: 320)
    }
    .accessibilityIdentifier("browser.downloads")
  }
}

/// The tab's overflow menu.
struct BrowserTabMenu: View {
  let model: BrowserTabModel
  let environment: BrowserEnvironment
  @Binding var sheet: BrowserTabSheet?

  var body: some View {
    @Bindable var settings = environment.settings
    Menu {
      Button("History") { sheet = .history }
      Button("Bookmarks") { sheet = .bookmarks }
      Button(model.isBookmarked ? "Remove Bookmark" : "Bookmark This Page") {
        model.toggleBookmark()
      }
      Toggle("Show Bookmarks Bar", isOn: $settings.showsBookmarksBar)
      Divider()
      Button("Find…") { model.showFindBar() }
      Menu("Zoom") {
        Button("Zoom In") { model.zoomIn() }
        Button("Zoom Out") { model.zoomOut() }
        Button("Actual Size") { model.resetZoom() }
      }
      Button(model.isMuted ? "Unmute Tab" : "Mute Tab") { model.toggleMute() }
      Button("Reload Ignoring Cache") { model.reloadIgnoringCache() }
      Divider()
      Button("Print…") { model.printPage() }
      Button("View Source") { model.viewSource() }
      #if os(macOS)
        // WebKit on iOS has no in-app inspector; Safari's Develop menu reaches the page.
        Button("Developer Tools") { model.showDevTools() }
      #endif
      Divider()
      Button("Downloads") { sheet = .downloads }
      Button("Site Permissions…") { sheet = .siteSettings }
      Button("Clear Browsing Data…") { sheet = .clearData }
      Button("Profiles…") { sheet = .profiles }
      if model.controller.offeredEngines.count > 1 { engineMenu }
      #if os(iOS)
        // Touch layouts have no ⌘W, and the iPhone has no tab strip.
        Divider()
        Button("Close Tab") { environment.pageClosed(model) }
          .accessibilityIdentifier("browser.closeTab")
      #endif
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityIdentifier("browser.tabMenu")
  }

  private var engineMenu: some View {
    Menu("Browser Engine") {
      ForEach(model.controller.offeredEngines) { kind in
        Button {
          model.controller.switchEngine(to: kind)
        } label: {
          if model.controller.activeEngine == kind {
            Label(kind.displayName, systemImage: "checkmark")
          } else {
            Text(kind.displayName)
          }
        }
      }
    }
  }
}

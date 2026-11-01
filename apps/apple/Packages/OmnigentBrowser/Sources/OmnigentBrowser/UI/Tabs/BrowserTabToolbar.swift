public import SwiftUI

/// Back, forward, reload, omnibox with suggestions and bookmark star, mute, zoom, downloads,
/// profile chip and the tab menu.
struct BrowserTabToolbar: View {
  let model: BrowserTabModel
  let environment: BrowserEnvironment
  @Binding var sheet: BrowserTabSheet?

  var body: some View {
    HStack(spacing: 6) {
      Button("Back", systemImage: "chevron.backward") { model.goBack() }
        .disabled(!model.canGoBack)
        .accessibilityIdentifier("browser.back")
      Button("Forward", systemImage: "chevron.forward") { model.goForward() }
        .disabled(!model.canGoForward)
        .accessibilityIdentifier("browser.forward")
      if model.isLoading {
        Button("Stop", systemImage: "xmark") { model.stopLoading() }
          .accessibilityIdentifier("browser.stop")
      } else {
        Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
          .disabled(model.tab == nil)
          .help("Reload (⇧⌘R reloads without the cache)")
          .accessibilityIdentifier("browser.reload")
      }
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

/// The address and search field. Shows the page URL; while editing, suggestions from history,
/// bookmarks and open tabs, plus go or search for what was typed.
struct BrowserOmniboxField: View {
  let model: BrowserTabModel
  let environment: BrowserEnvironment
  @State private var text = ""
  @State private var editing = false
  @State private var selected = 0
  @State private var error: BrowserError?
  @FocusState private var focused: Bool

  var body: some View {
    let suggestions = currentSuggestions
    HStack(spacing: 6) {
      if let image = model.favicon?.image {
        image.resizable().frame(width: 16, height: 16)
      } else {
        Image(systemName: model.url?.scheme == "https" ? "lock.fill" : "globe")
          .foregroundStyle(.secondary)
          .frame(width: 16, height: 16)
          .accessibilityLabel(model.url?.scheme == "https" ? "Secure" : "Page")
      }
      TextField("Search or enter address", text: $text)
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .focused($focused)
        .onSubmit { submit(suggestions) }
        .onKeyPress(.downArrow) {
          selected = min(selected + 1, max(0, suggestions.count - 1))
          return .handled
        }
        .onKeyPress(.upArrow) {
          selected = max(selected - 1, 0)
          return .handled
        }
        .onKeyPress(.escape) {
          revert()
          return .handled
        }
        .onChange(of: text) {
          if focused { editing = true }
          selected = 0
        }
        .accessibilityIdentifier("browser.omnibox")
      if let url = model.url, BrowserHistoryStore.isRecordable(url) {
        Button(
          model.isBookmarked ? "Remove Bookmark" : "Bookmark This Page",
          systemImage: model.isBookmarked ? "star.fill" : "star"
        ) {
          model.toggleBookmark()
        }
        .foregroundStyle(model.isBookmarked ? Color.accentColor : Color.secondary)
        .accessibilityIdentifier("browser.bookmarkStar")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(.quaternary.opacity(focused ? 0.9 : 0.6), in: Capsule())
    .overlay {
      if focused { Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5) }
    }
    .overlay(alignment: .topLeading) {
      if focused, editing, !suggestions.isEmpty {
        BrowserOmniboxSuggestionList(suggestions: suggestions, selected: selected) { suggestion in
          choose(suggestion)
        }
        .offset(y: 34)
      }
    }
    .zIndex(10)
    .onChange(of: model.url, initial: true) { revert() }
    .onChange(of: focused) { _, isFocused in
      if !isFocused { revert() }
    }
    .onChange(of: model.omniboxFocusRequest, initial: true) { _, request in
      if request > 0 { focused = true }
    }
    .popover(
      isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    ) {
      Text(error?.localizedDescription ?? "").padding()
    }
  }

  private var currentSuggestions: [BrowserOmniboxSuggestion] {
    guard editing else { return [] }
    return BrowserOmnibox.suggestions(
      for: text, searchEngine: environment.settings.searchEngine,
      history: environment.history(for: model.profileID),
      bookmarks: environment.bookmarks(for: model.profileID),
      openTabs: environment.openTabSummaries(excluding: model.id).filter {
        $0.profileID == model.profileID
      })
  }

  private func revert() {
    editing = false
    selected = 0
    let url = model.url
    text = url.map { $0.absoluteString == "about:blank" ? "" : $0.absoluteString } ?? ""
  }

  private func submit(_ suggestions: [BrowserOmniboxSuggestion]) {
    if editing, suggestions.indices.contains(selected), selected > 0 {
      choose(suggestions[selected])
      return
    }
    do {
      try model.submitOmnibox(text)
      editing = false
      focused = false
    } catch let failure {
      error = failure
    }
  }

  private func choose(_ suggestion: BrowserOmniboxSuggestion) {
    editing = false
    focused = false
    if case .openTab(let id) = suggestion.kind, let switchTo = environment.onSwitchToTab {
      switchTo(id)
      revert()
      return
    }
    model.load(suggestion.url, typed: suggestion.kind == .navigate)
  }
}

struct BrowserOmniboxSuggestionList: View {
  let suggestions: [BrowserOmniboxSuggestion]
  let selected: Int
  let choose: (BrowserOmniboxSuggestion) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
        Button {
          choose(suggestion)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: Self.icon(suggestion.kind))
              .frame(width: 16)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(suggestion.title).lineLimit(1)
            Text(suggestion.subtitle)
              .lineLimit(1)
              .foregroundStyle(.secondary)
              .font(.caption)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
          .background(
            index == selected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("browser.omnibox.suggestion.\(index)")
      }
    }
    .padding(4)
    .frame(minWidth: 420, maxWidth: 640, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .shadow(radius: 8, y: 4)
    .accessibilityIdentifier("browser.omnibox.suggestions")
  }

  private static func icon(_ kind: BrowserOmniboxSuggestion.Kind) -> String {
    switch kind {
    case .navigate: "globe"
    case .search: "magnifyingglass"
    case .history: "clock"
    case .bookmark: "star"
    case .openTab: "square.on.square"
    }
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
      VStack(alignment: .leading, spacing: 6) {
        Text("New Tab in Profile").font(.caption).foregroundStyle(.secondary)
        ForEach(environment.profiles.profiles) { profile in
          Button {
            showing = false
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
          showing = false
          sheet = .profiles
        }
        .buttonStyle(.plain)
      }
      .padding(12)
      .frame(minWidth: 220)
    }
    .accessibilityIdentifier("browser.profileChip")
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
      Button("Developer Tools") { model.showDevTools() }
      Divider()
      Button("Downloads") { sheet = .downloads }
      Button("Site Permissions…") { sheet = .siteSettings }
      Button("Clear Browsing Data…") { sheet = .clearData }
      Button("Profiles…") { sheet = .profiles }
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
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityIdentifier("browser.tabMenu")
  }
}

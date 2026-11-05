import SwiftUI

extension View {
  /// A Mac sheet's minimum size; iPhone and iPad sheets size themselves to the screen.
  func browserSheetFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
    #if os(macOS)
      frame(minWidth: minWidth, minHeight: minHeight)
    #else
      self
    #endif
  }

  /// A Mac sheet's fixed size; iPhone and iPad sheets size themselves to the screen.
  func browserSheetFrame(width: CGFloat, height: CGFloat? = nil) -> some View {
    #if os(macOS)
      frame(width: width, height: height)
    #else
      self
    #endif
  }
}

#if os(iOS)
  /// The browser tab's controls on iPad and iPhone, sized for touch. On iPad (regular width) one
  /// bar holds back, forward, reload, the address field, share, the profile and the tab menu,
  /// like Safari's iPad toolbar. On iPhone the address field and reload stay on top, and the
  /// rest moves to ``BrowserTouchBottomBar`` within thumb reach.
  struct BrowserTouchTopBar: View {
    let model: BrowserTabModel
    let environment: BrowserEnvironment
    @Binding var sheet: BrowserTabSheet?
    let isCompact: Bool

    var body: some View {
      HStack(spacing: isCompact ? 8 : 14) {
        if !isCompact {
          BrowserBackButton(model: model)
          BrowserForwardButton(model: model)
        }
        BrowserReloadButton(model: model)
        BrowserOmniboxField(model: model, environment: environment)
        if !isCompact {
          BrowserShareButton(model: model)
          BrowserProfileMenu(model: model, environment: environment, sheet: $sheet)
          BrowserTabMenu(model: model, environment: environment, sheet: $sheet)
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .font(.title3)
      .padding(.horizontal, isCompact ? 12 : 16)
      .padding(.vertical, 6)
    }
  }

  /// The iPhone's bottom toolbar: back, forward, share, bookmarks and the tab menu, as in
  /// Safari, floating over the page.
  struct BrowserTouchBottomBar: View {
    let model: BrowserTabModel
    let environment: BrowserEnvironment
    @Binding var sheet: BrowserTabSheet?

    var body: some View {
      HStack(spacing: 0) {
        BrowserBackButton(model: model).frame(maxWidth: .infinity)
        BrowserForwardButton(model: model).frame(maxWidth: .infinity)
        BrowserShareButton(model: model).frame(maxWidth: .infinity)
        Button("Bookmarks", systemImage: "book") { sheet = .bookmarks }
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier("browser.bookmarks")
        BrowserTabMenu(model: model, environment: environment, sheet: $sheet)
          .frame(maxWidth: .infinity)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .font(.title3)
      .frame(height: 50)
      .padding(.horizontal, 6)
      .glassEffect(.regular.interactive(), in: .capsule)
      .padding(.horizontal, 24)
      .padding(.bottom, 4)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("browser.bottomBar")
    }
  }

  /// Shares the page's address (Messages, Mail, Copy, Add to Reading List...).
  struct BrowserShareButton: View {
    let model: BrowserTabModel

    var body: some View {
      if let url = model.url, BrowserHistoryStore.isRecordable(url) {
        ShareLink(item: url, subject: Text(model.title), preview: SharePreview(model.displayTitle))
        {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("browser.share")
      } else {
        Button("Share", systemImage: "square.and.arrow.up") {}
          .disabled(true)
          .accessibilityIdentifier("browser.share")
      }
    }
  }
#endif

/// Goes back a page.
struct BrowserBackButton: View {
  let model: BrowserTabModel

  var body: some View {
    Button("Back", systemImage: "chevron.backward") { model.goBack() }
      .disabled(!model.canGoBack)
      .accessibilityIdentifier("browser.back")
  }
}

/// Goes forward a page.
struct BrowserForwardButton: View {
  let model: BrowserTabModel

  var body: some View {
    Button("Forward", systemImage: "chevron.forward") { model.goForward() }
      .disabled(!model.canGoForward)
      .accessibilityIdentifier("browser.forward")
  }
}

/// Stops a load, or reloads the page.
struct BrowserReloadButton: View {
  let model: BrowserTabModel

  var body: some View {
    if model.isLoading {
      Button("Stop", systemImage: "xmark") { model.stopLoading() }
        .accessibilityIdentifier("browser.stop")
    } else {
      Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
        .disabled(model.tab == nil)
        .help("Reload (⇧⌘R reloads without the cache)")
        .accessibilityIdentifier("browser.reload")
    }
  }
}

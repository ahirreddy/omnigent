public import SwiftUI

/// The browser tab's address row on iPhone and iPad: one row, sized for touch, around Safari's
/// address pill. On iPad (regular width) it holds back, forward, the pill, share, the profile
/// and the tab menu. On iPhone it stands in for the app's navigation bar: back to the session
/// list, the pill and the tab overview; the rest is in the bottom toolbar within thumb reach.
/// While the address is edited the pill takes the row.
struct BrowserTouchTopBar: View {
  let model: BrowserTabModel
  let environment: BrowserEnvironment
  @Binding var sheet: BrowserTabSheet?
  let isCompact: Bool
  /// Shows the app's session list (iPhone); `nil` where the app's navigation bar stays.
  var showSessions: (@MainActor () -> Void)?
  /// The app's tab overview button (iPhone).
  var tabsButton: AnyView?
  @State private var editingAddress = false

  var body: some View {
    HStack(spacing: isCompact ? 8 : 14) {
      if !editingAddress { leading }
      BrowserOmniboxField(
        model: model, environment: environment, style: .pill, isEditing: $editingAddress)
      if !editingAddress { trailing }
    }
    .labelStyle(.iconOnly)
    .padding(.horizontal, isCompact ? 12 : 16)
    .padding(.vertical, 6)
    .animation(.smooth(duration: 0.25), value: editingAddress)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("browser.addressBar")
  }

  @ViewBuilder private var leading: some View {
    if isCompact {
      if let showSessions {
        Button("Sessions", systemImage: "chevron.backward", action: showSessions)
          .buttonStyle(BrowserCircleButtonStyle())
          .accessibilityIdentifier("browser.sessions")
      }
    } else {
      HStack(spacing: 14) {
        BrowserBackButton(model: model)
        BrowserForwardButton(model: model)
      }
      .buttonStyle(.borderless)
      .tint(.primary)
      .font(.title3)
    }
  }

  @ViewBuilder private var trailing: some View {
    if isCompact {
      tabsButton?.buttonStyle(BrowserCircleButtonStyle())
    } else {
      HStack(spacing: 14) {
        BrowserShareButton(model: model)
        BrowserProfileMenu(model: model, environment: environment, sheet: $sheet)
        BrowserTabMenu(model: model, environment: environment, sheet: $sheet)
      }
      .buttonStyle(.borderless)
      .tint(.primary)
      .font(.title3)
    }
  }
}

/// A round button the pill's height on the system fill, like the pill itself.
private struct BrowserCircleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(.iconOnly)
      .font(.body.weight(.medium))
      .foregroundStyle(.primary)
      .frame(width: BrowserOmniboxField.pillHeight, height: BrowserOmniboxField.pillHeight)
      .background(.fill.tertiary, in: Circle())
      .contentShape(Circle())
      .opacity(configuration.isPressed ? 0.6 : 1)
  }
}

/// The pill's label while it is not being edited: the domain with a lock for HTTPS, or "Search
/// or enter website". The field underneath carries the full address for accessibility.
struct BrowserDomainLabel: View {
  let url: URL?

  var body: some View {
    let display = BrowserAddressDisplay(url: url)
    HStack(spacing: 4) {
      if display.isEmpty {
        Image(systemName: "magnifyingglass")
        Text("Search or enter website")
      } else {
        if display.isSecure {
          Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
        }
        Text(display.domain)
      }
    }
    .foregroundStyle(display.isEmpty ? .secondary : .primary)
    .lineLimit(1)
    .truncationMode(.middle)
    .accessibilityHidden(true)
  }
}

/// A thin line along the pill's bottom edge while the page loads, in the system blue as in
/// Safari (the theme's pink is kept for what needs the user).
struct BrowserPillProgress: View {
  let model: BrowserTabModel

  var body: some View {
    let fraction = model.isLoading ? max(0.05, min(model.estimatedProgress, 1)) : 0
    GeometryReader { proxy in
      Capsule()
        .fill(Color.blue)
        .frame(width: max(0, proxy.size.width - 40) * fraction, height: 2.5)
        .padding(.leading, 20)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
    .animation(.easeOut(duration: 0.2), value: fraction)
    .opacity(model.isLoading ? 1 : 0)
    .allowsHitTesting(false)
    .accessibilityElement()
    .accessibilityLabel("Loading")
    .accessibilityValue(
      Text(model.estimatedProgress, format: .percent.precision(.fractionLength(0)))
    )
    .accessibilityIdentifier("browser.progress")
  }
}

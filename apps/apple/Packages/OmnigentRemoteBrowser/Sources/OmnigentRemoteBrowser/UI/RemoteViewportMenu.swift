import OmnigentCoreFFI
import SwiftUI

/// The remote tab's viewport menu on the Mac toolbar (design doc section 16.1): keep the agent's
/// size, fit the window, or a preset or custom size.
struct RemoteViewportMenu: View {
  let store: RemoteBrowserStore
  @State private var editingCustomSize = false

  var body: some View {
    Menu {
      RemoteViewportMenuItems(store: store, editingCustomSize: $editingCustomSize)
    } label: {
      Label("Viewport: \(store.viewportMode.title)", systemImage: icon)
    }
    .menuIndicator(.hidden)
    .help("Remote viewport size")
    .accessibilityIdentifier("remote-browser.viewport")
    .remoteCustomSizeSheet(store: store, isPresented: $editingCustomSize)
  }

  private var icon: String {
    switch store.viewportMode {
    case .keep: "aspectratio"
    case .fitWindow: "arrow.up.left.and.arrow.down.right"
    case .fixed: "ruler"
    case .mobile: "iphone"
    }
  }
}

/// The viewport choices, shared by the Mac toolbar's menu and the iOS page menu's Viewport
/// submenu: keep, fit, a preset or custom size, and (on iPhone and iPad) the device's own mobile
/// size.
struct RemoteViewportMenuItems: View {
  let store: RemoteBrowserStore
  @Binding var editingCustomSize: Bool

  var body: some View {
    choice(.keep, systemImage: "aspectratio", id: "keep")
    choice(.fitWindow, systemImage: "arrow.up.left.and.arrow.down.right", id: "fit")
    Menu {
      ForEach(RemoteViewportMode.presets, id: \.self) { size in
        choice(.fixed(size), systemImage: nil, id: "preset.\(size.width)x\(size.height)")
      }
      Divider()
      Button("Custom Size\u{2026}", systemImage: "pencil") { editingCustomSize = true }
        .accessibilityIdentifier("remote-browser.viewport.custom")
    } label: {
      Label(fixedTitle, systemImage: "ruler")
    }
    .accessibilityIdentifier("remote-browser.viewport.fixed")
    #if os(iOS)
      choice(
        .mobile(site: store.viewportMode.requestsMobileSite), systemImage: "iphone", id: "mobile")
    #endif
    if !store.canSendInput {
      Divider()
      Text("Applies while you are in control")
    }
  }

  private var fixedTitle: String {
    if case .fixed(let size) = store.viewportMode { return "Set Remote Size (\(size.label))" }
    return "Set Remote Size"
  }

  private func choice(_ mode: RemoteViewportMode, systemImage: String?, id: String) -> some View {
    let selected = store.viewportMode == mode
    return Button {
      store.viewportMode = mode
    } label: {
      if selected {
        Label(mode.title, systemImage: "checkmark")
      } else if let systemImage {
        Label(mode.title, systemImage: systemImage)
      } else {
        Text(mode.title)
      }
    }
    .accessibilityIdentifier("remote-browser.viewport.\(id)")
  }
}

#if os(iOS)
  /// Safari's "Request Desktop Website" for Mobile Size: asks for mobile sites with a mobile
  /// user agent, or back for desktop sites. Only Mobile Size has a mobile user agent to offer.
  struct RemoteMobileSiteButton: View {
    let store: RemoteBrowserStore

    var body: some View {
      let site = store.viewportMode.requestsMobileSite
      Button {
        store.requestMobileWebsite(!site)
      } label: {
        if site {
          Label("Request Desktop Website", systemImage: "desktopcomputer")
        } else {
          Label("Request Mobile Website", systemImage: "iphone")
        }
      }
      .disabled(!store.viewportMode.isMobile)
      .accessibilityIdentifier("remote-browser.viewport.mobileSite")
    }
  }
#endif

extension View {
  /// Presents the custom size form, applying the size it returns.
  func remoteCustomSizeSheet(store: RemoteBrowserStore, isPresented: Binding<Bool>) -> some View {
    sheet(isPresented: isPresented) {
      RemoteCustomSizeSheet(initial: customSizeInitial(store)) { store.viewportMode = .fixed($0) }
    }
  }

  private func customSizeInitial(_ store: RemoteBrowserStore) -> RemoteViewportSize {
    if case .fixed(let size) = store.viewportMode { return size }
    let viewport = store.snapshot.viewport
    return RemoteViewportSize(
      width: Int(viewport?.width ?? 1280), height: Int(viewport?.height ?? 800))
  }
}

/// Width, height and sharp text for "Custom Size".
struct RemoteCustomSizeSheet: View {
  let apply: (RemoteViewportSize) -> Void
  @State private var width: Int
  @State private var height: Int
  @State private var sharpText: Bool
  @Environment(\.dismiss) private var dismiss

  init(initial: RemoteViewportSize, apply: @escaping (RemoteViewportSize) -> Void) {
    self.apply = apply
    _width = State(initialValue: initial.width)
    _height = State(initialValue: initial.height)
    _sharpText = State(initialValue: initial.dpr > 1)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Width", value: $width, format: .number)
            .accessibilityIdentifier("remote-browser.viewport.custom.width")
          TextField("Height", value: $height, format: .number)
            .accessibilityIdentifier("remote-browser.viewport.custom.height")
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
        } header: {
          Text("Remote size in CSS pixels")
        } footer: {
          Text("200 to 3840 pixels on each side.")
        }
        Toggle("Sharp Text (2\u{00D7} pixels)", isOn: $sharpText)
          .accessibilityIdentifier("remote-browser.viewport.custom.sharp")
      }
      .navigationTitle("Custom Size")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") {
            apply(RemoteViewportSize(width: width, height: height, dpr: sharpText ? 2 : 1))
            dismiss()
          }
          .disabled(!valid)
          .accessibilityIdentifier("remote-browser.viewport.custom.apply")
        }
      }
    }
    .frame(minWidth: 320, minHeight: 280)
  }

  private var valid: Bool {
    (200...3840).contains(width) && (200...3840).contains(height)
  }
}

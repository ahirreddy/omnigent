import OmnigentCoreFFI
import SwiftUI

/// The remote tab's viewport menu (design doc section 16.1): keep the agent's size, fit the
/// window, a preset or custom size, or (on iPhone and iPad) the device's own mobile size.
struct RemoteViewportMenu: View {
  let store: RemoteBrowserStore
  @State private var editingCustomSize = false

  var body: some View {
    Menu {
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
        Divider()
        choice(.mobile(site: mobileSite), systemImage: "iphone", id: "mobile")
        Toggle(
          "Request Mobile Website",
          isOn: Binding(get: { mobileSite }, set: { store.requestMobileWebsite($0) })
        )
        .disabled(!store.viewportMode.isMobile)
        .accessibilityIdentifier("remote-browser.viewport.mobileSite")
      #endif
      if !store.canSendInput {
        Divider()
        Text("Applies while you are in control")
      }
    } label: {
      Label("Viewport: \(store.viewportMode.title)", systemImage: icon)
    }
    .menuIndicator(.hidden)
    .help("Remote viewport size")
    .accessibilityIdentifier("remote-browser.viewport")
    .sheet(isPresented: $editingCustomSize) {
      RemoteCustomSizeSheet(initial: customInitial) { store.viewportMode = .fixed($0) }
    }
  }

  private var mobileSite: Bool {
    if case .mobile(let site) = store.viewportMode { return site }
    return false
  }

  private var fixedTitle: String {
    if case .fixed(let size) = store.viewportMode { return "Set Remote Size (\(size.label))" }
    return "Set Remote Size"
  }

  private var customInitial: RemoteViewportSize {
    if case .fixed(let size) = store.viewportMode { return size }
    let viewport = store.snapshot.viewport
    return RemoteViewportSize(
      width: Int(viewport?.width ?? 1280), height: Int(viewport?.height ?? 800))
  }

  private var icon: String {
    switch store.viewportMode {
    case .keep: "aspectratio"
    case .fitWindow: "arrow.up.left.and.arrow.down.right"
    case .fixed: "ruler"
    case .mobile: "iphone"
    }
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

public import SwiftUI

/// The component gallery: a searchable catalog of components, pages and flows, with an
/// inspector for appearance, theme, device and accessibility, and snapshot export.
public struct GalleryCatalogView: View {
  @State private var settings = CatalogSettings()
  @State private var selection: String?
  @State private var search = ""
  @State private var showsInspector = true
  private let initialStateID: String?

  /// Creates the gallery.
  /// - Parameter initialEntryID: The entry to show first, for example
  ///   `components.composer.composer`; the first entry when `nil` or unknown.
  public init(initialEntryID: String? = nil) {
    var options = GalleryLaunchOptions()
    options.entryID = initialEntryID
    self.init(options: options)
  }

  /// Creates the gallery from launch options: the entry, state and device to start on.
  /// - Parameter options: Parsed launch options.
  public init(options: GalleryLaunchOptions) {
    let entries = GalleryCatalog.entries
    let initial = options.entryID.flatMap { id in entries.first { $0.id == id }?.id }
    _selection = State(initialValue: initial ?? entries.first?.id)
    initialStateID = options.stateID
    let settings = CatalogSettings()
    if let screen = options.device.flatMap(CatalogScreen.init(id:)) {
      settings.device = screen.device
      settings.isLandscape = screen.isLandscape
      settings.isUnfolded = screen.isUnfolded
    }
    settings.showsFrame = options.frames
    _settings = State(initialValue: settings)
  }

  private var results: [CatalogEntry] {
    GalleryCatalog.search(GalleryCatalog.entries, query: search)
  }

  private var entry: CatalogEntry? { selection.flatMap(GalleryCatalog.entry) }

  /// The gallery.
  public var body: some View {
    NavigationSplitView {
      CatalogSidebar(entries: results, selection: $selection, isSearching: !search.isEmpty)
        .searchable(text: $search, placement: .sidebar, prompt: "Components, pages, flows")
        .navigationTitle("Gallery")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    } detail: {
      Group {
        if let entry {
          CatalogEntryDetail(
            entry: entry, settings: settings,
            initialStateID: entry.states.contains { $0.id == initialStateID } ? initialStateID : nil
          )
          .id(entry.id)
        } else {
          ContentUnavailableView(
            "Choose an Entry", systemImage: "square.grid.2x2",
            description: Text(CatalogSidebar.summary(GalleryCatalog.entries)))
        }
      }
      .inspector(isPresented: $showsInspector) {
        CatalogInspector(settings: settings, current: entry, results: results)
          .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
      }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showsInspector.toggle()
          } label: {
            Label("Gallery Controls", systemImage: "slider.horizontal.3")
          }
          .help("Show or hide appearance, device and export controls")
          .accessibilityIdentifier("gallery-inspector-toggle")
        }
      }
    }
    .accessibilityIdentifier("gallery")
  }
}

/// The catalog's sidebar: three sections, each grouped by area.
struct CatalogSidebar: View {
  let entries: [CatalogEntry]
  @Binding var selection: String?
  let isSearching: Bool
  @State private var collapsed: Set<String> = []

  static func summary(_ entries: [CatalogEntry]) -> String {
    CatalogSection.allCases.map { section in
      "\(entries.count { $0.section == section }) \(section.title.lowercased())"
    }.joined(separator: ", ")
  }

  var body: some View {
    List(selection: $selection) {
      ForEach(CatalogSection.allCases) { section in
        let groups = GalleryCatalog.groups(entries, section: section)
        if !groups.isEmpty {
          Section {
            ForEach(groups, id: \.area) { group in
              DisclosureGroup(isExpanded: expanded("\(section.rawValue).\(group.area.rawValue)")) {
                ForEach(group.entries) { entry in
                  Label(entry.title, systemImage: entry.systemImage)
                    .tag(entry.id)
                    .accessibilityIdentifier("gallery-entry-\(entry.id)")
                }
              } label: {
                Text(group.area.title)
              }
            }
          } header: {
            Text("\(section.title) \u{00B7} \(groups.reduce(0) { $0 + $1.entries.count })")
          }
        }
      }
    }
    .overlay {
      if entries.isEmpty {
        ContentUnavailableView.search
      }
    }
  }

  private func expanded(_ key: String) -> Binding<Bool> {
    Binding(
      get: { isSearching || !collapsed.contains(key) },
      set: { isExpanded in
        if isExpanded { collapsed.remove(key) } else { collapsed.insert(key) }
      })
  }
}

/// One entry: its header, state picker or step list, and the canvases.
struct CatalogEntryDetail: View {
  let entry: CatalogEntry
  @Bindable var settings: CatalogSettings
  @State private var stateID: String?
  @State private var showsLive = false
  #if os(iOS)
    @State private var showsFullScreen = false
  #endif

  init(entry: CatalogEntry, settings: CatalogSettings, initialStateID: String? = nil) {
    self.entry = entry
    _settings = Bindable(settings)
    _stateID = State(initialValue: initialStateID)
  }

  private var state: CatalogState? { entry.state(stateID) }
  private var screen: CatalogScreen { settings.screen(for: entry.canvas) }
  private var showsAllStates: Bool { entry.section == .components && settings.showsAllStates }

  var body: some View {
    VStack(spacing: 0) {
      CatalogEntryHeader(
        entry: entry, stateID: $stateID, showsLive: $showsLive, showsStatePicker: !showsAllStates
      )
      Divider()
      if showsLive, let live = entry.live {
        CatalogLiveCanvas(make: live, settings: settings, screen: screen)
      } else if entry.section == .flows {
        CatalogFlowDetail(entry: entry, settings: settings, stepID: $stateID)
      } else if showsAllStates {
        CatalogStateGrid(entry: entry, states: entry.states, settings: settings)
      } else if let state {
        CatalogStateGrid(entry: entry, states: [state], settings: settings).id(state.id)
      }
    }
    .toolbar {
      ToolbarItem {
        Button {
          open()
        } label: {
          #if os(macOS)
            Label("Open in Window", systemImage: "macwindow.badge.plus")
          #else
            Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
          #endif
        }
        .help("Show this state at full size with the window's own chrome")
        .disabled(state == nil)
        .accessibilityIdentifier("gallery-open-full")
      }
    }
    #if os(iOS)
      .fullScreenCover(isPresented: $showsFullScreen) {
        if let state {
          CatalogFullScreen(state: state, settings: settings, canvas: entry.canvas) {
            showsFullScreen = false
          }
        }
      }
    #endif
  }

  private func open() {
    #if os(macOS)
      guard let state else { return }
      let layout = CatalogLayout(canvas: entry.canvas, screen: screen, framed: settings.showsFrame)
      CatalogWindows.open(
        title: "\(entry.title) \u{2014} \(state.title)", state: state,
        context: settings.context(screen),
        traits: settings.traits(settings.appearance.schemes[0], screen: screen), layout: layout)
    #else
      showsFullScreen = true
    #endif
  }
}

/// The title, summary, picker and note above the canvas.
private struct CatalogEntryHeader: View {
  let entry: CatalogEntry
  @Binding var stateID: String?
  @Binding var showsLive: Bool
  let showsStatePicker: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
          Text(entry.title).font(.title2.weight(.semibold))
          Text(entry.summary).foregroundStyle(.secondary)
        }
        Spacer()
        if entry.live != nil {
          Picker("Mode", selection: $showsLive) {
            Text(entry.section == .flows ? "Steps" : "States").tag(false)
            Text("Live").tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          .accessibilityIdentifier("gallery-mode")
        }
      }
      HStack(spacing: Theme.Spacing.small) {
        Text("\(entry.section.title) \u{00B7} \(entry.area.title)")
        Text(entry.id).monospaced()
        Spacer()
        if showsStatePicker, entry.section != .flows, entry.states.count > 1, !showsLive {
          Picker("State", selection: selected) {
            ForEach(entry.states) { Text($0.title).tag($0.id) }
          }
          .fixedSize()
          .accessibilityIdentifier("gallery-state")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let note = entry.state(stateID)?.note, entry.section != .flows, showsStatePicker {
        Label(note, systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, Theme.Spacing.extraLarge)
    .padding(.vertical, Theme.Spacing.medium)
  }

  private var selected: Binding<String> {
    Binding(
      get: { entry.state(stateID)?.id ?? "" },
      set: { stateID = $0 })
  }
}

/// States laid out with each appearance side by side, pages in device frames scaled to fit.
private struct CatalogStateGrid: View {
  let entry: CatalogEntry
  let states: [CatalogState]
  @Bindable var settings: CatalogSettings

  private var screen: CatalogScreen { settings.screen(for: entry.canvas) }
  private var layout: CatalogLayout {
    CatalogLayout(canvas: entry.canvas, screen: screen, framed: settings.showsFrame)
  }
  private var isPage: Bool { layout.isPage }

  var body: some View {
    GeometryReader { proxy in
      ScrollView([.vertical, .horizontal]) {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
          ForEach(states) { state in
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
              if states.count > 1 {
                Text(state.title).font(.headline)
                if let note = state.note {
                  Text(note).font(.callout).foregroundStyle(.secondary)
                }
              }
              row(state, scale: scale(for: proxy.size))
            }
          }
        }
        .padding(Theme.Spacing.extraLarge)
        // Two-axis scroll views center smaller content; keep it at the top leading corner.
        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
      }
    }
  }

  private func row(_ state: CatalogState, scale: CGFloat) -> some View {
    let schemes = settings.appearance.schemes
    return CatalogSideBySide(isHorizontal: isPage || layout.width * 2 < 1_500) {
      ForEach(schemes, id: \.self) { scheme in
        let canvas = CatalogCanvasView(
          state: state, context: settings.context(screen),
          traits: settings.traits(scheme, screen: screen), layout: layout
        )
        .id(CatalogCanvasID(state: state.id, scheme: scheme, layout: layout))
        let label = "\(screen.title) \u{00B7} \(scheme == .dark ? "Dark" : "Light")"
        if isPage {
          CatalogPageFrame(layout: layout, label: label) {
            canvas
              .scaleEffect(scale, anchor: .topLeading)
              .frame(
                width: layout.width * scale, height: (layout.height ?? 0) * scale,
                alignment: .topLeading)
          }
        } else {
          CatalogComponentFrame(label: scheme == .dark ? "Dark" : "Light") { canvas }
        }
      }
    }
  }

  /// Pages shrink to fit the visible area when Fit is on; components stay at actual size.
  private func scale(for available: CGSize) -> CGFloat {
    guard isPage, settings.fitsPages else { return 1 }
    return layout.fitScale(in: available, columns: settings.appearance.schemes.count)
  }
}

/// A canvas's identity: a new state, appearance or layout makes its view afresh.
struct CatalogCanvasID: Hashable {
  let state: String
  let scheme: ColorScheme
  let layout: CatalogLayout
}

/// Children in a row, or a column when they would be too wide.
private struct CatalogSideBySide<Content: View>: View {
  let isHorizontal: Bool
  @ViewBuilder var content: Content

  var body: some View {
    if isHorizontal {
      HStack(alignment: .top, spacing: Theme.Spacing.extraLarge) { content }
    } else {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraLarge) { content }
    }
  }
}

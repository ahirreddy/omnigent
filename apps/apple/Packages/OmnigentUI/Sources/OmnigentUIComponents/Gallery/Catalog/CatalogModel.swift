import SwiftUI

/// The catalog's three levels: single components, whole pages and multi-step flows.
enum CatalogSection: String, CaseIterable, Identifiable, Sendable {
  /// One reusable component in its important states.
  case components
  /// A full screen with realistic data.
  case pages
  /// A step-through journey.
  case flows

  /// The section itself.
  var id: Self { self }

  /// The sidebar heading.
  var title: String {
    switch self {
    case .components: "Components"
    case .pages: "Pages"
    case .flows: "Flows"
    }
  }

  /// An SF Symbol.
  var systemImage: String {
    switch self {
    case .components: "square.grid.2x2"
    case .pages: "macwindow"
    case .flows: "arrow.triangle.turn.up.right.diamond"
    }
  }
}

/// The product area an entry belongs to, for grouping and search.
enum CatalogArea: String, CaseIterable, Identifiable, Sendable {
  case designSystem
  case transcript
  case composer
  case decisions
  case inbox
  case sessionList
  case inspector
  case tabs
  case palette
  case settings
  case newSession
  case markdown
  case signIn
  case shell

  /// The area itself.
  var id: Self { self }

  /// The group heading.
  var title: String {
    switch self {
    case .designSystem: "Design System"
    case .transcript: "Transcript"
    case .composer: "Composer"
    case .decisions: "Decisions"
    case .inbox: "Inbox"
    case .sessionList: "Session List"
    case .inspector: "Inspector"
    case .tabs: "Tabs"
    case .palette: "Palette"
    case .settings: "Settings"
    case .newSession: "New Session"
    case .markdown: "Markdown"
    case .signIn: "Sign-in"
    case .shell: "App Shell"
    }
  }
}

/// How an entry's canvas is sized.
enum CatalogCanvas: Hashable, Sendable {
  /// A column of the given width that grows to fit its content.
  case column(width: CGFloat)
  /// A fixed-size surface, such as a sidebar or a sheet.
  case fixed(width: CGFloat, height: CGFloat)
  /// A whole screen sized by a device, from the devices the entry supports.
  case device([CatalogDevice])

  /// A whole screen on every device.
  static let anyDevice = Self.device(CatalogDevice.allCases)
  /// A whole screen on iPhone only.
  static let phone = Self.device(CatalogDevice.phones)
  /// A whole screen on devices with room for a regular-width layout.
  static let largeScreen = Self.device(CatalogDevice.largeScreens)

  /// The devices a device canvas supports; empty for columns and fixed surfaces.
  var devices: [CatalogDevice] {
    if case .device(let devices) = self { return devices }
    return []
  }
}

/// Everything an entry's views may need from the catalog when they are made.
struct CatalogContext {
  /// The screen the canvas lays out for.
  var screen: CatalogScreen
  /// The theme preferences the catalog's pages share, so playground models follow the
  /// inspector's palette.
  var preferences: ThemePreferences
}

/// One state of an entry: a component state, a page variant or a flow step.
struct CatalogState: Identifiable {
  /// A file-name-safe id, unique within its entry.
  let id: String
  /// The picker and step-list title.
  let title: String
  /// What to look at, or for a flow step, what the user did to get here.
  let note: String?
  /// For a flow step, the step it branches from instead of the one before it.
  let branchesFrom: String?
  /// Makes the view. Called once per presentation; the result keeps its own state.
  let make: @MainActor (CatalogContext) -> AnyView

  /// Creates a state.
  /// - Parameters:
  ///   - id: A file-name-safe id, unique within its entry.
  ///   - title: The title.
  ///   - note: What to look at.
  ///   - branchesFrom: The step a branch starts from.
  ///   - make: Makes the view.
  init(
    _ id: String, _ title: String, note: String? = nil, branchesFrom: String? = nil,
    make: @escaping @MainActor (CatalogContext) -> AnyView
  ) {
    self.id = id
    self.title = title
    self.note = note
    self.branchesFrom = branchesFrom
    self.make = make
  }

  /// Creates a state from a view that ignores the context.
  /// - Parameters:
  ///   - id: A file-name-safe id, unique within its entry.
  ///   - title: The title.
  ///   - note: What to look at.
  ///   - content: The view.
  init<Content: View>(
    _ id: String, _ title: String, note: String? = nil,
    @ViewBuilder content: @escaping @MainActor () -> Content
  ) {
    self.init(id, title, note: note) { _ in AnyView(content()) }
  }
}

/// One catalog entry: a component, a page or a flow.
struct CatalogEntry: Identifiable {
  /// A stable path-like id, `<section>.<area>.<name>`.
  let id: String
  /// The section.
  let section: CatalogSection
  /// The product area.
  let area: CatalogArea
  /// The title.
  let title: String
  /// One line on what it is and where it appears.
  let summary: String
  /// An SF Symbol.
  let systemImage: String
  /// How the canvas is sized.
  let canvas: CatalogCanvas
  /// The states, page variants or flow steps, in order.
  let states: [CatalogState]
  /// An interactive version, when an existing playground supports real interaction.
  let live: (@MainActor (CatalogContext) -> AnyView)?
  /// Extra search terms.
  let keywords: [String]

  /// Creates an entry.
  /// - Parameters:
  ///   - section: The section.
  ///   - area: The product area.
  ///   - name: The id's last component, file-name safe.
  ///   - title: The title.
  ///   - summary: One line on what it is.
  ///   - systemImage: An SF Symbol.
  ///   - canvas: How the canvas is sized.
  ///   - keywords: Extra search terms.
  ///   - states: The states, in order.
  ///   - live: An interactive version.
  init(
    _ section: CatalogSection, _ area: CatalogArea, _ name: String, title: String,
    summary: String, systemImage: String, canvas: CatalogCanvas, keywords: [String] = [],
    states: [CatalogState], live: (@MainActor (CatalogContext) -> AnyView)? = nil
  ) {
    self.id = "\(section.rawValue).\(area.rawValue).\(name)"
    self.section = section
    self.area = area
    self.title = title
    self.summary = summary
    self.systemImage = systemImage
    self.canvas = canvas
    self.keywords = keywords
    self.states = states
    self.live = live
  }

  /// The state with `id`, or the first one.
  /// - Parameter id: A state id.
  /// - Returns: The state, or `nil` when the entry has none.
  func state(_ id: String?) -> CatalogState? {
    states.first { $0.id == id } ?? states.first
  }
}

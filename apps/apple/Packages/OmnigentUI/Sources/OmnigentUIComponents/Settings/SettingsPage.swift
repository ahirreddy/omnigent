#if os(macOS)
  public import SwiftUI

  /// One category of the Mac's Settings page: its row in the sidebar and its pane.
  public struct SettingsPageCategory: Identifiable {
    /// The category's title, also its identity.
    public let id: String
    /// An SF Symbol.
    public let systemImage: String
    /// The pane lays itself out over the whole content area (a split view) instead of the
    /// readable column.
    public let isWide: Bool
    /// The pane, usually a grouped `Form`.
    public let content: AnyView

    /// Creates a category.
    /// - Parameters:
    ///   - title: The title, also its identity.
    ///   - systemImage: An SF Symbol.
    ///   - isWide: The pane lays itself out over the whole content area.
    ///   - content: The pane.
    public init(_ title: String, systemImage: String, isWide: Bool = false, content: AnyView) {
      id = title
      self.systemImage = systemImage
      self.isWide = isWide
      self.content = content
    }

    /// The title.
    public var title: String { id }
  }

  /// The Mac's Settings, in the whole window: the categories in a sidebar on the left under a
  /// Back control, and the selected category's pane in a readable column beside it. Escape and
  /// Command-W go back, as Back does.
  public struct SettingsPage: View {
    private let categories: [SettingsPageCategory]
    @Binding private var selection: String
    private let back: @MainActor () -> Void

    /// Creates the page.
    /// - Parameters:
    ///   - categories: The categories, in sidebar order.
    ///   - selection: The shown category's id; one the page does not have shows the first.
    ///   - back: Leaves Settings for the window's own content.
    public init(
      categories: [SettingsPageCategory], selection: Binding<String>,
      back: @escaping @MainActor () -> Void
    ) {
      self.categories = categories
      _selection = selection
      self.back = back
    }

    /// The category whose pane shows.
    private var shown: SettingsPageCategory? {
      categories.first { $0.id == selection } ?? categories.first
    }

    /// The page.
    public var body: some View {
      HStack(spacing: 0) {
        SettingsPageSidebar(
          categories: categories, shownID: shown?.id, select: { selection = $0 }, back: back)
        pane
      }
      .themeCanvas()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("settings-page")
    }

    @ViewBuilder private var pane: some View {
      if let category = shown {
        Group {
          if category.isWide {
            category.content
          } else {
            VStack(alignment: .leading, spacing: 0) {
              // As the titles of the window's own pages (Usage, Automations).
              Text(category.title)
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, SettingsPageMetrics.formInset)
                .padding(.top, Theme.Spacing.large)
              category.content
            }
            .frame(maxWidth: SettingsPageMetrics.columnWidth)
          }
        }
        // The panes are grouped forms; the theme's canvas shows behind their groups.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(category.id)
      }
    }
  }

  /// The Settings page's sizes.
  enum SettingsPageMetrics {
    /// The widest a form pane's column gets, so its rows stay readable in a wide window.
    static let columnWidth: CGFloat = 680
    /// A grouped form's own leading inset on the Mac, which the pane's heading lines up with.
    static let formInset: CGFloat = 20
  }

  /// The page's sidebar, drawn as the session sidebar is: a panel of glass at the window's
  /// leading edge, reaching under the title bar, with the theme's selection behind the shown row.
  private struct SettingsPageSidebar: View {
    let categories: [SettingsPageCategory]
    let shownID: String?
    let select: @MainActor (String) -> Void
    let back: @MainActor () -> Void

    var body: some View {
      List(selection: listSelection) {
        ForEach(categories) { category in
          Button {
            select(category.id)
          } label: {
            Label(category.title, systemImage: category.systemImage)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .tag(category.id)
          .sidebarSelection(category.id == shownID)
          .accessibilityAddTraits(category.id == shownID ? .isSelected : [])
          .accessibilityIdentifier("settings-category-\(category.id)")
        }
      }
      .listStyle(.sidebar)
      .font(.callout)
      .environment(\.defaultMinListRowHeight, Theme.Control.sidebarRow)
      .scrollContentBackground(.hidden)
      .safeAreaInset(edge: .top, spacing: 0) { header }
      .frame(width: AppShellMetrics.sidebarIdealWidth)
      .frame(maxHeight: .infinity)
      .background {
        // Only the panel reaches under the title bar; its rows start below it.
        Color.clear
          .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
          .padding(.top, Theme.Spacing.small)
          .ignoresSafeArea(.container, edges: .top)
      }
      .padding([.horizontal, .bottom], Theme.Spacing.small)
    }

    /// The arrow keys move the list's selection; a click runs the row's button.
    private var listSelection: Binding<String?> {
      Binding(get: { shownID }, set: { id in if let id { select(id) } })
    }

    private var header: some View {
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        Button(action: back) {
          Label("Back", systemImage: "chevron.backward")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .keyboardShortcut(.cancelAction)
        .help("Back (Esc)")
        .accessibilityIdentifier("settings-back")
        // The page's name, where the session sidebar has the wordmark.
        Text("Settings")
          .font(.headline.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.Spacing.large)
      .padding(.vertical, Theme.Spacing.small)
      .background { closeShortcut }
    }

    /// Command-W leaves Settings: the key reaches the page before File > Close Tab, which would
    /// close a tab of the content the page covers.
    private var closeShortcut: some View {
      Button("Close Settings", action: back)
        .keyboardShortcut(AppShortcuts.closeTab)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }
#endif

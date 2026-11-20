public import SwiftUI

/// What the server's title search found for the Nests picker.
nonisolated public struct NestSearchResults: Hashable, Sendable {
  /// Sessions the viewer owns whose title matches ``query``.
  public var found: [SessionSummary]
  /// The text ``found`` answers; they show only while it is still the text typed.
  public var query: String
  /// A page is being read.
  public var isSearching: Bool
  /// The last read failed; it can be tried again.
  public var failed: Bool
  /// More matches remain.
  public var hasMore: Bool

  /// Creates results.
  /// - Parameters:
  ///   - found: Owned matches.
  ///   - query: The text they answer.
  ///   - isSearching: A page is being read.
  ///   - failed: The last read failed.
  ///   - hasMore: More matches remain.
  public init(
    found: [SessionSummary] = [], query: String = "", isSearching: Bool = false,
    failed: Bool = false, hasMore: Bool = false
  ) {
    self.found = found
    self.query = query
    self.isSearching = isSearching
    self.failed = failed
    self.hasMore = hasMore
  }
}

/// The Nests picker's actions.
public struct NestPickerActions {
  /// Moves the session into the nest of the chosen session.
  public var join: @MainActor (SessionSummary) -> Void
  /// Takes it out of its nest; `nil` when it is in none.
  public var leave: (@MainActor () -> Void)?
  /// Reads the next page of matches, or the failed one again.
  public var more: @MainActor () -> Void
  /// Closes the picker.
  public var dismiss: @MainActor () -> Void

  /// Creates actions.
  /// - Parameters:
  ///   - join: Join a nest.
  ///   - leave: Leave the session's nest.
  ///   - more: Read more matches.
  ///   - dismiss: Close.
  public init(
    join: @escaping @MainActor (SessionSummary) -> Void, leave: (@MainActor () -> Void)?,
    more: @escaping @MainActor () -> Void, dismiss: @escaping @MainActor () -> Void
  ) {
    self.join = join
    self.leave = leave
    self.more = more
    self.dismiss = dismiss
  }
}

/// Moves a session into another nest, searching the server beyond the loaded rows (the web's
/// `NestPickerMenu`): the loaded nests whose title matches, then the server's matches.
public struct NestPickerSheet: View {
  private let session: SessionSummary
  private let local: [SessionSummary]
  private let isShared: (String) -> Bool
  private let results: NestSearchResults
  @Binding private var query: String
  private let actions: NestPickerActions
  @State private var searchFocused = false

  /// Creates the picker.
  /// - Parameters:
  ///   - session: The session that moves.
  ///   - local: The loaded rows.
  ///   - isShared: Whether a loaded row is someone else's.
  ///   - results: What the server found.
  ///   - query: The typed text.
  ///   - actions: The actions.
  public init(
    session: SessionSummary, local: [SessionSummary], isShared: @escaping (String) -> Bool,
    results: NestSearchResults, query: Binding<String>, actions: NestPickerActions
  ) {
    self.session = session
    self.local = local
    self.isShared = isShared
    self.results = results
    _query = query
    self.actions = actions
  }

  /// The nests to offer, one session of each: loaded rows matching `query`, then the server's
  /// matches while they answer it.
  static func destinations(
    for session: SessionSummary, local: [SessionSummary], results: NestSearchResults,
    query: String, isShared: (String) -> Bool
  ) -> [SessionSummary] {
    let text = query.trimmingCharacters(in: .whitespaces)
    let matching = local.filter { text.isEmpty || label($0).localizedCaseInsensitiveContains(text) }
    let found = results.query == text ? results.found : []
    return SidebarFamilies.nestDestinations(
      for: session, among: matching + found, isShared: isShared)
  }

  /// A nest's name: its representative's title.
  static func label(_ row: SessionSummary) -> String {
    row.family?.representativeTitle ?? row.title
  }

  private var shown: [SessionSummary] {
    Self.destinations(
      for: session, local: local, results: results, query: query, isShared: isShared)
  }

  private var answersQuery: Bool {
    results.query == query.trimmingCharacters(in: .whitespaces)
  }

  /// The sheet.
  public var body: some View {
    sheet
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Move to nest")
      .accessibilityIdentifier("nest-picker")
  }

  #if os(macOS)
    /// A Mac sheet: the title, the search field, the list in its bordered box, then the buttons.
    private var sheet: some View {
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        Text("Move to Nest").font(.headline)
        SearchField(
          "Search nests", text: $query, identifier: "nest-search", isFocused: $searchFocused,
          escape: {
            actions.dismiss()
            return true
          }
        )
        .accessibilityLabel("Search nests")
        content
          .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 320, alignment: .top)
          // A list in a sheet sits in a bordered box, as an AppKit table in its scroll view.
          .overlay { Rectangle().strokeBorder(.separator).allowsHitTesting(false) }
        HStack {
          if let leave = actions.leave {
            Button("Remove from Nest", action: leave)
          }
          Spacer()
          Button("Cancel", role: .cancel, action: actions.dismiss)
            .keyboardShortcut(.cancelAction)
        }
      }
      .padding(Theme.Spacing.large)
      .frame(minWidth: 420)
      .onAppear { searchFocused = true }
    }
  #else
    /// An iOS sheet: the list under a navigation bar with the search field and Cancel.
    private var sheet: some View {
      NavigationStack {
        content
          .searchable(
            text: $query, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search nests"
          )
          .navigationTitle("Move to Nest")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", role: .cancel, action: actions.dismiss)
            }
            if let leave = actions.leave {
              ToolbarItem(placement: .bottomBar) {
                Button("Remove from Nest", action: leave)
              }
            }
          }
      }
    }
  #endif

  private var content: some View {
    List {
      ForEach(shown) { row in
        Button {
          actions.join(row)
        } label: {
          Label {
            Text(Self.label(row)).lineLimit(1).truncationMode(.tail)
          } icon: {
            // A list tints a label's icon with the accent; these stay grey.
            Image(systemName: "square.on.square").foregroundStyle(Color.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nest-destination-\(row.id)")
      }
      if results.isSearching {
        HStack(spacing: Theme.Spacing.small) {
          ProgressView().controlSize(.small)
          Text("Searching\u{2026}").foregroundStyle(.secondary)
        }
      } else if shown.isEmpty, answersQuery {
        Text("No other nests").foregroundStyle(.secondary)
      }
      if results.hasMore || results.failed {
        Button(results.failed ? "Retry" : "Show More", action: actions.more)
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
          .accessibilityIdentifier("nest-search-more")
      }
    }
    .listStyle(.plain)
  }
}

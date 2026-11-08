public import SwiftUI

/// The address and search field. Shows the page URL; while editing, suggestions from history,
/// bookmarks and open tabs, plus go or search for what was typed. On the Mac it is a toolbar
/// field with the favicon and bookmark star; on iPhone and iPad it is Safari's address pill.
struct BrowserOmniboxField: View {
  /// How the field looks.
  enum Style {
    /// A toolbar field with the favicon and the bookmark star (Mac).
    case toolbar
    /// Safari's pill: the domain centered until tapped, reload or stop at its trailing edge and
    /// the load progress along its bottom edge (iPhone, iPad).
    case pill
  }

  let model: BrowserTabModel
  let environment: BrowserEnvironment
  var style = Style.toolbar
  /// Follows whether the address is being edited, so the row can make room for it.
  var isEditing: Binding<Bool>?
  @State private var text = ""
  @State private var editing = false
  @State private var selected = 0
  @State private var selection: TextSelection?
  @State private var error: BrowserError?
  @FocusState private var focused: Bool

  static let pillHeight: CGFloat = 44
  private static let pillAccessory: CGFloat = 40

  var body: some View {
    let suggestions = currentSuggestions
    HStack(spacing: 8) {
      chrome(suggestions)
        .overlay(alignment: .topLeading) {
          if focused, editing, !suggestions.isEmpty {
            BrowserOmniboxSuggestionList(suggestions: suggestions, selected: selected) {
              choose($0)
            }
            .offset(y: style == .pill ? Self.pillHeight + 4 : 34)
          }
        }
      if style == .pill, focused {
        Button("Cancel") { focused = false }
          .buttonStyle(.plain)
          .fixedSize()
          .accessibilityIdentifier("browser.omnibox.cancel")
      }
    }
    .zIndex(10)
    .onChange(of: model.url, initial: true) { revert() }
    .onChange(of: focused) { _, isFocused in
      if let isEditing, isEditing.wrappedValue != isFocused { isEditing.wrappedValue = isFocused }
      guard isFocused else {
        revert()
        return
      }
      // As in Safari, focusing selects the whole address, so typing replaces it. After the
      // tap that focused the field places its caret.
      Task { selection = TextSelection(range: text.startIndex..<text.endIndex) }
    }
    .onChange(of: model.omniboxFocusRequest, initial: true) { _, request in
      if request > 0 { focused = true }
    }
    .popover(
      isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    ) {
      Text(error?.localizedDescription ?? "").padding()
        .presentationCompactAdaptation(.popover)
    }
  }

  @ViewBuilder private func chrome(_ suggestions: [BrowserOmniboxSuggestion]) -> some View {
    switch style {
    case .toolbar: toolbarField(suggestions)
    case .pill: pill(suggestions)
    }
  }

  private func field(_ suggestions: [BrowserOmniboxSuggestion]) -> some View {
    TextField(
      "Search or enter address", text: $text, selection: $selection,
      // The pill draws its own label while it is not being edited.
      prompt: style == .pill && !focused ? Text(verbatim: "") : nil
    )
    .textFieldStyle(.plain)
    .autocorrectionDisabled()
    .addressInput()
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
  }

  private func toolbarField(_ suggestions: [BrowserOmniboxSuggestion]) -> some View {
    HStack(spacing: 6) {
      if let image = model.favicon?.image {
        image.resizable().frame(width: 16, height: 16)
      } else {
        Image(systemName: model.url?.scheme == "https" ? "lock.fill" : "globe")
          .foregroundStyle(.secondary)
          .frame(width: 16, height: 16)
          .accessibilityLabel(model.url?.scheme == "https" ? "Secure" : "Page")
      }
      field(suggestions)
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
  }

  /// The address stays in the field (clear while not editing), so a tap on the domain focuses
  /// it; the empty leading slot balances reload so the domain sits centered.
  private func pill(_ suggestions: [BrowserOmniboxSuggestion]) -> some View {
    HStack(spacing: 0) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .frame(width: Self.pillAccessory)
        .opacity(focused ? 1 : 0)
        .accessibilityHidden(true)
      field(suggestions)
        .foregroundStyle(focused ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
        .overlay {
          if !focused {
            BrowserDomainLabel(url: model.url).allowsHitTesting(false)
          }
        }
      pillTrailing
    }
    .frame(height: Self.pillHeight)
    .background(.fill.tertiary, in: Capsule())
    .overlay(alignment: .bottom) { BrowserPillProgress(model: model) }
  }

  /// Reload or stop, or Clear while editing.
  private var pillTrailing: some View {
    Group {
      if !focused {
        BrowserReloadButton(model: model).foregroundStyle(.primary)
      } else if !text.isEmpty {
        Button("Clear", systemImage: "xmark.circle.fill") { replaceText("") }
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("browser.omnibox.clear")
      } else {
        Color.clear
      }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.plain)
    .frame(width: Self.pillAccessory, height: Self.pillHeight)
    .contentShape(Rectangle())
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
    replaceText(url.map { $0.absoluteString == "about:blank" ? "" : $0.absoluteString } ?? "")
  }

  /// Sets the field's text and drops the selection, whose indices belong to the old text.
  private func replaceText(_ newText: String) {
    selection = nil
    text = newText
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
    .suggestionListWidth()
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

extension View {
  /// The address keyboard on iPhone and iPad: no capitalization, `.` and `/` keys, and Go.
  fileprivate func addressInput() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.never)
        .keyboardType(.webSearch)
        .submitLabel(.go)
    #else
      self
    #endif
  }

  /// Suggestions as wide as the field on iPhone and iPad, a wider panel on the Mac.
  fileprivate func suggestionListWidth() -> some View {
    #if os(iOS)
      frame(maxWidth: .infinity, alignment: .leading)
    #else
      frame(minWidth: 420, maxWidth: 640, alignment: .leading)
    #endif
  }
}

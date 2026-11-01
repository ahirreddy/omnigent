public import SwiftUI

/// Content search: a query with case and regex toggles, optional include and exclude globs,
/// and results grouped by file with the match highlighted. Partial results and server
/// warnings are labeled; failures (an invalid regex, search turned off) show the server's
/// reason. Selecting a match opens the file at its line.
public struct ContentSearchPanel: View {
  @Bindable private var model: ContentSearchModel
  private let source: any WorkspaceDataSource
  private let actions: WorkspaceActions
  private let onOpen: (ContentMatch) -> Void
  @FocusState private var field: Field?

  private enum Field: Hashable {
    case query
    case results
  }

  /// A panel.
  /// - Parameters:
  ///   - model: The search state.
  ///   - source: Used for absolute paths.
  ///   - actions: Host hooks.
  ///   - onOpen: Opens a match's file at its line.
  public init(
    model: ContentSearchModel, source: any WorkspaceDataSource, actions: WorkspaceActions,
    onOpen: @escaping (ContentMatch) -> Void
  ) {
    self.model = model
    self.source = source
    self.actions = actions
    self.onOpen = onOpen
  }

  /// The view.
  public var body: some View {
    VStack(spacing: 0) {
      form
      Divider()
      results
    }
    .accessibilityIdentifier("workspace.search")
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        TextField("Search file contents", text: $model.query.query)
          .textFieldStyle(.roundedBorder)
          .focused($field, equals: .query)
          .onSubmit { submit() }
          .accessibilityIdentifier("workspace.search.query")
        Toggle(isOn: $model.query.caseSensitive) {
          Text("Aa").font(.system(size: 11, weight: .semibold))
        }
        .toggleStyle(.button)
        .help("Match case")
        .accessibilityLabel("Match case")
        Toggle(isOn: $model.query.regex) {
          Text(".*").font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .toggleStyle(.button)
        .help("Use regular expression")
        .accessibilityLabel("Use regular expression")
        Button {
          model.showsFilters.toggle()
        } label: {
          Image(
            systemName: model.query.hasFilters
              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.borderless)
        .help("Filter files")
        .accessibilityLabel("Filter files")
      }
      if model.showsFilters {
        TextField(
          "Include", text: $model.query.include,
          prompt: Text(verbatim: "Include, e.g. src/**, *.{ts,tsx}")
        )
        .textFieldStyle(.roundedBorder)
        .onSubmit { submit() }
        TextField(
          "Exclude", text: $model.query.exclude,
          prompt: Text(verbatim: "Exclude, e.g. **/tests/**")
        )
        .textFieldStyle(.roundedBorder)
        .onSubmit { submit() }
      }
    }
    .font(.system(size: 12))
    .padding(10)
  }

  @ViewBuilder private var results: some View {
    switch model.state {
    case .idle:
      ContentUnavailableView(
        "Search File Contents", systemImage: "text.magnifyingglass",
        description: Text("Find text across the session's workspace."))
    case .loading:
      ProgressView("Searching")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let failure):
      FailureView(failure: failure)
    case .loaded(let result):
      if result.files.isEmpty {
        ContentUnavailableView {
          Label("No Matches", systemImage: "magnifyingglass")
        } description: {
          Text(
            result.truncated
              ? "The search stopped early, so a match may still exist."
              : "Nothing matches \"\(model.searchedQuery?.query ?? "")\".")
        }
      } else {
        matches(result)
      }
    }
  }

  private func matches(_ result: ContentSearchResult) -> some View {
    VStack(spacing: 0) {
      if let warning = result.warning ?? (result.truncated ? "Results are partial." : nil) {
        NoticeBar(symbol: "exclamationmark.triangle", text: warning)
      }
      HStack {
        Text("\(result.matchCount) results in \(result.files.count) files")
        Spacer()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      matchList(result)
    }
  }

  private func matchList(_ result: ContentSearchResult) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(result.files) { file in
            Section {
              ForEach(file.matches) { match in
                MatchRow(match: match, isSelected: match.id == model.selection)
                  .id(match.id)
                  .contentShape(.rect)
                  .accessibilityAddTraits(.isButton)
                  .onTapGesture {
                    model.selection = match.id
                    field = .results
                    onOpen(match)
                  }
                  .contextMenu { PathMenu(path: match.path, source: source, actions: actions) }
              }
            } header: {
              FileMatchesHeader(file: file)
                .contextMenu { PathMenu(path: file.path, source: source, actions: actions) }
            }
          }
        }
      }
      .focusable()
      .focused($field, equals: .results)
      .focusEffectDisabled()
      .onKeyPress(.upArrow) {
        model.moveSelection(by: -1)
        return .handled
      }
      .onKeyPress(.downArrow) {
        model.moveSelection(by: 1)
        return .handled
      }
      .onKeyPress(.return) {
        if let match = model.matches.first(where: { $0.id == model.selection }) { onOpen(match) }
        return .handled
      }
      .onChange(of: model.selection) { _, selection in
        if let selection { proxy.scrollTo(selection) }
      }
    }
  }

  private func submit() {
    Task { await model.search() }
  }
}

private struct FileMatchesHeader: View {
  let file: ContentSearchFile

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: FileIcons.symbol(forName: WorkspacePaths.name(of: file.path)))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(WorkspacePaths.name(of: file.path))
        .font(.system(size: 12, weight: .semibold))
      Text(WorkspacePaths.directory(of: file.path))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 4)
      Text("\(file.matches.count)")
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(.quaternary, in: .capsule)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(.bar)
  }
}

private struct MatchRow: View {
  let match: ContentMatch
  let isSelected: Bool

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(String(match.line))
        .font(WorkspaceTheme.gutter)
        .foregroundStyle(.tertiary)
        .frame(minWidth: 28, alignment: .trailing)
      Text(
        Highlighting.marked(
          match.text, range: match.match.utf16Range(in: match.text),
          background: WorkspaceTheme.matchBackground(scheme))
      )
      .font(WorkspaceTheme.code)
      .lineLimit(1)
      .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
    .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Line \(match.line): \(match.text)")
  }
}

#Preview("Content search") {
  @Previewable @State var model = WorkspaceSamples.searchedModel()
  ContentSearchPanel(
    model: model, source: SampleWorkspaceDataSource(), actions: .none, onOpen: { _ in }
  )
  .frame(width: 340, height: 480)
}

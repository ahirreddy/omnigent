import Foundation

extension FileTreeModel {
  /// Whether the filter has text, so the rows are search matches.
  public var isSearching: Bool { !query.isEmpty }

  private var query: String { filter.trimmingCharacters(in: .whitespaces) }

  /// Searches the current filter now, skipping the pause.
  public func searchNow() async {
    pendingSearch?.cancel()
    searchGeneration += 1
    let current = searchGeneration
    let (query, include, exclude) = (query, include, exclude)
    guard !query.isEmpty else {
      search = .idle
      rebuild()
      return
    }
    if search.value == nil { search = .loading }
    rebuild()
    let result: LoadState<PathSearchResult>
    do {
      result = .loaded(try await source.searchPaths(query, include: include, exclude: exclude))
    } catch {
      result = .failed(error)
    }
    guard current == searchGeneration else { return }
    search = result
    rebuild()
  }

  func searchChanged() {
    pendingSearch?.cancel()
    let delay = searchDelay
    pendingSearch = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return  // A newer keystroke replaced this search.
      }
      await self?.searchNow()
    }
  }

  func appendMatches(into result: inout [Row]) {
    switch search {
    case .idle, .loading:
      result.append(Row(id: "#search-loading", directory: "", depth: 0, content: .loading))
      if search.value == nil { return }
    case .failed(let failure):
      result.append(Row(id: "#search-failure", directory: "", depth: 0, content: .failure(failure)))
      return
    case .loaded:
      break
    }
    let matches = sort.sorted((search.value?.entries ?? []).filter(isShown))
    for entry in matches {
      result.append(
        Row(
          id: entry.path, directory: WorkspacePaths.directory(of: entry.path), depth: 0,
          content: .match(entry)))
    }
    if matches.isEmpty {
      result.append(
        Row(id: "#search-none", directory: "", depth: 0, content: .note("No matching files")))
    } else if search.value?.truncated == true {
      result.append(
        Row(
          id: "#search-more", directory: "", depth: 0,
          content: .note("More files match. Refine the search to see them.")))
    }
  }
}

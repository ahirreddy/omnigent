internal import Foundation

/// Parses the Netscape bookmark file format (`<DL>`, `<DT><H3>`, `<DT><A HREF>`) that Chrome,
/// Safari and Firefox export.
nonisolated enum BrowserBookmarkHTML {
  struct Result {
    var toolbar: [BrowserBookmark]
    var other: [BrowserBookmark]
  }

  enum Token {
    case folder(String, isToolbar: Bool)
    case listStart
    case listEnd
    case link(String, URL)
  }

  /// Folders being built; index 0 is the root.
  private struct Builder {
    var stack: [(folder: BrowserBookmark, isToolbar: Bool)] = [
      (BrowserBookmark(folder: "root"), false)
    ]
    var pendingFolder: (title: String, isToolbar: Bool)?
    var toolbar: [BrowserBookmark] = []

    mutating func apply(_ token: Token) {
      switch token {
      case .folder(let title, let isToolbar):
        pendingFolder = (title, isToolbar)
      case .listStart:
        if let pending = pendingFolder {
          stack.append((BrowserBookmark(folder: pending.title), pending.isToolbar))
          pendingFolder = nil
        } else if stack.count > 1 || !(stack[0].folder.children ?? []).isEmpty {
          stack.append((BrowserBookmark(folder: "Folder"), false))
        }
      case .listEnd:
        closeFolder()
      case .link(let title, let url):
        stack[stack.count - 1].folder.children?.append(BrowserBookmark(title: title, url: url))
      }
    }

    mutating func closeFolder() {
      guard stack.count > 1 else { return }
      let (folder, isToolbar) = stack.removeLast()
      if isToolbar {
        toolbar.append(contentsOf: folder.children ?? [])
      } else {
        stack[stack.count - 1].folder.children?.append(folder)
      }
    }
  }

  static func parse(_ data: Data) throws(BrowserError) -> Result {
    guard
      let html = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1)
    else {
      throw .storageFailed("The bookmarks file is not text.")
    }
    guard html.range(of: "<DL", options: .caseInsensitive) != nil else {
      throw .storageFailed("The file is not a bookmarks export (no <DL> list).")
    }
    var builder = Builder()
    for token in try tokenize(html) {
      builder.apply(token)
    }
    while builder.stack.count > 1 {
      builder.closeFolder()
    }
    return Result(toolbar: builder.toolbar, other: builder.stack[0].folder.children ?? [])
  }

  static func tokenize(_ html: String) throws(BrowserError) -> [Token] {
    let regex: NSRegularExpression
    do {
      regex = try NSRegularExpression(
        pattern: #"<H3([^>]*)>(.*?)</H3>|<DL[^>]*>|</DL>|<A\s([^>]*)>(.*?)</A>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    } catch {
      throw .storageFailed("Bookmark parser: \(error.localizedDescription)")
    }
    let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
    return matches.compactMap { token(for: $0, in: html) }
  }

  private static func token(for match: NSTextCheckingResult, in html: String) -> Token? {
    func group(_ index: Int) -> String? {
      Range(match.range(at: index), in: html).map { String(html[$0]) }
    }
    if let folderTitle = group(2) {
      let title = unescape(folderTitle)
      // Chrome and Firefox flag the toolbar folder; Safari exports it as "Favorites".
      let isToolbar =
        (group(1) ?? "").uppercased().contains("PERSONAL_TOOLBAR_FOLDER") || title == "Favorites"
        || title == "Favourites"
      return .folder(title, isToolbar: isToolbar)
    }
    if let attributes = group(3) {
      guard let href = attribute("HREF", in: attributes), let url = URL(string: href),
        url.scheme != nil
      else {
        return nil
      }
      let title = unescape(group(4) ?? "")
      return .link(title.isEmpty ? href : title, url)
    }
    return (group(0) ?? "").hasPrefix("</") ? .listEnd : .listStart
  }

  static func attribute(_ name: String, in attributes: String) -> String? {
    let pattern = "\(name)\\s*=\\s*\"([^\"]*)\""
    guard
      let range = attributes.range(of: pattern, options: [.regularExpression, .caseInsensitive])
    else {
      return nil
    }
    let match = attributes[range]
    guard let open = match.firstIndex(of: "\""), let close = match.lastIndex(of: "\""),
      open < close
    else {
      return nil
    }
    return unescape(String(match[match.index(after: open)..<close]))
  }

  static func unescape(_ text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for (entity, character) in [
      ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
      ("&nbsp;", " "), ("&amp;", "&"),
    ] {
      result = result.replacingOccurrences(of: entity, with: character)
    }
    return result
  }
}

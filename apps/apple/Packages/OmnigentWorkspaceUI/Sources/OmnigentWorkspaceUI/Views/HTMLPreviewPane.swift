import SwiftUI

/// The HTML preview's zoom levels: Chrome's page-zoom presets, so it steps as the web's
/// preview and browser zoom do.
enum HTMLPreviewZoom {
  static let levels: [Double] = [
    0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5,
  ]
  /// Tolerates float drift, so a level never steps to itself.
  private static let epsilon = 0.001

  /// The next level above `current`, or the largest.
  static func zoomedIn(_ current: Double) -> Double {
    levels.first { $0 > current + epsilon } ?? levels.last ?? current
  }

  /// The next level below `current`, or the smallest.
  static func zoomedOut(_ current: Double) -> Double {
    levels.last { $0 < current - epsilon } ?? levels.first ?? current
  }

  /// The level a zoom shortcut leads to.
  static func zoomed(_ current: Double, by key: HTMLZoomKey) -> Double {
    switch key {
    case .zoomIn: zoomedIn(current)
    case .zoomOut: zoomedOut(current)
    case .reset: 1
    }
  }
}

/// A find in the HTML preview; a new `id` runs it again (Return steps to the next match).
struct HTMLFindRequest: Equatable {
  var query = ""
  var backwards = false
  var id = 0
}

/// Comments on an HTML file's rendered page, as the web's `HtmlCommentViewer`: the file's
/// review, and the source the selected text is found in.
struct HTMLPreviewReview {
  let path: String
  let review: FileReviewContext
  let source: any WorkspaceDataSource
  /// Unsaved edits: comments wait until they are saved.
  let isDirty: Bool
  let selectedCommentID: Binding<String?>
  /// Opens the comment composer on a span.
  let comment: (FileTextSpan) -> Void
  /// Selects a comment and shows the panel.
  let show: (String) -> Void

  /// The comments the page highlights: the open ones, and a sent one the panel shows.
  var marks: [HTMLCommentMark] {
    let selected = selectedCommentID.wrappedValue
    return review.comments.compactMap { comment in
      guard comment.isOpen || comment.id == selected, let anchor = comment.anchor else {
        return nil
      }
      return HTMLCommentMark(id: comment.id, anchor: anchor, occurrence: comment.htmlOccurrence)
    }
  }

  /// The open comment already on this copy of the selected text.
  func existingComment(on selection: HTMLSelection) -> FileCommentLine? {
    let text = HTMLSelection.folded(selection.text)
    return review.openComments.first { comment in
      comment.anchor.map(HTMLSelection.folded) == text
        && (comment.htmlOccurrence ?? 0) == selection.occurrence
    }
  }

  /// The span a comment on `selection` stores, offsets from the `html` source.
  func span(_ selection: HTMLSelection, in html: String) -> FileTextSpan {
    let range = source.htmlSourceRange(
      of: selection.text, occurrence: selection.occurrence, in: html)
    return .html(selection.text, range: range, in: html, path: path)
  }
}

extension HTMLSelection {
  /// `text` with whitespace runs folded to one space and trimmed, as the page compares it.
  static func folded(_ text: String) -> String {
    text.unicodeScalars
      .split(whereSeparator: { $0.value <= 0x20 })
      .map { String(String.UnicodeScalarView($0)) }
      .joined(separator: " ")
  }
}

/// The rendered HTML with the web preview's toolbar: find in the page, zoom that scales only
/// the document, as browser zoom does, and with a review, comments on the selected text.
struct HTMLPreviewPane: View {
  let html: String
  var comments: HTMLPreviewReview?
  @State private var zoom = 1.0
  @State private var query = ""
  @State private var find = HTMLFindRequest()
  /// The last find matched nothing.
  @State private var missed = false
  /// The selected text, to comment on.
  @State private var selection: HTMLSelection?

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      HTMLPreview(
        html: html, zoom: zoom, find: find, found: { missed = !$0 },
        commenting: comments.map { comments in
          HTMLPreviewCommenting(
            marks: comments.marks, activeID: comments.selectedCommentID.wrappedValue,
            received: received)
        })
    }
    .onChange(of: html) {
      zoom = 1
      missed = false
      selection = nil
    }
  }

  private var toolbar: some View {
    HStack(spacing: 6) {
      TextField("Find", text: $query)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 220)
        .onSubmit { search(backwards: false) }
        .onChange(of: query) { missed = false }
        .accessibilityIdentifier("workspace.html.find")
      ControlGroup {
        Button("Previous Match", systemImage: "chevron.up") { search(backwards: true) }
        Button("Next Match", systemImage: "chevron.down") { search(backwards: false) }
      }
      .labelStyle(.iconOnly)
      .controlSize(.small)
      .fixedSize()
      .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
      if missed {
        Text("No matches").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let comments, comments.review.canComment {
        commentButton(comments)
      }
      Button {
        zoom = 1
      } label: {
        Text(PDFPreviewView.percent(zoom)).monospacedDigit().frame(minWidth: 40)
      }
      .buttonStyle(.borderless)
      .disabled(zoom == 1)
      .help("Reset zoom")
      .accessibilityLabel("Reset zoom")
      ControlGroup {
        Button("Zoom Out", systemImage: "minus.magnifyingglass") {
          zoom = HTMLPreviewZoom.zoomedOut(zoom)
        }
        .disabled(zoom <= (HTMLPreviewZoom.levels.first ?? zoom))
        Button("Zoom In", systemImage: "plus.magnifyingglass") {
          zoom = HTMLPreviewZoom.zoomedIn(zoom)
        }
        .disabled(zoom >= (HTMLPreviewZoom.levels.last ?? zoom))
      }
      .labelStyle(.iconOnly)
      .controlSize(.small)
      .fixedSize()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
  }

  private func commentButton(_ comments: HTMLPreviewReview) -> some View {
    Button("Comment", systemImage: "text.bubble") {
      if let selection { comments.comment(comments.span(selection, in: html)) }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .disabled(selection == nil || comments.isDirty)
    .help(
      comments.isDirty
        ? "Save your changes to comment on a selection."
        : selection == nil ? "Select text to comment on it" : "Add a comment"
    )
    .accessibilityIdentifier("workspace.html.comment")
  }

  /// What the reader did in the page, as the web's viewer handles its bridge.
  private func received(_ message: HTMLBridgeMessage) {
    guard let comments else { return }
    switch message {
    case .ready:
      break
    case .selection(let selected):
      // Selecting text a comment is already on selects that comment instead.
      if let existing = comments.existingComment(on: selected) {
        selection = nil
        comments.show(existing.id)
      } else {
        selection = selected
      }
    case .commentClick(let id):
      selection = nil
      comments.show(id)
    case .selectionCleared:
      selection = nil
      comments.selectedCommentID.wrappedValue = nil
    case .zoom(let key):
      zoom = HTMLPreviewZoom.zoomed(zoom, by: key)
    }
  }

  private func search(backwards: Bool) {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    find = HTMLFindRequest(query: text, backwards: backwards, id: find.id + 1)
  }
}

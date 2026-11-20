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
}

/// A find in the HTML preview; a new `id` runs it again (Return steps to the next match).
struct HTMLFindRequest: Equatable {
  var query = ""
  var backwards = false
  var id = 0
}

/// The rendered HTML with the web preview's toolbar: find in the page, and zoom that scales only
/// the document, as browser zoom does.
struct HTMLPreviewPane: View {
  let html: String
  @State private var zoom = 1.0
  @State private var query = ""
  @State private var find = HTMLFindRequest()
  /// The last find matched nothing.
  @State private var missed = false

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      HTMLPreview(html: html, zoom: zoom, find: find) { missed = !$0 }
    }
    .onChange(of: html) {
      zoom = 1
      missed = false
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

  private func search(backwards: Bool) {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    find = HTMLFindRequest(query: text, backwards: backwards, id: find.id + 1)
  }
}

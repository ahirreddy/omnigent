import SwiftUI

/// A Markdown file rendered, with the web preview's table of contents ("On this page"): its
/// headings, filtered as typed, each scrolling the preview to its section. The contents show
/// beside the preview, or in a sheet on a narrow width, where choosing a heading closes it.
struct MarkdownPreviewPane: View {
  let text: String
  let markdown: (String) -> AnyView
  @AppStorage("workspace.markdownContents") private var showsContents = false
  @State private var filter = ""
  @State private var target: Int?
  @State private var width: CGFloat = 0
  /// The contents sheet on a narrow width; it opens each time it is asked for, not on its own.
  @State private var showsSheet = false

  /// Too narrow for the contents beside the text.
  private var isNarrow: Bool { width > 0 && width < 600 }

  var body: some View {
    let outline = MarkdownOutline(text)
    VStack(spacing: 0) {
      if !outline.headings.isEmpty { toolbar }
      ScrollViewReader { proxy in
        let scroll: (Int) -> Void = { id in
          target = id
          withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
        HStack(spacing: 0) {
          ScrollView {
            // A section's heading is its first block, so the gap stands in for its top margin.
            VStack(alignment: .leading, spacing: 16) {
              ForEach(outline.sections) { section in
                markdown(section.text).id(section.id)
              }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          if showsContents, !isNarrow, !outline.headings.isEmpty {
            Divider()
            contents(outline, scrollTo: scroll).frame(width: 260)
          }
        }
        .sheet(isPresented: $showsSheet) {
          contents(outline) { id in
            showsSheet = false
            scroll(id)
          }
          .presentationDetents([.medium, .large])
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }

  /// The contents beside the text, or the sheet on a narrow width.
  private var shownBinding: Binding<Bool> {
    Binding(
      get: { isNarrow ? showsSheet : showsContents },
      set: { shown in
        if isNarrow { showsSheet = shown } else { showsContents = shown }
      })
  }

  private var toolbar: some View {
    HStack {
      Spacer()
      Toggle(isOn: shownBinding) {
        Label("Contents", systemImage: "list.bullet.indent")
      }
      .toggleStyle(.button)
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help(shownBinding.wrappedValue ? "Hide the table of contents" : "Show the table of contents")
      .accessibilityIdentifier("workspace.markdown.contents")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
  }

  private func contents(_ outline: MarkdownOutline, scrollTo: @escaping (Int) -> Void)
    -> some View
  {
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    let shown = outline.headings.filter {
      query.isEmpty || ($0.title ?? "").lowercased().contains(query)
    }
    let base = outline.headings.map(\.level).min() ?? 1
    return VStack(alignment: .leading, spacing: 8) {
      Text("On this page").font(.headline)
      TextField("Filter headings", text: $filter)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("workspace.markdown.contentsFilter")
      if shown.isEmpty {
        Text("No matching headings")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.top, 8)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(shown) { heading in
            Button {
              scrollTo(heading.id)
            } label: {
              Text(heading.title ?? "")
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fontWeight(target == heading.id ? .medium : .regular)
                .foregroundStyle(target == heading.id ? .primary : .secondary)
                .padding(.leading, CGFloat(heading.level - base) * 12)
                .padding(.vertical, 3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .font(.callout)
    .padding(12)
    .frame(maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace.markdown.toc")
  }
}

import SwiftUI

/// Find in the terminal's screen and scrollback, backed by Ghostty's search.
struct TerminalFindBar: View {
  let controller: TerminalSurfaceController
  @State private var needle = ""
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Find", text: $needle)
        .textFieldStyle(.plain)
        .focused($focused)
        .onSubmit { controller.searchNext() }
        .onChange(of: needle) { _, value in controller.updateSearch(value) }
        .accessibilityLabel("Find in terminal")
      if let total = controller.search?.total {
        Text(matchText(total: total, selected: controller.search?.selected))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Button("Previous match", systemImage: "chevron.up") {
        controller.searchNext(backwards: true)
      }
      .labelStyle(.iconOnly)
      Button("Next match", systemImage: "chevron.down") { controller.searchNext() }
        .labelStyle(.iconOnly)
      Button("Close find", systemImage: "xmark") { controller.endSearch() }
        .labelStyle(.iconOnly)
        .keyboardShortcut(.cancelAction)
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: 420)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .onAppear {
      needle = controller.search?.needle ?? ""
      focused = true
    }
  }

  private func matchText(total: Int, selected: Int?) -> String {
    guard total > 0 else { return "No matches" }
    if let selected { return "\(selected + 1) of \(total)" }
    return "\(total) matches"
  }
}

import SwiftUI

/// Settings › Appearance › Show in agent pickers, as the web's: a summary of what the pickers
/// show, Edit (a checklist of the server's harnesses and agents) and Show all.
struct PickerVisibilitySetting: View {
  let source: PickerVisibilitySource
  @AppStorage(PickerVisibility.key) private var hiddenRaw: String?
  @State private var entries: [PickerVisibilityEntry] = []
  @State private var isLoaded = false
  @State private var failure: String?
  @State private var isEditing = false
  @State private var attempt = 0

  private var hidden: Set<String> { PickerVisibility.hiddenNames(hiddenRaw) }

  var body: some View {
    LabeledContent {
      HStack {
        if failure != nil, !isLoaded {
          Button("Retry") { attempt += 1 }
        }
        Button("Edit\u{2026}") { isEditing = true }
          .disabled(entries.isEmpty)
          .accessibilityLabel("Edit which agents the pickers show")
          .accessibilityIdentifier("settings.picker-visibility-edit")
        Button("Show All") { hiddenRaw = nil }
          .disabled(!entries.contains { hidden.contains($0.name) })
          .accessibilityLabel("Show all agents in the pickers")
          .accessibilityIdentifier("settings.picker-visibility-reset")
      }
    } label: {
      Text("Show in agent pickers")
      Text(
        "Choose which of this server's harnesses and agents appear when you start a chat or set "
          + "a project default. Existing sessions are unaffected, and the entry you have "
          + "selected always stays visible.")
      Text(summary)
        .foregroundStyle(ThemeColor.primary)
        .accessibilityIdentifier("settings.picker-visibility-summary")
    }
    .task(id: "\(source.server) \(attempt)") { await read() }
    .sheet(isPresented: $isEditing) {
      PickerVisibilityEditor(entries: entries, hiddenRaw: $hiddenRaw)
    }
  }

  private var summary: String {
    if isLoaded {
      return entries.isEmpty
        ? "No agents available on this server yet."
        : PickerVisibility.summary(entries, hidden: hidden)
    }
    return failure.map { "Couldn't load this server's harnesses and agents: \($0)" }
      ?? "Loading agents\u{2026}"
  }

  private func read() async {
    switch await source.load() {
    case .loaded(let loaded):
      entries = loaded
      isLoaded = true
      failure = nil
    case .failed(let message):
      failure = message
    }
  }
}

/// The checklist behind Edit: each harness and agent with a checkmark while it shows, filtered
/// by name.
private struct PickerVisibilityEditor: View {
  let entries: [PickerVisibilityEntry]
  @Binding var hiddenRaw: String?
  @State private var filter = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        ForEach(PickerVisibilityEntry.Group.allCases, id: \.self) { group in
          let rows = entries.filter { $0.group == group && matches($0) }
          if !rows.isEmpty {
            Section(group.rawValue) {
              ForEach(rows) { entry in
                Toggle(entry.title, isOn: shown(entry))
                  .accessibilityIdentifier("settings.picker-visibility-toggle-\(entry.name)")
              }
            }
          }
        }
      }
      .searchable(text: $filter, prompt: "Filter harnesses and agents")
      .navigationTitle("Show in Agent Pickers")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 360, minHeight: 420)
    #endif
  }

  private func matches(_ entry: PickerVisibilityEntry) -> Bool {
    filter.isEmpty || entry.title.localizedCaseInsensitiveContains(filter)
      || entry.name.localizedCaseInsensitiveContains(filter)
  }

  private func shown(_ entry: PickerVisibilityEntry) -> Binding<Bool> {
    Binding(
      get: { !PickerVisibility.hiddenNames(hiddenRaw).contains(entry.name) },
      set: { isShown in
        var names = PickerVisibility.hiddenNames(hiddenRaw)
        if isShown { names.remove(entry.name) } else { names.insert(entry.name) }
        let next = PickerVisibility.stored(names)
        if next != hiddenRaw { hiddenRaw = next }
      })
  }
}

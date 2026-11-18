public import SwiftUI

/// The caller's saved guidance for automatic session titles, as the server reports it.
nonisolated public enum TitleInstructionsState: Hashable, Sendable {
  /// Being read.
  case loading
  /// The read failed.
  case failed
  /// Read: the saved guidance (empty when none) and the server's limit in characters.
  case ready(saved: String, maxChars: Int)

  /// How many characters the server counts in `draft`: Unicode scalars once trimmed, so an
  /// emoji counts as one.
  public static func length(of draft: String) -> Int {
    draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
  }
}

/// Settings > Sessions: title instructions the server adds when it names the caller's sessions,
/// as the web's General > Sessions control.
struct SessionTitleInstructionsPane: View {
  let state: TitleInstructionsState
  let actions: ServerSettingsActions
  @State private var draft = ""
  @State private var isSaving = false
  @State private var notice: String?

  private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    Section {
      ZStack(alignment: .topLeading) {
        if draft.isEmpty {
          Text("e.g. Start every title with the ticket id, like OMNI-123.")
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
            .padding(.leading, 5)
            .allowsHitTesting(false)
        }
        TextEditor(text: $draft)
          .frame(minHeight: 96, maxHeight: 256)
          .scrollContentBackground(.hidden)
          .disabled(!isReady || isSaving)
          .accessibilityLabel("Title instructions")
          .accessibilityIdentifier("settings.session-title-instructions")
      }
      HStack {
        Text(status)
          .font(.callout)
          .foregroundStyle(isTooLong ? Theme.failure : .secondary)
          .accessibilityIdentifier("settings.session-title-instructions.status")
        Spacer()
        buttons
      }
      if let notice {
        Text(notice).font(.callout).foregroundStyle(.secondary)
      }
    } header: {
      Text("Title instructions")
    } footer: {
      Text(
        "Guidance for automatic session titles, such as a format, language or prefix. Leave "
          + "blank to use the server's title instructions, or the default prompt.")
    }
    .onChange(of: state, initial: true) { _, state in
      if case .ready(let saved, _) = state { draft = saved }
    }
  }

  @ViewBuilder private var buttons: some View {
    switch state {
    case .failed:
      if let retry = actions.load {
        Button("Retry") { retry(.sessions) }
          .accessibilityIdentifier("settings.session-title-instructions.retry")
      }
    case .ready(let saved, _):
      if !saved.isEmpty {
        // Clearing would also discard an unsaved draft.
        Button("Clear") { persist(nil) }
          .disabled(isSaving || isDirty)
          .accessibilityIdentifier("settings.session-title-instructions.clear")
      }
      Button(isSaving ? "Saving\u{2026}" : "Save") { persist(trimmed.isEmpty ? nil : trimmed) }
        .primaryActionStyle()
        .disabled(!isDirty || isTooLong || isSaving || actions.saveTitleInstructions == nil)
        .accessibilityIdentifier("settings.session-title-instructions.save")
    case .loading:
      EmptyView()
    }
  }

  private var isReady: Bool {
    if case .ready = state { return true }
    return false
  }

  private var isDirty: Bool {
    guard case .ready(let saved, _) = state else { return false }
    return trimmed != saved
  }

  private var isTooLong: Bool {
    guard case .ready(_, let maxChars) = state else { return false }
    return TitleInstructionsState.length(of: draft) > maxChars
  }

  private var status: String {
    switch state {
    case .loading: return "Loading\u{2026}"
    case .failed: return "Couldn't load your title instructions."
    case .ready(_, let maxChars):
      let count = TitleInstructionsState.length(of: draft)
      return count > maxChars
        ? "\(count) / \(maxChars) characters \u{2014} shorten to save"
        : "\(count) / \(maxChars) characters"
    }
  }

  private func persist(_ instructions: String?) {
    guard let save = actions.saveTitleInstructions else { return }
    isSaving = true
    notice = nil
    Task {
      let saved = await save(instructions)
      isSaving = false
      // A failure shows in the page's error line, which names the server's reason.
      if saved {
        notice = instructions == nil ? "Title instructions cleared" : "Title instructions saved"
      }
    }
  }
}

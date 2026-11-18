public import SwiftUI

/// The `/rewind` picker's state (the web's `RewindPicker`).
nonisolated public struct RewindPickerState: Hashable, Sendable {
  /// One prompt to continue from just before.
  public struct Prompt: Hashable, Sendable, Identifiable {
    /// The prompt's item id.
    public var id: String
    /// Its text; empty for a prompt of attachments only.
    public var text: String

    /// Creates a prompt.
    /// - Parameters:
    ///   - id: Item id.
    ///   - text: Text.
    public init(id: String, text: String) {
      self.id = id
      self.text = text
    }
  }

  /// Reading the newest prompts.
  public enum Phase: Hashable, Sendable {
    /// Being read.
    case loading
    /// Listed.
    case loaded
    /// They could not be read.
    case failed(String)
  }

  /// Older prompts.
  public enum Older: Hashable, Sendable {
    /// None remain.
    case none
    /// More can be read.
    case available
    /// Being read.
    case loading
    /// The last read failed; it can be tried again.
    case failed(String)
  }

  /// The newest batch.
  public var phase: Phase
  /// The prompts read so far, newest first.
  public var prompts: [Prompt]
  /// Older prompts.
  public var older: Older

  /// Creates a state.
  /// - Parameters:
  ///   - phase: The newest batch.
  ///   - prompts: Newest first.
  ///   - older: Older prompts.
  public init(phase: Phase, prompts: [Prompt] = [], older: Older = .none) {
    self.phase = phase
    self.prompts = prompts
    self.older = older
  }

  /// The prompts whose text contains every word of `query`, in any case; all for a blank one.
  public static func matching(_ prompts: [Prompt], query: String) -> [Prompt] {
    let words = query.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return prompts }
    return prompts.filter { prompt in
      words.allSatisfy { prompt.text.localizedCaseInsensitiveContains($0) }
    }
  }
}

/// The picker's actions.
public struct RewindPickerActions {
  /// Continues from just before the prompt with this id.
  public var choose: @MainActor (String) -> Void
  /// Reads the next older prompts.
  public var loadOlder: @MainActor () -> Void
  /// Closes the picker.
  public var dismiss: @MainActor () -> Void

  /// Creates actions.
  /// - Parameters:
  ///   - choose: Rewind to a prompt.
  ///   - loadOlder: Read older prompts.
  ///   - dismiss: Close.
  public init(
    choose: @escaping @MainActor (String) -> Void, loadOlder: @escaping @MainActor () -> Void,
    dismiss: @escaping @MainActor () -> Void
  ) {
    self.choose = choose
    self.loadOlder = loadOlder
    self.dismiss = dismiss
  }
}

/// The session's prompts, newest first and searchable. Choosing one continues the conversation
/// in a new chat from just before it, with the prompt ready to edit.
public struct RewindPickerSheet: View {
  private let state: RewindPickerState
  private let actions: RewindPickerActions
  @State private var query = ""
  @FocusState private var searchFocused: Bool

  /// Creates the sheet.
  /// - Parameters:
  ///   - state: The state.
  ///   - actions: The actions.
  public init(state: RewindPickerState, actions: RewindPickerActions) {
    self.state = state
    self.actions = actions
  }

  private var shown: [RewindPickerState.Prompt] {
    RewindPickerState.matching(state.prompts, query: query)
  }

  /// The sheet.
  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      TextField("Rewind to a prompt\u{2026}", text: $query)
        .textFieldStyle(.roundedBorder)
        .focused($searchFocused)
        .onSubmit { if let first = shown.first { actions.choose(first.id) } }
        .accessibilityIdentifier("rewind-search")
      content
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 360, alignment: .top)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: actions.dismiss)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(Theme.Spacing.large)
    .frame(minWidth: 460)
    .onAppear { searchFocused = true }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Rewind conversation")
    .accessibilityHint(
      "Choose a prompt. The conversation continues in a new chat from just before it, with the "
        + "prompt ready to edit."
    )
    .accessibilityIdentifier("rewind-picker")
  }

  @ViewBuilder private var content: some View {
    switch state.phase {
    case .loading:
      notice("Loading prompts\u{2026}")
    case .failed(let message):
      notice(message, failure: true)
    case .loaded:
      List {
        if shown.isEmpty {
          Text("No prompts to rewind to").foregroundStyle(.secondary)
        } else {
          Section("Continue from just before") {
            ForEach(shown) { prompt in
              Button {
                actions.choose(prompt.id)
              } label: {
                Text(Self.label(prompt))
                  .lineLimit(1)
                  .truncationMode(.tail)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("rewind-prompt-\(prompt.id)")
            }
          }
        }
        // Shown whatever the search, so an older prompt stays reachable.
        if let older = olderTitle {
          Button(older, action: actions.loadOlder)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(state.older == .loading)
            .accessibilityIdentifier("rewind-load-older")
        }
      }
      .listStyle(.plain)
    }
  }

  private var olderTitle: String? {
    switch state.older {
    case .none: nil
    case .available: "Load older prompts"
    case .loading: "Loading older prompts\u{2026}"
    case .failed(let message): "\(message) \u{2014} try again"
    }
  }

  /// A prompt's row: its text, or "(attachment)" for one with only files.
  static func label(_ prompt: RewindPickerState.Prompt) -> String {
    let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "(attachment)" : text
  }

  private func notice(_ text: String, failure: Bool = false) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(failure ? Theme.failure : .secondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Theme.Spacing.extraLarge)
  }
}

public import SwiftUI

/// The web's sandbox profile chip: the chosen profile's name, opening a searchable list of the
/// provider's profiles with their descriptions.
public struct SandboxProfilePicker: View {
  let state: SandboxProfilesState
  let actions: SandboxProfilesActions

  @State private var isOpen = false

  /// Creates the picker.
  public init(state: SandboxProfilesState, actions: SandboxProfilesActions) {
    self.state = state
    self.actions = actions
  }

  /// The chip.
  public var body: some View {
    Button {
      isOpen = true
    } label: {
      Label(state.label, systemImage: "shippingbox")
    }
    .fixedSize()
    .help("Sandbox profile")
    .accessibilityLabel("Sandbox profile, \(state.label)")
    .accessibilityIdentifier("sandbox-profile")
    .popover(isPresented: $isOpen) {
      SandboxProfileList(
        state: state, actions: actions, close: { isOpen = false }
      )
      .frame(width: 320, height: 320)
    }
  }
}

/// The profile list with its search field.
struct SandboxProfileList: View {
  let state: SandboxProfilesState
  let actions: SandboxProfilesActions
  let close: () -> Void

  @State private var search = ""
  @State private var results: Result<[SandboxProfileOption], FolderBrowseError>?
  @State private var isSearching = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if actions.search != nil {
        TextField("Search profiles", text: $search)
          .textFieldStyle(.roundedBorder)
          .padding(Theme.Spacing.small)
          .accessibilityIdentifier("sandbox-profile-search")
      }
      List {
        ForEach(rows) { profile in
          Button {
            actions.select(profile)
            close()
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(profile.name)
              if !profile.description.isEmpty {
                Text(profile.description).font(.caption).foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        if let status {
          Text(status).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let error = currentError {
        HStack {
          Text(error).font(.caption).foregroundStyle(Theme.failure)
          if let retry = actions.retry, results == nil {
            Button("Try Again", action: retry).controlSize(.small)
          }
        }
        .padding(Theme.Spacing.small)
      }
    }
    .task(id: search) { await runSearch() }
  }

  private var rows: [SandboxProfileOption] {
    if search.trimmingCharacters(in: .whitespaces).isEmpty { return state.profiles }
    if case .success(let found) = results { return found }
    return []
  }

  private var currentError: String? {
    if case .failure(let error) = results { return error.message }
    return search.isEmpty ? state.error : nil
  }

  private var status: String? {
    if isSearching || (search.isEmpty && state.isLoading) { return "Loading profiles\u{2026}" }
    if rows.isEmpty, currentError == nil {
      return search.isEmpty
        ? "No sandbox profiles available for this provider." : "No matching profiles."
    }
    if search.isEmpty, state.hasMore { return "Showing the first profiles. Search to find others." }
    return nil
  }

  private func runSearch() async {
    let text = search.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, let find = actions.search else {
      results = nil
      isSearching = false
      return
    }
    // Waits for typing to pause, as the web's 200 ms debounce.
    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
    isSearching = true
    let found = await find(text)
    // The text changed while this one was out, so its answer is out of date.
    guard !Task.isCancelled else { return }
    results = found
    isSearching = false
  }
}

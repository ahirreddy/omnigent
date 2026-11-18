import OmnigentPlatform
public import SwiftUI

/// "Share this automation": the people and groups each run's session is shared with, at Read
/// access only, as the web's dialog for an automation.
nonisolated public struct AutomationShareState: Hashable, Sendable {
  /// One grantee.
  public struct Person: Hashable, Sendable, Identifiable {
    /// The id or email sent to the server.
    public var id: String
    /// Their name; the id follows when it differs.
    public var name: String

    /// Creates a person.
    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  /// Who it is shared with.
  public var people: [Person]
  /// The automation continues one session, whose shares the list replaces on each run.
  public var continuesSession: Bool
  /// The list is being read.
  public var isLoading: Bool
  /// A change is in flight.
  public var isSaving: Bool
  /// Why the list could not be read or the last change failed.
  public var errorMessage: String?

  /// Creates the state.
  public init(
    people: [Person] = [], continuesSession: Bool = false, isLoading: Bool = false,
    isSaving: Bool = false, errorMessage: String? = nil
  ) {
    self.people = people
    self.continuesSession = continuesSession
    self.isLoading = isLoading
    self.isSaving = isSaving
    self.errorMessage = errorMessage
  }
}

/// The automation share sheet.
public struct AutomationShareSheet: View {
  private let state: AutomationShareState
  private let add: @MainActor (String) -> Void
  private let remove: @MainActor (String) -> Void
  private let done: @MainActor () -> Void
  @State private var newPerson = ""

  /// Creates the sheet.
  /// - Parameters:
  ///   - state: The grants.
  ///   - add: Share with a person or group.
  ///   - remove: Stop sharing with one.
  ///   - done: Close.
  public init(
    state: AutomationShareState, add: @escaping @MainActor (String) -> Void,
    remove: @escaping @MainActor (String) -> Void, done: @escaping @MainActor () -> Void
  ) {
    self.state = state
    self.add = add
    self.remove = remove
    self.done = done
  }

  /// The sheet.
  public var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Each run\u{2019}s session is shared with the people below, with Read access.")
            .foregroundStyle(.secondary)
          if state.continuesSession {
            Text(
              "Sharing it replaces the shares on the session it continues with this list, including people added there by hand, even at Edit or Manage. The owner and General access are kept."
            )
            .font(.callout).foregroundStyle(.secondary)
          }
        }
        Section("People") {
          if state.isLoading {
            LoadingCaption(title: "Loading\u{2026}")
          } else if state.people.isEmpty {
            Text("No grants yet.").foregroundStyle(.secondary)
          }
          ForEach(state.people) { person in
            HStack {
              AuthorAvatar(name: person.name)
              VStack(alignment: .leading) {
                Text(person.name)
                if person.name != person.id {
                  Text(person.id).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Text("Read").foregroundStyle(.secondary)
              Button("Remove", systemImage: "xmark.circle") { remove(person.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove access")
                .accessibilityLabel("Remove access")
                .accessibilityIdentifier("automation-share-remove-\(person.id)")
            }
          }
          HStack {
            TextField("Add people", text: $newPerson, prompt: Text("alice@example.com"))
              .textContentType(.emailAddress)
              .onSubmit(submit)
              .accessibilityIdentifier("automation-share-add-person")
            Button("Add", action: submit)
              .disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty)
              .accessibilityIdentifier("automation-share-add")
          }
          .disabled(state.isSaving)
        }
        if let error = state.errorMessage {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(Theme.failure)
              .textSelection(.enabled)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Share this automation")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: done).accessibilityIdentifier("automation-share-done")
        }
      }
    }
    #if os(macOS)
      .frame(width: 480, height: 460)
    #endif
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("automation-share-sheet")
  }

  private func submit() {
    let person = newPerson.trimmingCharacters(in: .whitespaces)
    guard !person.isEmpty else { return }
    add(person)
    newPerson = ""
  }
}

import Observation
import SwiftUI

/// The reader's open and closed choices for the transcript's folds, by the id of what each
/// fold opens. The table transcript keeps them here: its cells are reused for other rows, and a
/// row shown again in another cell starts its views afresh. Each choice is observed on its own,
/// so a fold the reader opens renders that fold alone.
@MainActor
@Observable
final class TranscriptDisclosures {
  /// One fold's choice.
  @MainActor
  @Observable
  final class Choice {
    // `nil` until the reader chooses: the fold follows its row (open while live, say).
    // swiftlint:disable:next discouraged_optional_boolean
    var isExpanded: Bool?
  }

  @ObservationIgnored private var choices: [String: Choice] = [:]
  /// Told after the reader opens or closes a fold, which changes its row's height.
  @ObservationIgnored var changed: () -> Void = {}

  /// The choice for `key`, made the first time it is asked for.
  func choice(_ key: String) -> Choice {
    if let choice = choices[key] { return choice }
    let choice = Choice()
    choices[key] = choice
    return choice
  }

  /// The reader's choice for `key`, `nil` before they made one, without making a ``Choice``
  /// to observe: for the table's AppKit cells, which read it for every row they show.
  func madeChoice(_ key: String) -> Bool? {  // swiftlint:disable:this discouraged_optional_boolean
    choices[key]?.isExpanded
  }

  /// Forgets every choice: another session opened.
  func reset() {
    choices = [:]
  }
}

extension EnvironmentValues {
  /// Where the transcript keeps its folds' choices; `nil` keeps each in its view's state.
  @Entry var transcriptDisclosures: TranscriptDisclosures?
}

/// A fold's open state: in the transcript's ``TranscriptDisclosures`` when it keeps them, else
/// in the view's own state. Its value is itself, to read and set by the fold's key.
@MainActor
@propertyWrapper
struct RowDisclosure: DynamicProperty {
  @Environment(\.transcriptDisclosures) private var store
  // swiftlint:disable:next discouraged_optional_boolean
  @State private var local: Bool?

  init() {}

  var wrappedValue: Self { self }

  /// The reader's choice for the fold `key`; `nil` before they made one.
  func choice(_ key: String) -> Bool? {  // swiftlint:disable:this discouraged_optional_boolean
    if let store { return store.choice(key).isExpanded }
    return local
  }

  /// Records the reader's choice for the fold `key`.
  func choose(_ isExpanded: Bool, for key: String) {
    if let store {
      store.choice(key).isExpanded = isExpanded
      store.changed()
    } else {
      local = isExpanded
    }
  }

  /// Forgets the reader's choice for the fold `key`, which follows its row again.
  func forget(_ key: String) {
    if let store {
      store.choice(key).isExpanded = nil
      store.changed()
    } else {
      local = nil
    }
  }

  /// A binding to the fold `key`'s open state, closed until the reader opens it.
  func binding(_ key: String) -> Binding<Bool> {
    Binding(get: { choice(key) ?? false }, set: { choose($0, for: key) })
  }
}

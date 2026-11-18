import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The `/rewind` picker's view state and actions over the composer's ``RewindPicker``.
enum RewindAdapter {
  static func state(_ picker: RewindPicker) -> RewindPickerState {
    let phase: RewindPickerState.Phase =
      switch picker.phase {
      case .loading: .loading
      case .loaded: .loaded
      case .failed(let message): .failed(message)
      }
    let older: RewindPickerState.Older =
      switch picker.older {
      case .loading: .loading
      case .failed(let message): .failed(message)
      case .idle: picker.olderCursor == nil ? .none : .available
      }
    return RewindPickerState(
      phase: phase,
      prompts: picker.prompts.map { RewindPickerState.Prompt(id: $0.itemId, text: $0.text) },
      older: older)
  }

  /// Choosing a prompt rewinds, then opens the new session; a warning about attachments that
  /// did not come back is reported once it opens.
  static func actions(
    _ picker: RewindPicker, composer: ComposerStore, open: @escaping @MainActor (String) -> Void,
    report: @escaping @MainActor (String) -> Void
  ) -> RewindPickerActions {
    RewindPickerActions(
      choose: { id in
        guard let prompt = picker.prompts.first(where: { $0.itemId == id }) else { return }
        Task {
          guard let outcome = await composer.rewind(to: prompt) else { return }
          open(outcome.sessionID)
          if let warning = outcome.warning { report(warning) }
        }
      },
      loadOlder: { Task { await picker.loadOlder() } },
      dismiss: { composer.dismissRewindPicker() })
  }
}

/// Shows the composer's `/rewind` picker, which reads its prompts as it opens.
struct SessionRewindPresenter: ViewModifier {
  let composer: ComposerStore
  /// Opens the session a rewind continues in.
  let open: @MainActor (String) -> Void
  let report: @MainActor (String) -> Void

  func body(content: Content) -> some View {
    content.sheet(
      item: Binding(
        get: { composer.rewindPicker },
        set: { if $0 == nil { composer.dismissRewindPicker() } })
    ) { picker in
      RewindPickerSheet(
        state: RewindAdapter.state(picker),
        actions: RewindAdapter.actions(picker, composer: composer, open: open, report: report)
      )
      .task { await picker.load() }
    }
  }
}

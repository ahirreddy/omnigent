import Foundation
import OmnigentStores

/// What an Add nested agent composer keeps while the user is elsewhere, by source session, so
/// its provisional row reopens it as it was: its choices (host, agent, model, folder, name)
/// and its files. Its text stays in ``CreationStore/composerDrafts``. Kept for the app's run,
/// as the web keeps them for the page load.
final class NestedComposerDrafts {
  private var forms: [String: NewSessionForm] = [:]
  private var files: [String: [PendingAttachment]] = [:]
  /// The files the store held for other composers while a nested one shows.
  private var outside: [PendingAttachment] = []
  /// The nested composer whose files the store holds now.
  private var shown: String?

  /// The composer's form beside `sourceID`: the kept one, or a new one kept from now on.
  func form(for sourceID: String) -> NewSessionForm {
    if let kept = forms[sourceID] { return kept }
    let form = NewSessionForm()
    forms[sourceID] = form
    return form
  }

  /// The composer beside `sourceID` shows: its files take the store's place. Another nested
  /// composer that has not left yet keeps its own; the others' wait for this one to leave.
  func arrive(_ sourceID: String, creation: CreationStore) {
    if let shown, shown != sourceID {
      keep(shown, creation)
    } else if shown == nil {
      outside += creation.takeAttachments()
    }
    creation.restoreAttachments(files.removeValue(forKey: sourceID) ?? [])
    shown = sourceID
  }

  /// The composer beside `sourceID` left: it keeps its files, and the others' come back. A
  /// page that is no nested composer, or not the one shown, changes nothing.
  func leave(_ sourceID: String?, creation: CreationStore?) {
    guard let sourceID, let creation, shown == sourceID else { return }
    keep(sourceID, creation)
    creation.restoreAttachments(outside)
    outside = []
    shown = nil
  }

  private func keep(_ sourceID: String, _ creation: CreationStore) {
    let mine = creation.takeAttachments()
    if forms[sourceID] != nil, !mine.isEmpty { files[sourceID] = mine }
  }

  /// Forgets the composer beside `sourceID`: it was created, or its draft deleted.
  func discard(_ sourceID: String) {
    forms[sourceID] = nil
    files[sourceID] = nil
  }
}

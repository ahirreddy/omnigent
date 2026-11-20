import OmnigentCoreFFI
import OmnigentStores

/// Run now from the list and the automation's page.
extension AutomationsAdapter {
  /// Starts a run of `id`, saying so as the web's toast; a run in flight is not an error.
  @MainActor @discardableResult
  static func runNow(
    _ pages: PagesStore, id: String, started: String, notify: @escaping @MainActor (String) -> Void
  ) async -> Bool {
    if await pages.runAutomation(id) {
      notify(started)
      return true
    }
    if case .HttpStatus(409, _) = pages.automationError {
      notify("This run is already in progress")
    } else {
      notify("Couldn\u{2019}t start the run")
    }
    pages.dismissAutomationError()
    return false
  }
}

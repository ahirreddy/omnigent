public import OmnigentCoreFFI

/// The new sandbox a session starts on, as far as reading its choices goes.
public struct NewSandboxChoice: Hashable, Sendable {
  /// The sandbox's provider; `nil` when the server names none.
  public var provider: String?

  /// Creates a choice.
  /// - Parameter provider: The provider.
  public init(provider: String?) {
    self.provider = provider
  }
}

extension CreationStore {
  /// Why `selection` cannot be created now (the core's validation against the loaded catalog
  /// and models), or `nil` when it can.
  /// - Parameter selection: The selection.
  /// - Returns: The reason to show.
  public func unavailableReason(_ selection: CreationSelection) -> String? {
    guard let catalog = catalog.value else { return "The host and agent list has not loaded." }
    return creationValidationError(
      catalog: catalog, selection: selection, models: models.value ?? [])
  }
}

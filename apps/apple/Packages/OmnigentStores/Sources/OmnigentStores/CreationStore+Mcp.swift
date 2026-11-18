import OmnigentCoreFFI

/// The server-configured MCP services a new session can start with (the web's
/// `useMcpRegistryCatalog`).
extension CreationStore {
  /// Reads the MCP registry's services once the catalog says the server has one; a server
  /// without it leaves them idle. A list already read stays shown while it reloads.
  public func loadMcpServices() async {
    guard catalog.value?.mcpRegistry == true else {
      mcpServices = .idle
      return
    }
    if mcpServices.value == nil { mcpServices = .loading }
    do {
      mcpServices = .loaded(try await core.mcpServices())
    } catch {
      mcpServices = .failed(coreError(error))
    }
  }
}

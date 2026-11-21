#if os(macOS)
  public import OmnigentBrowser
  import OmnigentWebLayer

  extension ChromiumConfiguration {
    /// The configuration with agents' DevTools pipe on. The host gets a pipe only the app
    /// holds; nothing listens until an agent's endpoint is asked for.
    public func withAgentDevTools() -> Self {
      var copy = self
      copy.session.agentDevTools = true
      return copy
    }
  }

  extension ChromiumBrowserEngine: BrowserAgentDevToolsGate {
    /// How long a host that is still starting may take before the endpoint fails.
    private static let readyWait = Duration.seconds(30)

    /// See `BrowserAgentDevToolsGate.agentDevToolsEndpoint(scope:)`.
    public func agentDevToolsEndpoint(scope: String) async throws(BrowserError)
      -> BrowserAgentDevToolsEndpoint
    {
      do throws(WebLayerError) {
        try await session.waitUntilReady(timeout: Self.readyWait)
        let endpoint = try await session.agentDevToolsEndpoint(scope: scope)
        return BrowserAgentDevToolsEndpoint(port: endpoint.port, path: endpoint.path)
      } catch {
        throw ChromiumBrowserTab.convert(error)
      }
    }

    /// See `BrowserAgentDevToolsGate.setAgentDevToolsScope(_:targets:)`.
    public func setAgentDevToolsScope(_ scope: String, targets: Set<String>) {
      session.setAgentDevToolsScope(scope, targets: targets)
    }

    /// See `BrowserAgentDevToolsGate.addAgentDevToolsTarget(_:scope:)`.
    public func addAgentDevToolsTarget(_ target: String, scope: String) {
      session.addAgentDevToolsTarget(target, scope: scope)
    }

    /// See `BrowserAgentDevToolsGate.closeAgentDevToolsEndpoint()`.
    public func closeAgentDevToolsEndpoint() {
      session.closeAgentDevToolsEndpoint()
    }
  }
#endif

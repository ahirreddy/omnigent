public import OmnigentCoreFFI

extension HostConfig {
  /// This build's policy: debug builds accept http to any host, release builds require https
  /// except for loopback. macOS signs in through a loopback listener, iOS through its
  /// registered scheme.
  public static var app: HostConfig { app(databricks: nil) }

  /// This build's policy, with the Databricks OAuth client read from the bundle (for servers in
  /// a Databricks workspace). Without one, those servers offer no sign-in method.
  /// - Parameter databricks: The public client id and HTTPS redirect, or `nil`.
  /// - Returns: The configuration.
  public static func app(databricks: DatabricksOAuthSettings?) -> HostConfig {
    #if DEBUG
      let policy = UrlPolicy.development
    #else
      let policy = UrlPolicy.release
    #endif
    #if os(macOS)
      return HostConfig(
        urlPolicy: policy, oidcRedirect: .loopback(path: "/oauth/callback"),
        databricks: databricks)
    #else
      return HostConfig(
        urlPolicy: policy,
        oidcRedirect: .privateScheme(redirectUri: "ai.omnigent.ios:/oauth/callback"),
        databricks: databricks)
    #endif
  }
}

extension AuthMode {
  /// A short user-facing name for the sign-in mode.
  public var displayName: String {
    switch self {
    case .oidc: "OpenID Connect"
    case .accounts: "Accounts"
    case .header: "Header"
    case .custom: "Custom"
    case .unauthenticated: "None"
    case .unknown(let value): "Unknown (\(value))"
    }
  }
}

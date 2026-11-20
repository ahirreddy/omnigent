import Foundation

/// What an opened MCP server row shows, as the web's tool probe has it.
public enum HarnessMcpProbe: Equatable, Sendable {
  /// The host is connecting to the server.
  case loading
  /// It isn't connected, or the probe failed: why.
  case notice(String)
  /// Connected: its tools, and whether only the first 500 are listed.
  case tools([HarnessMcpTool], truncated: Bool)
}

/// One tool an MCP server offers.
public struct HarnessMcpTool: Equatable, Sendable, Hashable {
  /// Its name.
  public var name: String
  /// What it does.
  public var description: String?

  /// Creates a tool.
  public init(name: String, description: String? = nil) {
    self.name = name
    self.description = description
  }
}

/// The connection badge on a probed MCP server's row.
public struct HarnessMcpStatus: Equatable, Sendable {
  /// How it went.
  public enum Tone: Equatable, Sendable {
    /// Connected.
    case connected
    /// Needs a sign-in.
    case attention
    /// Failed to connect.
    case failed
  }

  /// "Connected", "Needs auth" or "Failed to connect".
  public var label: String
  /// Its color.
  public var tone: Tone
  /// "3 tools" once connected.
  public var toolCount: String?

  /// Creates a status.
  public init(label: String, tone: Tone, toolCount: String? = nil) {
    self.label = label
    self.tone = tone
    self.toolCount = toolCount
  }
}

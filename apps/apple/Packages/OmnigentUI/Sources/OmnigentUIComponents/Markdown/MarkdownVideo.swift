import Foundation
import OmnigentWorkspaceUI
import SwiftUI

/// Where a recording a message links to plays from (the web's `isVideoFile` and
/// `isRemoteVideoUrl`): a workspace file, or a direct `http(s)` link to a video file.
nonisolated enum MarkdownVideoSource: Hashable {
  /// A workspace file, as cited.
  case workspace(String)
  /// A video file on the web.
  case remote(URL)

  /// The names the web plays as video.
  static let extensions: Set<String> = ["mp4", "webm", "mov", "m4v", "ogv"]

  init?(_ destination: String) {
    if let url = MarkdownParser.safeURL(destination) {
      guard url.scheme?.lowercased() != "mailto", Self.isVideoName(url.path()) else {
        return nil
      }
      self = .remote(url)
      return
    }
    guard let path = WorkspacePaths.linkedPath(destination), Self.isVideoName(path) else {
      return nil
    }
    self = .workspace(path)
  }

  /// Whether a path or URL path names a video, read up to a `?` or `#`.
  static func isVideoName(_ path: String) -> Bool {
    let name = path.split(separator: "/").last.map(String.init) ?? path
    let base = name.split(separator: "?", maxSplits: 1).first.map(String.init) ?? name
    let file = base.split(separator: "#", maxSplits: 1).first.map(String.init) ?? base
    guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return false }
    return extensions.contains(file[file.index(after: dot)...].lowercased())
  }
}

nonisolated extension MarkdownBlock {
  /// How an image or a video block reads as text where it isn't drawn: `[Image: alt]` or
  /// `[Video: title]`, naming the source instead of empty text when `namingSource`.
  func mediaLabel(namingSource: Bool) -> String {
    let (kind, text, source) =
      switch self {
      case .image(let source, let alt): ("Image", alt, source)
      case .video(let source, let title): ("Video", title, source)
      default: ("Media", "", "")
      }
    let shown = text.isEmpty && namingSource ? source : text
    return shown.isEmpty ? "[\(kind)]" : "[\(kind): \(shown)]"
  }
}

/// A recording a message links to, as the web's compact chat player: a workspace video streams
/// through the session's workspace and its name opens the file viewer; a remote one plays from
/// its URL. A link that can't play here shows as its title.
struct MarkdownVideoView: View {
  let source: String
  let title: String

  @Environment(\.workspaceFileLinks) private var links

  var body: some View {
    switch MarkdownVideoSource(source) {
    case .remote(let url):
      RemoteVideoView(url: url, title: title.isEmpty ? "Video recording" : title)
    case .workspace(let cited):
      if let links, let videoSource = links.videoSource, let path = links.videoPath(cited) {
        WorkspaceVideoView(
          path: path, source: videoSource, download: links.downloadVideo, compact: true,
          title: title
        ) {
          links.open(WorkspaceFileTarget(path: path))
        }
      } else {
        unplayable
      }
    case nil:
      unplayable
    }
  }

  private var unplayable: some View {
    Label(title.isEmpty ? source : title, systemImage: "video")
      .foregroundStyle(.secondary)
      .help(source)
  }
}

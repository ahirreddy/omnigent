import AVKit
public import SwiftUI

/// A workspace video as the web's `VideoPlayer` card shows it: its name and Download, then Play
/// recording, which streams the file into the system player; a recording with a chapters file
/// lists its chapters beside the player (below it when narrow), each seeking to its start.
public struct WorkspaceVideoView: View {
  private let path: String
  private let source: any WorkspaceDataSource
  private let download: ((String) -> Void)?
  private let compact: Bool
  private let openFile: (() -> Void)?
  @State private var playback = WorkspaceVideoPlayback()
  @State private var chapters = VideoChapters.none
  @State private var showsActions = true
  @State private var width: CGFloat = 0

  /// What a video that would not play says, as on the web.
  static let failureMessage =
    "This video couldn't be played. Download the file to open it in another app."
  /// Wider than this and the chapters sit beside the player.
  static let wideWidth: CGFloat = 640

  /// A player card.
  /// - Parameters:
  ///   - path: The environment-relative video.
  ///   - source: Reads it.
  ///   - download: Saves a file where the person picks; `nil` hides Download.
  ///   - compact: The small card the chat embeds.
  ///   - openFile: Opens the video in the file viewer, from its name; `nil` keeps the name plain.
  public init(
    path: String, source: any WorkspaceDataSource, download: ((String) -> Void)?,
    compact: Bool = false, openFile: (() -> Void)? = nil
  ) {
    self.path = path
    self.source = source
    self.download = download
    self.compact = compact
    self.openFile = openFile
  }

  /// The view.
  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      let wide = width >= Self.wideWidth
      let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
      layout {
        stage
        if showsChapters {
          Divider()
          ChapterList(
            chapters: chapters.chapters, time: playback.time, duration: playback.duration,
            failed: playback.phase == .failed
          ) { seconds in
            playback.seek(to: seconds, read: reader)
          }
          .frame(width: wide ? 288 : nil)
          .frame(maxHeight: wide ? .infinity : 288)
        }
      }
    }
    .background(.background.secondary)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    .frame(maxWidth: compact ? 320 : 1024)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .task(id: path) {
      playback.stop()
      chapters = await source.videoChapters(path)
    }
    .onDisappear { playback.stop() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace.video")
  }

  private var title: String { WorkspacePaths.name(of: path) }

  private var showsChapters: Bool { !compact && !chapters.chapters.isEmpty && showsActions }

  /// Reads the video's bytes for the player.
  private var reader: WorkspaceVideoLoader.Read {
    let source = source
    let path = path
    return { offset, length throws(WorkspaceFailure) in
      try await source.readVideo(path, offset: offset, length: length)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "video")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      if let openFile {
        Button(title, action: openFile)
          .buttonStyle(.plain)
          .underline(pattern: .dot)
          .lineLimit(1)
          .help(title)
      } else {
        Text(title)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(title)
      }
      Spacer(minLength: 8)
      if let download {
        if let file = chapters.file {
          Menu {
            Button("Download video") { download(path) }
            Button("Download annotations (.vtt)") { download(file) }
          } label: {
            Image(systemName: "arrow.down.to.line")
              .accessibilityLabel("Download recording: \(title)")
          }
          .menuStyle(.button)
          .buttonStyle(.borderless)
          .fixedSize()
          .help("Download recording")
          .accessibilityIdentifier("workspace.video.download")
        } else {
          Button("Download video: \(title)", systemImage: "arrow.down.to.line") { download(path) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Download video")
            .accessibilityIdentifier("workspace.video.download")
        }
      }
      if !compact, !chapters.chapters.isEmpty {
        Button(
          showsActions ? "Hide recording actions" : "Show recording actions",
          systemImage: showsActions ? "sidebar.right" : "sidebar.squares.right"
        ) {
          showsActions.toggle()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(showsActions ? "Collapse actions" : "Expand actions")
        .accessibilityIdentifier("workspace.video.actions-toggle")
      }
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .frame(minHeight: 44)
  }

  @ViewBuilder private var stage: some View {
    ZStack {
      switch playback.phase {
      case .idle:
        Button {
          playback.play(reader)
        } label: {
          VStack(spacing: 10) {
            Image(systemName: "play.fill")
              .font(.largeTitle)
            Text("Play recording")
          }
          .padding(16)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Play video: \(title)")
        .accessibilityIdentifier("workspace.video.play")
      case .loading, .ready:
        if let player = playback.player {
          VideoPlayer(player: player)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityIdentifier("workspace.video.player")
        }
        if playback.phase == .loading {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading video\u{2026}")
          }
          .padding(8)
          .background(.regularMaterial, in: Capsule())
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("workspace.video.loading")
        }
      case .failed:
        VStack(spacing: 12) {
          Image(systemName: "video.slash")
            .font(.title)
            .accessibilityHidden(true)
          Text(Self.failureMessage)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("workspace.video.failure")
          HStack(spacing: 8) {
            if let download {
              Button("Download") { download(path) }
            }
            Button("Retry") { playback.stop() }
          }
          .buttonStyle(.bordered)
        }
        .foregroundStyle(.secondary)
        .padding(16)
      }
    }
    .frame(maxWidth: .infinity)
    .aspectRatio(compact ? 1.6 : 16.0 / 9.0, contentMode: .fit)
    .background(playback.phase == .idle || playback.phase == .failed ? Color.clear : .black)
  }
}

/// The chapters of a recording: each one's title and start; the current one marked.
private struct ChapterList: View {
  let chapters: [VideoChapter]
  let time: Double
  let duration: Double?
  let failed: Bool
  let seek: (Double) -> Void

  var body: some View {
    let current = chapters.lastIndex { $0.time <= time && time < $0.end }
    ScrollView {
      VStack(spacing: 2) {
        ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
          Button {
            seek(chapter.time)
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: "play")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
              Text(chapter.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
              Text(WorkspaceVideoTime.clock(chapter.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(
              index == current ? Color.accentColor.opacity(0.15) : .clear,
              in: RoundedRectangle(cornerRadius: 6))
          }
          .buttonStyle(.plain)
          .disabled(failed || duration.map { chapter.time >= $0 } == true)
          .accessibilityValue(index == current ? "Current" : "")
          .accessibilityIdentifier("workspace.video.chapter")
        }
      }
      .padding(8)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Recording actions")
  }
}

/// Times as the web's `formatVideoTime` writes them.
nonisolated enum WorkspaceVideoTime {
  /// `m:ss`, the whole seconds of `seconds`.
  static func clock(_ seconds: Double) -> String {
    let whole = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
    let remainder = whole % 60
    return "\(whole / 60):\(remainder < 10 ? "0" : "")\(remainder)"
  }
}

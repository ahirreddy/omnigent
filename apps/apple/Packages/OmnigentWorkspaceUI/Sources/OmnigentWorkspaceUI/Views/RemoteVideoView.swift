import AVKit
import Combine
public import SwiftUI

/// A direct link to a video file on the web as the web's compact `VideoPlayer` shows it: its
/// title and Open in Browser, then Play video. Nothing is fetched before Play; a video that
/// won't play offers the browser instead.
public struct RemoteVideoView: View {
  private let url: URL
  private let title: String
  @State private var player: AVPlayer?
  @State private var failed = false
  @Environment(\.openURL) private var openURL

  /// What a remote video that would not play says.
  static let failureMessage = "This video couldn't be played here."

  /// A player card.
  /// - Parameters:
  ///   - url: The video file.
  ///   - title: The link's text.
  public init(url: URL, title: String) {
    self.url = url
    self.title = title
  }

  /// The view.
  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      stage
    }
    .background(.background.secondary)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    .frame(maxWidth: 320)
    .onDisappear { stop() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("remote.video")
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "video")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(url.absoluteString)
      Spacer(minLength: 8)
      Button("Open in Browser", systemImage: "safari") { openURL(url) }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Open in Browser")
        .accessibilityIdentifier("remote.video.open")
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .frame(minHeight: 44)
  }

  @ViewBuilder private var stage: some View {
    ZStack {
      if failed {
        VStack(spacing: 12) {
          Image(systemName: "video.slash")
            .font(.title)
            .accessibilityHidden(true)
          Text(Self.failureMessage)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("remote.video.failure")
          Button("Open in Browser") { openURL(url) }
            .buttonStyle(.bordered)
        }
        .foregroundStyle(.secondary)
        .padding(16)
      } else if let player {
        VideoPlayer(player: player)
          .accessibilityElement(children: .contain)
          .accessibilityLabel(title)
          .accessibilityIdentifier("remote.video.player")
          .onReceive(player.publisher(for: \.currentItem?.status)) { status in
            if status == .failed { fail() }
          }
      } else {
        Button("Play video", systemImage: "play.fill", action: play)
          .buttonStyle(.bordered)
          .controlSize(.large)
          .accessibilityLabel("Play video: \(title)")
          .accessibilityIdentifier("remote.video.play")
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: WorkspaceVideoView.compactStageHeight)
    .background(player == nil || failed ? Color.clear : .black)
  }

  private func play() {
    let player = AVPlayer(url: url)
    self.player = player
    player.play()
  }

  private func fail() {
    stop()
    failed = true
  }

  private func stop() {
    player?.pause()
    player = nil
  }
}

import Foundation
import OmnigentBrowser
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The page an agent drives, mirrored read-only: a screenshot refreshed every second, so the
/// agent's page never leaves its off-screen panel and no input can reach it.
struct AgentBrowserMirror: View {
  let tab: any BrowserTab
  var refreshInterval: Duration = .seconds(1)

  @State private var image: Image?
  @State private var failure: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label("The agent is browsing. This view is read-only.", systemImage: "eye")
        Spacer()
        Text(tab.state.url?.absoluteString ?? "")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.callout)
      .padding(8)
      Divider()
      Group {
        if let image {
          image.resizable().scaledToFit()
            .accessibilityLabel("The page the agent is on")
        } else if let failure {
          ContentUnavailableView(
            "No Picture of the Page", systemImage: "exclamationmark.triangle",
            description: Text(failure))
        } else {
          ProgressView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationTitle(tab.state.title.isEmpty ? "Agent Browser" : tab.state.title)
    .accessibilityIdentifier("agent-browser-tab")
    .task { await refresh() }
  }

  private func refresh() async {
    while !Task.isCancelled {
      do {
        let data = try await tab.takeSnapshotPNG()
        if let decoded = Self.image(from: data) {
          image = decoded
          failure = nil
        } else {
          // Without this the page would show a spinner forever.
          failure = "The page's picture could not be read."
        }
      } catch {
        failure = error.localizedDescription
      }
      do {
        try await Task.sleep(for: refreshInterval)
      } catch {
        break
      }
    }
  }

  /// The decoded snapshot, or `nil` when the platform cannot decode it.
  static func image(from data: Data) -> Image? {
    #if os(macOS)
      NSImage(data: data).map(Image.init(nsImage:))
    #else
      UIImage(data: data).map(Image.init(uiImage:))
    #endif
  }
}

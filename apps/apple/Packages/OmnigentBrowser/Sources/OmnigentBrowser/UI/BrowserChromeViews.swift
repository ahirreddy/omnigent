public import SwiftUI

#if os(macOS)
  internal import AppKit
#endif

/// The certificate-error interstitial shown over the page. Proceeding is offered only when the
/// error is overridable and the app allows overrides.
struct BrowserCertificateInterstitial: View {
  let prompt: BrowserCertificatePrompt
  let allowsProceeding: Bool
  let resolve: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Your connection is not private", systemImage: "exclamationmark.shield.fill")
        .font(.title2.bold())
        .foregroundStyle(.red)
      Text(
        "\(prompt.url?.host(percentEncoded: false) ?? "This site") may be impersonating the real site. \(prompt.message)"
      )
      .textSelection(.enabled)
      if !prompt.subject.isEmpty || !prompt.issuer.isEmpty {
        Text(
          "Certificate: \(prompt.subject), issued by \(prompt.issuer). Error \(prompt.errorCode)."
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      }
      HStack {
        Button("Go Back") { resolve(false) }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("browser.certificate.back")
        if prompt.isOverridable, allowsProceeding {
          Button("Proceed to \(prompt.url?.host(percentEncoded: false) ?? "the site") (unsafe)") {
            resolve(true)
          }
          .accessibilityIdentifier("browser.certificate.proceed")
        }
      }
    }
    .padding(32)
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .accessibilityIdentifier("browser.certificate.interstitial")
  }
}

/// "Popup blocked" with a way to open it anyway.
struct BrowserBlockedPopupBanner: View {
  let blocked: BrowserBlockedPopup
  let open: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Label(
        "Popup blocked: \(blocked.url?.absoluteString ?? "a window")",
        systemImage: "rectangle.on.rectangle.slash"
      )
      .lineLimit(1)
      if blocked.url != nil {
        Button("Open", action: open)
      }
      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
    }
    .font(.callout)
    .padding(8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .padding(8)
    .accessibilityIdentifier("browser.popupBlocked")
  }
}

/// Toolbar button that shows the downloads list.
struct BrowserDownloadsButton: View {
  let presenter: BrowserPromptPresenter
  @State private var showing = false

  var body: some View {
    Button("Downloads", systemImage: "arrow.down.circle") { showing.toggle() }
      .popover(isPresented: $showing) {
        BrowserDownloadsView(
          center: presenter.downloadCenter, settings: presenter.downloadSettings
        )
        .frame(width: 380, height: 320)
      }
      .accessibilityIdentifier("browser.downloads")
  }
}

/// The downloads list with progress, Reveal in Finder, Cancel, and the download settings.
public struct BrowserDownloadsView: View {
  private let center: BrowserDownloadCenter
  @Bindable private var settings: BrowserDownloadSettings
  private let profileIdentifier: String?

  /// Creates the view.
  /// - Parameters:
  ///   - center: The downloads.
  ///   - settings: Folder and ask-first settings.
  ///   - profileIdentifier: Shows only that profile's downloads; nil shows all.
  public init(
    center: BrowserDownloadCenter, settings: BrowserDownloadSettings,
    profileIdentifier: String? = nil
  ) {
    self.center = center
    self.settings = settings
    self.profileIdentifier = profileIdentifier
  }

  /// The view body.
  public var body: some View {
    let items = profileIdentifier.map(center.items(profileIdentifier:)) ?? center.items
    VStack(alignment: .leading, spacing: 0) {
      if items.isEmpty {
        ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
      } else {
        List(items) { download in
          BrowserDownloadRow(download: download)
        }
      }
      Divider()
      BrowserDownloadSettingsView(settings: settings)
        .padding(10)
    }
    .accessibilityIdentifier("browser.downloadsList")
  }
}

struct BrowserDownloadRow: View {
  let download: BrowserDownload
  @State private var error: BrowserError?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(download.destination.lastPathComponent).lineLimit(1)
        Spacer()
        if download.state.isFinal {
          #if os(macOS)
            if download.state == .complete {
              Button("Show in Finder", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([download.destination])
              }
              .labelStyle(.iconOnly)
            }
          #endif
        } else {
          Button("Cancel", systemImage: "xmark.circle") {
            do throws(BrowserError) {
              try download.cancel()
            } catch let failure {
              error = failure
            }
          }
          .labelStyle(.iconOnly)
        }
      }
      if let fraction = download.fractionCompleted {
        ProgressView(value: fraction)
      } else if !download.state.isFinal {
        ProgressView().progressViewStyle(.linear)
      }
      Text(statusText).font(.caption).foregroundStyle(.secondary)
      if let error {
        Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
      }
    }
    .buttonStyle(.borderless)
  }

  private var statusText: String {
    let received = ByteCountFormatter.string(
      fromByteCount: download.receivedBytes, countStyle: .file)
    switch download.state {
    case .inProgress:
      let total = download.totalBytes.map {
        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
      }
      return total.map { "\(received) of \($0)" } ?? received
    case .paused: return "Paused at \(received)"
    case .complete: return "Done, \(received)"
    case .cancelled: return "Cancelled"
    case .failed(let reason): return "Failed: \(reason)"
    }
  }
}

/// Save folder and ask-first switch.
public struct BrowserDownloadSettingsView: View {
  @Bindable private var settings: BrowserDownloadSettings

  /// Creates the view.
  public init(settings: BrowserDownloadSettings) {
    self.settings = settings
  }

  /// The view body.
  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Save to \(settings.directory.lastPathComponent)").lineLimit(1)
        #if os(macOS)
          Button("Change…") { chooseFolder() }
        #endif
      }
      Toggle("Ask where to save each download", isOn: $settings.askBeforeDownload)
        .accessibilityIdentifier("browser.downloads.ask")
    }
    .font(.callout)
  }

  #if os(macOS)
    private func chooseFolder() {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.directoryURL = settings.directory
      if panel.runModal() == .OK, let url = panel.url {
        settings.directory = url
      }
    }
  #endif
}

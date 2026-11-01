internal import AppKit
internal import Foundation
internal import OmnigentWebLayer
internal import SwiftUI

/// Sample host for the Omnigent Web Layer.
///
/// Arguments:
/// - `--url <url>`: first page (default https://example.com).
/// - `--render-mode remoteLayer|ioSurface`: rendering path (default remoteLayer).
/// - `--proof <name>[,<name>...]`: runs proof scenarios, logs results and quits. See `Proofs`.
/// - `--output <dir>`: where proofs write screenshots (default /private/tmp/claude-502).
@main
struct WebLayerExampleApp: App {
  @State private var model = ExampleModel()

  var body: some Scene {
    WindowGroup("Omnigent Web Layer Example") {
      ExampleRoot(model: model)
        .frame(minWidth: 1000, minHeight: 720)
        .task { await model.runProofsIfRequested() }
    }
    .commands {
      CommandMenu("Probe") {
        Button("Unhandled Key Probe") { model.unhandledKeyProbeFired() }
          .keyboardShortcut("u", modifiers: [.command, .shift])
      }
    }
  }
}

@Observable
final class ExampleModel {
  let session: Session
  let profile: Profile
  let webView: WebView
  let options: ExampleOptions
  private(set) var log: [String] = []
  private(set) var unhandledProbeCount = 0
  private var loggedFirstPaint = false

  init() {
    let options = ExampleOptions(arguments: ProcessInfo.processInfo.arguments)
    self.options = options
    var configuration = SessionConfiguration.standard()
    configuration.renderMode = options.renderMode
    session = Session(configuration: configuration)
    profile = session.profile(identifier: "example", persistence: .persistent)
    webView = profile.makeWebView(initialURL: options.url)
    Clock.log("app model created; starting host (\(options.renderMode.rawValue))")
    session.start()
    Clock.log("session.start() returned; state \(session.state)")
    webView.onEvent = { event in Clock.log("view event: \(event)") }
  }

  func uiDidAppear() {
    guard !loggedFirstPaint else { return }
    loggedFirstPaint = true
    Clock.log("first UI paint; host state \(session.state)")
  }

  func unhandledKeyProbeFired() {
    unhandledProbeCount += 1
    Clock.log("Probe menu item fired via unhandled key (count \(unhandledProbeCount))")
  }

  func runProofsIfRequested() async {
    guard !options.proofs.isEmpty else { return }
    let proofs = Proofs(model: self)
    let failures = await proofs.run(options.proofs)
    Clock.log(failures == 0 ? "PROOFS PASSED" : "PROOFS FAILED: \(failures)")
    if options.keepOpen { return }
    if failures > 0 {
      session.shutdown()
      exit(1)
    }
    NSApp.terminate(nil)
  }
}

struct ExampleOptions {
  var url = URL(string: "https://example.com")
  var renderMode = RenderMode.remoteLayer
  var proofs: [String] = []
  var output = URL(fileURLWithPath: "/private/tmp/claude-502", isDirectory: true)
  var keepOpen = false

  init(arguments: [String]) {
    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--url": url = iterator.next().flatMap(URL.init(string:))
      case "--render-mode": renderMode = iterator.next().flatMap(RenderMode.init) ?? .remoteLayer
      case "--proof": proofs = (iterator.next() ?? "").split(separator: ",").map(String.init)
      case "--output": output = URL(fileURLWithPath: iterator.next() ?? ".", isDirectory: true)
      case "--keep-open": keepOpen = true
      default: break
      }
    }
  }
}

/// Timestamps relative to process start, printed to stdout.
enum Clock {
  static let start = ContinuousClock.now

  static var elapsedMilliseconds: Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds)
      / 1e15
  }

  static func log(_ message: String) {
    let stamp = elapsedMilliseconds.formatted(
      .number.precision(.fractionLength(1)).grouping(.never))
    let line = "OWL t=\(stamp)ms \(message)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
  }
}

struct ExampleRoot: View {
  let model: ExampleModel
  @State private var address = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Back", systemImage: "chevron.backward") { model.webView.goBack() }
          .disabled(!model.webView.canGoBack)
        Button("Forward", systemImage: "chevron.forward") { model.webView.goForward() }
          .disabled(!model.webView.canGoForward)
        Button("Reload", systemImage: "arrow.clockwise") { model.webView.reload() }
        TextField("Address", text: $address)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            if let url = URL(string: address) { model.webView.load(url) }
          }
        Text(statusText)
          .font(.caption.monospaced())
          .lineLimit(1)
      }
      .labelStyle(.iconOnly)
      .padding(8)
      Divider()
      WebLayerContent(webView: model.webView)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear { model.uiDidAppear() }
    .onChange(of: model.webView.url, initial: true) { _, url in
      address = url?.absoluteString ?? ""
    }
  }

  private var statusText: String {
    switch model.session.state {
    case .idle: "idle"
    case .launching: "launching"
    case .ready(let info):
      "pid \(info.pid) \(info.renderMode.rawValue) Chromium \(info.chromiumVersion)"
    case .failed(let error), .crashed(let error): error.localizedDescription
    case .stopped: "stopped"
    }
  }
}

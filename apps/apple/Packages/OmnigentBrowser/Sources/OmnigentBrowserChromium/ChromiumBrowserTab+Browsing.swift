#if os(macOS)
  internal import AppKit
  internal import Foundation
  internal import OmnigentBrowser
  internal import OmnigentWebLayer
  internal import PDFKit

  /// Browsing state on Chromium, from protocol 1.2 hosts: favicons, audible state and mute,
  /// history, hard reload. Print goes through a PDF, so no print UI opens in the host.
  extension ChromiumBrowserTab {
    func reload(ignoringCache: Bool) { webView.reload(ignoringCache: ignoringCache) }

    func stopFinding() { webView.stopFinding() }

    func setZoomFactor(_ factor: Double) {
      // Chromium zoom levels are logarithmic: each step of 1 is 20%.
      webView.setZoomLevel(log(max(0.01, factor)) / log(1.2))
      syncState()
    }

    func setAudioMuted(_ muted: Bool) {
      webView.setAudioMuted(muted)
      syncState()
    }

    var navigationHistory: BrowserNavigationHistory {
      if let history = webView.navigationHistory, !history.entries.isEmpty {
        return BrowserNavigationHistory(
          entries: history.entries.map { BrowserNavigationEntry(url: $0.url, title: $0.title) },
          currentIndex: history.currentIndex)
      }
      // Hosts before 1.2 report no list; the current page is all there is.
      guard let url = webView.url else { return .empty }
      return BrowserNavigationHistory(
        entries: [BrowserNavigationEntry(url: url, title: webView.title)], currentIndex: 0)
    }

    var engineRestoreData: Data? { nil }

    func restoreEngineState(_ data: Data) -> Bool { false }

    func printPage() async throws(BrowserError) {
      guard let window = platformView.window else {
        throw .printFailed("The page is not in a window.")
      }
      let json: String
      do {
        json = try await webView.callDevToolsMethod(
          "Page.printToPDF", paramsJSON: #"{"printBackground":true}"#)
      } catch {
        throw Self.convert(error)
      }
      struct Result: Decodable { let data: String }
      let pdf: Data
      do {
        let result = try JSONDecoder().decode(Result.self, from: Data(json.utf8))
        guard let decoded = Data(base64Encoded: result.data) else {
          throw BrowserError.printFailed("Chromium returned PDF data that is not base64.")
        }
        pdf = decoded
      } catch let error as BrowserError {
        throw error
      } catch {
        throw .printFailed("Chromium's PDF reply is malformed: \(error.localizedDescription)")
      }
      guard let document = PDFDocument(data: pdf),
        let operation = document.printOperation(
          for: NSPrintInfo.shared, scalingMode: .pageScaleNone, autoRotate: true)
      else {
        throw .printFailed("The page's PDF could not be prepared for printing.")
      }
      operation.jobTitle = webView.title
      operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func viewSourceURL() throws(BrowserError) -> URL {
      guard let url = webView.url, let source = URL(string: "view-source:\(url.absoluteString)")
      else {
        throw .invalidURL("view-source")
      }
      return source
    }
  }
#endif

public import Foundation
internal import OWLProtocol
public import Observation
internal import os

/// What a file chooser lets the user pick.
nonisolated public enum WebFileChooserMode: Sendable, Hashable {
  /// One existing file.
  case open
  /// One or more existing files.
  case openMultiple
  /// A folder (`webkitdirectory`).
  case openFolder
  /// A new file to save (File System Access `showSaveFilePicker`).
  case save

  init(wire value: UInt64) {
    switch OWLFileChooserMode(rawValue: value) {
    case .openMultiple: self = .openMultiple
    case .openFolder: self = .openFolder
    case .save: self = .save
    default: self = .open
    }
  }
}

/// One entry of an `accept` attribute.
nonisolated public struct WebFileType: Sendable, Hashable, Decodable {
  /// The MIME type or extension the page wrote, for example "image/*" or ".png".
  public let filter: String
  /// Extensions without the dot, for example ["png", "jpg"].
  public let extensions: [String]
  /// A description, possibly empty.
  public let description: String
}

/// `<input type=file>` or a File System Access picker.
public final class WebFileChooserRequest: WebPromptRequest {
  /// What may be picked.
  public let mode: WebFileChooserMode
  /// The panel title, possibly empty.
  public let title: String
  /// A suggested path or file name, possibly empty.
  public let defaultPath: String
  /// Allowed types; empty allows everything.
  public let acceptTypes: [WebFileType]

  init(id: UInt64, webView: WebView, fields: WireDecoder) throws(WebLayerError) {
    mode = WebFileChooserMode(wire: fields.u64(.fileChooserMode) ?? 0)
    title = fields.string(.title) ?? ""
    defaultPath = fields.string(.defaultText) ?? ""
    acceptTypes = try WireJSON.decode(
      [WebFileType].self, fields.string(.acceptTypes) ?? "[]", field: "AcceptTypes")
    super.init(id: id, webView: webView)
  }

  /// Answers with the chosen files. Each must be a file URL.
  public func choose(_ urls: [URL]) {
    guard urls.allSatisfy(\.isFileURL), !urls.isEmpty else {
      webView?.lastError = .invalidArgument("A file chooser answer needs at least one file URL.")
      webView?.changed()
      cancel()
      return
    }
    reply(
      .fileChooserReply,
      WireEncoder().bool(.accepted, true).string(.paths, WireJSON.encode(urls.map(\.path))))
  }

  /// Cancels; the input keeps its previous files.
  public func cancel() {
    reply(.fileChooserReply, WireEncoder().bool(.accepted, false))
  }
}

/// A download the page started. Choose where it goes, or cancel it.
public final class WebDownloadRequest: WebPromptRequest {
  /// Chromium's ID for the download.
  public let downloadID: UInt32
  /// What is downloaded.
  public let url: URL?
  /// The file name the server or page suggested.
  public let suggestedName: String
  /// The MIME type, possibly empty.
  public let mimeType: String
  /// The size, when known.
  public let totalBytes: Int64?

  init(id: UInt64, webView: WebView, fields: WireDecoder) {
    downloadID = UInt32(truncatingIfNeeded: fields.u64(.downloadID) ?? 0)
    url = fields.string(.URL).flatMap(URL.init(string:))
    suggestedName = fields.string(.suggestedName) ?? ""
    mimeType = fields.string(.mimeType) ?? ""
    totalBytes = fields.i64(.totalBytes).flatMap { $0 >= 0 ? $0 : nil }
    super.init(id: id, webView: webView)
  }

  /// Starts the download into `destination` (a file URL) and adds it to `Session.downloads`.
  @discardableResult
  public func save(to destination: URL) -> WebDownload? {
    guard destination.isFileURL, let webView else {
      self.webView?.lastError = .invalidArgument("A download destination must be a file URL.")
      self.webView?.changed()
      cancel()
      return nil
    }
    let download = webView.session.downloads.started(by: self, viewID: webView.id, to: destination)
    reply(.downloadReply, WireEncoder().bool(.accepted, true).string(.path, destination.path))
    return download
  }

  /// Cancels before anything is written.
  public func cancel() {
    reply(.downloadReply, WireEncoder().bool(.accepted, false))
  }
}

/// Where a download stands.
nonisolated public enum WebDownloadState: Sendable, Hashable {
  /// Receiving data.
  case inProgress
  /// Paused by the user.
  case paused
  /// Finished; the file is at `destination`.
  case complete
  /// Cancelled.
  case cancelled
  /// Failed, for example because the network dropped.
  case interrupted

  init(wire value: UInt64) {
    switch OWLDownloadState(rawValue: value) {
    case .complete: self = .complete
    case .cancelled: self = .cancelled
    case .interrupted: self = .interrupted
    case .paused: self = .paused
    default: self = .inProgress
    }
  }

  /// Whether the download stopped for good.
  public var isFinal: Bool { self == .complete || self == .cancelled || self == .interrupted }
}

/// One download, updated as the host reports progress.
@Observable
public final class WebDownload: Identifiable {
  /// Chromium's ID for the download.
  public let id: UInt32
  /// What is downloaded.
  public let url: URL?
  /// The suggested file name.
  public let suggestedName: String
  /// Where the file goes.
  public let destination: URL
  /// Bytes received so far.
  public internal(set) var receivedBytes: Int64 = 0
  /// The size, when known.
  public internal(set) var totalBytes: Int64?
  /// Progress state.
  public internal(set) var state = WebDownloadState.inProgress

  @ObservationIgnored weak var session: Session?
  @ObservationIgnored let viewID: UInt64

  init(request: WebDownloadRequest, viewID: UInt64, destination: URL, session: Session) {
    id = request.downloadID
    url = request.url
    suggestedName = request.suggestedName
    totalBytes = request.totalBytes
    self.destination = destination
    self.viewID = viewID
    self.session = session
  }

  /// Progress in `0...1`, when the size is known.
  public var fractionCompleted: Double? {
    guard let totalBytes, totalBytes > 0 else { return state == .complete ? 1 : nil }
    return min(1, Double(receivedBytes) / Double(totalBytes))
  }

  /// Cancels the download.
  public func cancel() throws(WebLayerError) { try control(.cancel) }
  /// Pauses the download.
  public func pause() throws(WebLayerError) { try control(.pause) }
  /// Resumes a paused download.
  public func resume() throws(WebLayerError) { try control(.resume) }

  private func control(_ command: OWLDownloadCommand) throws(WebLayerError) {
    guard !state.isFinal else { throw .promptFinished("download \(id) already stopped") }
    guard let session else { throw .notReady }
    try session.post(
      .downloadControl, target: viewID,
      WireEncoder().u64(.downloadID, UInt64(id)).u64(.downloadCommand, command.rawValue))
  }
}

/// Every download in a session, newest first.
@Observable
public final class WebDownloadList {
  /// The downloads.
  public private(set) var items: [WebDownload] = []
  /// Called when a download is added or changes state.
  @ObservationIgnored public var onChange: ((WebDownload) -> Void)?
  @ObservationIgnored weak var session: Session?

  init() {}

  func started(by request: WebDownloadRequest, viewID: UInt64, to destination: URL)
    -> WebDownload?
  {
    guard let session else { return nil }
    let download = WebDownload(
      request: request, viewID: viewID, destination: destination, session: session)
    items.insert(download, at: 0)
    onChange?(download)
    return download
  }

  func update(_ fields: WireDecoder) {
    guard let raw = fields.u64(.downloadID) else {
      Logger.session.error("DownloadUpdated without a DownloadID.")
      return
    }
    guard let download = items.first(where: { $0.id == UInt32(truncatingIfNeeded: raw) }) else {
      // Chromium reports progress before the destination is chosen; the record starts then.
      Logger.session.debug("Progress for download \(raw) before it was accepted.")
      return
    }
    download.receivedBytes = fields.i64(.receivedBytes) ?? download.receivedBytes
    download.totalBytes = fields.i64(.totalBytes).flatMap { $0 >= 0 ? $0 : nil }
    download.state = WebDownloadState(wire: fields.u64(.downloadState) ?? 0)
    onChange?(download)
  }

  /// Removes finished downloads from the list. Files stay on disk.
  public func clearFinished() {
    items.removeAll { $0.state.isFinal }
  }
}

/// JSON for the structured 1.1 fields (owl_protocol.h).
nonisolated enum WireJSON {
  static func decode<T: Decodable>(_ type: T.Type, _ json: String, field: String)
    throws(WebLayerError) -> T
  {
    do {
      return try JSONDecoder().decode(type, from: Data(json.utf8))
    } catch {
      throw .channelFailed("Field \(field) is not valid JSON: \(error.localizedDescription)")
    }
  }

  static func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try encoder.encode(value)
    } catch {
      // Only plain strings, numbers, arrays and structs are encoded; failure is a programming
      // error.
      preconditionFailure("JSON encoding of \(T.self) failed: \(error)")
    }
    guard let text = String(bytes: data, encoding: .utf8) else {
      preconditionFailure("JSONEncoder produced invalid UTF-8.")
    }
    return text
  }
}

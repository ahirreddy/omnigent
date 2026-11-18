import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os

/// Streams a workspace video to AVFoundation through ranged reads, as the web's player streams
/// the file's download URL: each byte range AVFoundation asks for is read in chunks through the
/// data source, so a long recording plays and seeks without downloading all of it.
nonisolated final class WorkspaceVideoLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
  /// Reads `length` bytes from `offset`.
  typealias Read =
    @MainActor @Sendable (UInt64, UInt64) async throws(WorkspaceFailure) -> WorkspaceVideoChunk

  /// The scheme of the asset URL, so AVFoundation asks this loader for every byte.
  static let scheme = "omnigent-workspace-video"
  /// The most one read asks for.
  static let chunkLength: UInt64 = 2 * 1024 * 1024

  /// Where AVFoundation calls the loader.
  let queue = DispatchQueue(label: "omnigent.workspace.video-loader")
  private let read: Read
  private let requests = OSAllocatedUnfairLock(
    initialState: [ObjectIdentifier: Task<Void, Never>]())

  /// Why a video could not be streamed.
  enum Failure: Error, Equatable {
    /// The server's type is not one the player accepts.
    case unsupportedType
    /// The server did not say how long the file is.
    case unknownLength
    /// The server answered with other bytes than those asked for.
    case misplacedBytes
  }

  /// A loader.
  /// - Parameter read: Reads a byte range of the video.
  init(read: @escaping Read) {
    self.read = read
  }

  /// A URL only this loader can answer.
  static func assetURL() -> URL {
    URL(string: "\(scheme)://video/\(UUID().uuidString)") ?? URL(filePath: "/")
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    let request = LoadingRequest(loadingRequest)
    let key = ObjectIdentifier(loadingRequest)
    let read = read
    requests.withLock { requests in
      requests[key] = Task { [self] in
        await Self.serve(request, read: read)
        self.requests.withLock { _ = $0.removeValue(forKey: key) }
      }
    }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    let task = requests.withLock { $0.removeValue(forKey: ObjectIdentifier(loadingRequest)) }
    task?.cancel()
  }

  /// Stops every read in flight.
  func cancelAll() {
    let tasks = requests.withLock { requests in
      defer { requests.removeAll() }
      return Array(requests.values)
    }
    for task in tasks { task.cancel() }
  }

  /// Answers one request: the content facts when asked, then its bytes, chunk by chunk.
  private static func serve(_ wrapped: LoadingRequest, read: Read) async {
    let request = wrapped.request
    do {
      let plan = Plan(request)
      var offset = plan.start
      var described = request.contentInformationRequest == nil
      while true {
        try Task.checkCancellation()
        let length = plan.length(from: offset)
        if length == 0 { break }
        let chunk = try await read(offset, length)
        if !described, let information = request.contentInformationRequest {
          try describe(information, from: chunk)
          described = true
        }
        guard let dataRequest = request.dataRequest else { break }
        let bytes = try slice(chunk, from: offset, length: length)
        if bytes.isEmpty { break }
        dataRequest.respond(with: bytes)
        offset += UInt64(bytes.count)
        if let total = chunk.totalLength, offset >= total { break }
        if UInt64(bytes.count) < length { break }
      }
      request.finishLoading()
    } catch is CancellationError {
      // AVFoundation cancelled the request and expects no answer.
    } catch {
      request.finishLoading(with: error)
    }
  }

  /// Fills in the type and length AVFoundation needs to play and seek.
  static func describe(
    _ information: AVAssetResourceLoadingContentInformationRequest, from chunk: WorkspaceVideoChunk
  ) throws(Failure) {
    let facts = try facts(of: chunk)
    information.contentType = facts.type
    information.contentLength = facts.length
    information.isByteRangeAccessSupported = true
  }

  /// The uniform type and length of the video `chunk` is part of.
  static func facts(of chunk: WorkspaceVideoChunk) throws(Failure) -> (type: String, length: Int64)
  {
    guard let type = chunk.videoType, let uniform = UTType(mimeType: type) else {
      throw .unsupportedType
    }
    guard let total = chunk.totalLength, let length = Int64(exactly: total) else {
      throw .unknownLength
    }
    return (uniform.identifier, length)
  }

  /// The bytes of `chunk` from `offset`, at most `length`; a server that ignored the range sent
  /// the whole file, so its start is skipped.
  static func slice(_ chunk: WorkspaceVideoChunk, from offset: UInt64, length: UInt64)
    throws(Failure) -> Data
  {
    guard chunk.offset <= offset, let skip = Int(exactly: offset - chunk.offset),
      skip <= chunk.data.count
    else { throw .misplacedBytes }
    let start = chunk.data.startIndex + skip
    let take = min(chunk.data.count - skip, Int(clamping: length))
    return chunk.data.subdata(in: start..<(start + take))
  }

  /// Which bytes a request wants: from `start`, to `end` or to the file's end.
  struct Plan {
    let start: UInt64
    let end: UInt64?

    init(start: UInt64, end: UInt64?) {
      self.start = start
      self.end = end
    }

    init(_ request: AVAssetResourceLoadingRequest) {
      guard let data = request.dataRequest else {
        // Only the content facts: the first byte is enough to learn them.
        self.init(start: 0, end: 1)
        return
      }
      let start = UInt64(clamping: data.requestedOffset)
      let end =
        data.requestsAllDataToEndOfResource
        ? nil : start + UInt64(clamping: data.requestedLength)
      self.init(start: start, end: end)
    }

    /// How much the next read asks for at `offset`.
    func length(from offset: UInt64) -> UInt64 {
      guard let end else { return WorkspaceVideoLoader.chunkLength }
      return offset >= end ? 0 : min(WorkspaceVideoLoader.chunkLength, end - offset)
    }
  }
}

/// A loading request handed to the task that answers it; AVFoundation's requests may be
/// answered from any thread.
nonisolated private final class LoadingRequest: @unchecked Sendable {
  let request: AVAssetResourceLoadingRequest

  init(_ request: AVAssetResourceLoadingRequest) {
    self.request = request
  }
}

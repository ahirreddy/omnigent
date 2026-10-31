import Foundation

public enum AttachmentPreviewError: Error, LocalizedError, Equatable, Sendable {
  case unsupportedReference, tooLarge, unsupportedMedia

  public var errorDescription: String? {
    switch self {
    case .unsupportedReference:
      return "Only files belonging to this session on the connected server can be previewed here."
    case .tooLarge:
      return "This file exceeds the 10 MB native preview limit. Open it in the web app."
    case .unsupportedMedia:
      return "This file type cannot be safely previewed here. Open it in the web app."
    }
  }
}

public struct LocalAttachmentContent: Sendable {
  public let data: Data
  public let fileExtension: String
}

extension LocalServerSessionClient {
  public nonisolated func attachmentFileID(reference: String?, sessionID: String) -> String? {
    guard let reference, !reference.isEmpty else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    func identifier(_ value: String) -> Bool {
      !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    guard identifier(sessionID) else { return nil }
    if identifier(reference) { return reference }
    guard var root = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
    root.query = nil
    guard let apiRoot = root.string else { return nil }
    let logicalReference = reference.hasPrefix("/v1/") || reference.hasPrefix("v1/")
    let target =
      logicalReference
      ? apiRoot + "/" + reference.drop(while: { $0 == "/" })
      : reference
    guard let components = URLComponents(string: target), let url = components.url,
      url.scheme == baseURL.scheme, url.host == baseURL.host,
      (url.port ?? (url.scheme == "https" ? 443 : 80))
        == (baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80)),
      url.user == nil, url.password == nil, url.fragment == nil,
      components.percentEncodedQuery == nil
        || endpoint.databricksOrgID.map({ components.percentEncodedQuery == "o=\($0)" }) == true,
      !components.percentEncodedPath.contains("%"),
      url.path.hasPrefix(baseURL.path + "/v1/")
    else { return nil }
    let path = String(url.path.dropFirst(baseURL.path.count))
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(
      String.init)
    guard parts.count == 7, parts[0] == "v1", parts[1] == "sessions", parts[2] == sessionID,
      parts[3] == "resources", parts[4] == "files", identifier(parts[5]), parts[6] == "content"
    else { return nil }
    return parts[5]
  }

  public func attachmentContent(sessionID: String, fileID: String) async throws
    -> LocalAttachmentContent
  {
    try requireConnection()
    try validateIdentifier(sessionID)
    try validateIdentifier(fileID)
    let outgoing = try request(
      path: "/v1/sessions/\(sessionID)/resources/files/\(fileID)/content", accept: "*/*")
    let generation = connectionGeneration
    let (bytes, response) = try await session.bytes(for: outgoing)
    defer { bytes.task.cancel() }
    guard generation == connectionGeneration else { throw LocalServerClientError.notConnected }
    guard let http = response as? HTTPURLResponse else {
      throw LocalServerClientError.malformedResponse
    }
    guard http.url == outgoing.url else { throw LocalServerClientError.redirectNotAllowed }
    switch http.statusCode {
    case 200: break
    case 300...399: throw LocalServerClientError.redirectNotAllowed
    case 401:
      authenticationFailed()
      throw LocalServerClientError.unauthorized
    case 403: throw LocalServerClientError.forbidden
    default: throw LocalServerClientError.httpStatus(http.statusCode)
    }
    let extensions = [
      "application/pdf": "pdf", "text/plain": "txt", "application/json": "json",
      "text/markdown": "txt", "text/csv": "csv", "image/png": "png", "image/jpeg": "jpg",
      "image/gif": "gif", "image/webp": "webp", "image/heic": "heic", "image/tiff": "tiff",
      "audio/mpeg": "mp3", "audio/wav": "wav", "audio/x-wav": "wav", "audio/mp4": "m4a",
      "video/mp4": "mp4", "video/quicktime": "mov",
    ]
    let mediaType = http.value(forHTTPHeaderField: "Content-Type")?
      .split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let mediaType, let ext = extensions[mediaType] else {
      throw AttachmentPreviewError.unsupportedMedia
    }
    let limit = 10 * 1_024 * 1_024
    guard response.expectedContentLength <= limit else { throw AttachmentPreviewError.tooLarge }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard generation == connectionGeneration else { throw LocalServerClientError.notConnected }
      guard data.count < limit else { throw AttachmentPreviewError.tooLarge }
      data.append(byte)
    }
    return LocalAttachmentContent(data: data, fileExtension: ext)
  }
}

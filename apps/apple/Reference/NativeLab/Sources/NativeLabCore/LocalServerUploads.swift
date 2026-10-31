import Foundation

public enum AttachmentUploadError: Error, LocalizedError, Equatable, Sendable {
  case unsupportedType, invalidFilename, notRegularFile
  case tooLarge(Int)
  case draftLimit, notReady, wrongSession, uploadUncertain

  public var errorDescription: String? {
    switch self {
    case .unsupportedType: return "Attach an image, PDF, or text/code file."
    case .invalidFilename: return "This file needs a valid filename before it can be attached."
    case .notRegularFile: return "Choose a file rather than a folder or link."
    case .tooLarge(let limit):
      return "This file exceeds the \(limit / 1_024 / 1_024) MB upload limit."
    case .draftLimit:
      return "Keep at most 8 attachments and 25 MB per draft (100 MB across drafts)."
    case .notReady: return "Wait for attachments to finish uploading and review any errors."
    case .wrongSession: return "These attachments belong to a different session or server."
    case .uploadUncertain:
      return
        "Upload confirmation was lost. The file may already be stored. Your file is kept; automatic retry is disabled. Review the session files in the web app before removing or selecting it again."
    }
  }
}

public enum AttachmentUploadPolicy {
  public static let maximumFilesPerDraft = 8
  public static let maximumDraftBytes = 25 * 1_024 * 1_024
  public static let maximumStoredBytes = 100 * 1_024 * 1_024
  public static let textExtensions = Set(
    ("txt log md markdown csv json jsonl ndjson yaml yml toml ini cfg env lock proto graphql gql "
      + "html htm xml css js jsx mjs cjs ts tsx py rb go rs java kt scala swift c h cc cpp hpp cs "
      + "php pl r jl lua ex exs erl hs clj dart vue svelte sh bash zsh fish sql tf hcl gradle dockerfile ipynb")
      .split(separator: " ").map(String.init))

  public static func mediaType(filename: String, declared: String?) throws -> String {
    guard !filename.isEmpty, filename.utf8.count <= 255,
      !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !filename.contains("/"), !filename.contains("\\"), filename != ".", filename != ".."
    else { throw AttachmentUploadError.invalidFilename }
    let ext =
      filename.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init)?
      .lowercased() ?? ""
    let mime =
      declared?.split(separator: ";").first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-/")
    guard mime.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
      throw AttachmentUploadError.unsupportedType
    }
    let imageTypes = [
      "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
      "webp": "image/webp", "heic": "image/heic", "heif": "image/heif", "tif": "image/tiff",
      "tiff": "image/tiff", "bmp": "image/bmp", "avif": "image/avif", "svg": "image/svg+xml",
    ]
    if mime.hasPrefix("image/") { return mime }
    if let image = imageTypes[ext], mime.isEmpty || mime == "application/octet-stream" {
      return image
    }
    if mime == "application/pdf" || ext == "pdf" { return "application/pdf" }
    let textApplications: Set<String> = [
      "application/json", "application/javascript", "application/jsonl", "application/x-ndjson",
      "application/x-ipynb+json",
    ]
    if mime.hasPrefix("text/") || textApplications.contains(mime) { return mime }
    if textExtensions.contains(ext) { return "text/plain" }
    throw AttachmentUploadError.unsupportedType
  }

  public static func byteLimit(for mediaType: String) -> Int {
    (mediaType.hasPrefix("image/") ? 5 : (mediaType == "application/pdf" ? 20 : 10)) * 1_024 * 1_024
  }
}

public struct AttachmentUploadFile: Equatable, Sendable {
  public let filename: String
  public let mediaType: String
  public let data: Data

  public init(filename: String, mediaType: String? = nil, data: Data) throws {
    let resolved = try AttachmentUploadPolicy.mediaType(filename: filename, declared: mediaType)
    let limit = AttachmentUploadPolicy.byteLimit(for: resolved)
    guard data.count <= limit else { throw AttachmentUploadError.tooLarge(limit) }
    self.filename = filename
    self.mediaType = resolved
    self.data = data
  }

  /// Bounds reads even when a file provider reports a stale or missing size.
  public static func read(contentsOf url: URL, filename: String? = nil, mediaType: String? = nil)
    throws -> Self
  {
    let name = filename ?? url.lastPathComponent
    let mime = try AttachmentUploadPolicy.mediaType(filename: name, declared: mediaType)
    let limit = AttachmentUploadPolicy.byteLimit(for: mime)
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw AttachmentUploadError.notRegularFile
    }
    guard (values.fileSize ?? 0) <= limit else { throw AttachmentUploadError.tooLarge(limit) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    while let chunk = try handle.read(upToCount: min(64 * 1_024, limit + 1 - data.count)),
      !chunk.isEmpty
    {
      try Task.checkCancellation()
      data.append(chunk)
      guard data.count <= limit else { throw AttachmentUploadError.tooLarge(limit) }
    }
    return try Self(filename: name, mediaType: mime, data: data)
  }
}

public struct UploadedAttachment: Equatable, Sendable {
  public let serverURL: URL
  public let userID: String?
  public let sessionID: String
  public let id: String
  public let filename: String
  public let isImage: Bool

  public init(
    serverURL: URL, sessionID: String, id: String, filename: String, isImage: Bool,
    userID: String? = nil
  ) {
    self.serverURL = serverURL
    self.userID = userID
    self.sessionID = sessionID
    self.id = id
    self.filename = filename
    self.isImage = isImage
  }

  var contentBlock: JSONValue {
    .object([
      "type": .string(isImage ? "input_image" : "input_file"), "file_id": .string(id),
      "filename": .string(filename),
    ])
  }
}

extension LocalServerSessionClient {
  public func uploadAttachment(
    _ file: AttachmentUploadFile, sessionID: String,
    progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> UploadedAttachment {
    let summary = try await editableSession(sessionID)
    guard !summary.isArchived else { throw SessionClientError.archived }
    try Task.checkCancellation()
    var outgoing = try request(path: "/v1/sessions/\(sessionID)/resources/files")
    outgoing.httpMethod = "POST"
    let boundary = "NativeLab-\(UUID().uuidString)"
    outgoing.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let name = file.filename.replacingOccurrences(of: "\"", with: "%22")
    var body = Data(
      ("--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n"
        + "Content-Type: \(file.mediaType)\r\n\r\n").utf8)
    body.append(file.data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    let generation = connectionGeneration
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.upload(
        for: outgoing, from: body, delegate: AttachmentUploadDelegate(progress: progress))
    } catch {
      throw AttachmentUploadError.uploadUncertain
    }
    guard generation == connectionGeneration else { throw AttachmentUploadError.uploadUncertain }
    guard let http = response as? HTTPURLResponse, http.url == outgoing.url else {
      throw AttachmentUploadError.uploadUncertain
    }
    switch http.statusCode {
    case 201: break
    case 300...399: throw AttachmentUploadError.uploadUncertain
    case 401:
      authenticationFailed()
      throw LocalServerClientError.unauthorized
    case 403: throw LocalServerClientError.forbidden
    case 400...499: throw LocalServerClientError.httpStatus(http.statusCode)
    default: throw AttachmentUploadError.uploadUncertain
    }
    guard data.count <= 64 * 1_024,
      let resource = try? JSONDecoder().decode(UploadedFileWire.self, from: data),
      (try? validateIdentifier(resource.id)) != nil,
      resource.sessionID == nil || resource.sessionID == sessionID
    else { throw AttachmentUploadError.uploadUncertain }
    let filename = resource.metadata?.filename ?? resource.name ?? file.filename
    guard !filename.isEmpty else { throw AttachmentUploadError.uploadUncertain }
    progress(1)
    return UploadedAttachment(
      serverURL: baseURL, sessionID: sessionID, id: resource.id, filename: filename,
      isImage: file.mediaType.hasPrefix("image/"), userID: confirmedUserID)
  }

  /// Call once inside the app's SubmissionLedger operation; this endpoint has no idempotency key.
  public func submitMessage(_ text: String, attachments: [UploadedAttachment], to sessionID: String)
    async throws -> MessageSubmission
  {
    guard !attachments.isEmpty else { return try await submitMessage(text, to: sessionID) }
    try validateIdentifier(sessionID)
    guard attachments.count <= AttachmentUploadPolicy.maximumFilesPerDraft,
      attachments.allSatisfy({
        $0.sessionID == sessionID && $0.serverURL == baseURL
          && ($0.userID == confirmedUserID || (endpoint.isLocalSingleUser && $0.userID == nil))
      })
    else { throw AttachmentUploadError.wrongSession }
    for attachment in attachments { try validateIdentifier(attachment.id) }
    let summary = try await editableSession(sessionID)
    guard !summary.isArchived else { throw SessionClientError.archived }
    guard watchedSessionID == sessionID, streamReady else {
      throw LocalServerClientError.streamNotReady
    }
    if let reason = summary.configuration?.executionUnavailableReason {
      throw LocalServerClientError.executionUnavailable(reason)
    }
    try Task.checkCancellation()
    var content = attachments.map(\.contentBlock)
    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      content.append(.object(["type": .string("input_text"), "text": .string(text)]))
    }
    return try await mutation(
      path: "/v1/sessions/\(sessionID)/events",
      body: .object([
        "type": .string("message"),
        "data": .object(["role": .string("user"), "content": .array(content)]),
      ]))
  }
}

private struct UploadedFileWire: Decodable {
  let id: String
  let name: String?
  let sessionID: String?
  let metadata: Metadata?
  enum CodingKeys: String, CodingKey {
    case id, name, metadata
    case sessionID = "session_id"
  }
  struct Metadata: Decodable { let filename: String? }
}

private final class AttachmentUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
  let progress: @Sendable (Double) -> Void
  init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }
    progress(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) { handleServerChallenge(challenge, completionHandler: completionHandler) }
}

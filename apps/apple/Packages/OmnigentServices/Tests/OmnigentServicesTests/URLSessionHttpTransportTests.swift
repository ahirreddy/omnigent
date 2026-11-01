import Foundation
import OmnigentCoreFFI
import Synchronization
import Testing

@testable import OmnigentServices

final class StubURLProtocol: URLProtocol {
  enum Reply: Sendable {
    case response(status: Int, headers: [String: String], body: Data)
    case failure(URLError)
  }

  struct Recorded: Sendable {
    var method: String?
    var url: URL?
    var headers: [String: String]
  }

  static let reply = Mutex<Reply>(.failure(URLError(.unknown)))
  static let recorded = Mutex<[Recorded]>([])

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.recorded.withLock {
      $0.append(
        Recorded(
          method: request.httpMethod, url: request.url, headers: request.allHTTPHeaderFields ?? [:])
      )
    }
    switch Self.reply.withLock({ $0 }) {
    case .failure(let error):
      client?.urlProtocol(self, didFailWithError: error)
    case .response(let status, let headers, let body):
      guard let url = request.url,
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

@Suite(.serialized)
struct URLSessionHttpTransportTests {
  private func makeTransport() -> URLSessionHttpTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    StubURLProtocol.recorded.withLock { $0.removeAll() }
    return URLSessionHttpTransport(session: URLSession(configuration: configuration))
  }

  @Test func sendsRequestAndReturnsResponse() async throws {
    let transport = makeTransport()
    let body = Data(#"{"ok":true}"#.utf8)
    StubURLProtocol.reply.withLock {
      $0 = .response(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    let response = try await transport.send(
      request: HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:6767/.well-known/omnigent.json",
        headers: [HttpHeader(name: "Accept", value: "application/json")],
        body: nil
      )
    )

    #expect(response.status == 200)
    #expect(response.body == body)
    #expect(
      response.headers.contains { $0.name == "Content-Type" && $0.value == "application/json" })
    let recorded = try #require(StubURLProtocol.recorded.withLock { $0.first })
    #expect(recorded.method == "GET")
    #expect(recorded.url?.absoluteString == "http://127.0.0.1:6767/.well-known/omnigent.json")
    #expect(recorded.headers["Accept"] == "application/json")
  }

  @Test func non2xxIsReturnedNotThrown() async throws {
    let transport = makeTransport()
    StubURLProtocol.reply.withLock {
      $0 = .response(status: 404, headers: [:], body: Data("missing".utf8))
    }

    let response = try await transport.send(
      request: HttpRequest(
        method: "GET", url: "http://127.0.0.1:6767/missing", headers: [], body: nil)
    )

    #expect(response.status == 404)
    #expect(String(bytes: response.body, encoding: .utf8) == "missing")
  }

  @Test func connectionFailureMapsToOffline() async {
    let transport = makeTransport()
    StubURLProtocol.reply.withLock { $0 = .failure(URLError(.cannotConnectToHost)) }

    do {
      _ = try await transport.send(
        request: HttpRequest(method: "GET", url: "http://127.0.0.1:1/", headers: [], body: nil)
      )
      Issue.record("expected an offline error")
    } catch {
      guard case .Offline = error else {
        Issue.record("expected offline, got \(error)")
        return
      }
    }
  }

  @Test func invalidURLIsRejected() async {
    let transport = makeTransport()
    do {
      _ = try await transport.send(
        request: HttpRequest(method: "GET", url: "not a url", headers: [], body: nil))
      Issue.record("expected an invalid URL error")
    } catch {
      guard case .Other(let message) = error else {
        Issue.record("expected other, got \(error)")
        return
      }
      #expect(message.contains("not a url"))
    }
  }
}

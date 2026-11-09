#if os(macOS)
  public import Foundation
  public import OmnigentBrowser
  internal import OmnigentWebLayer

  /// Clearing and deleting profile data on Chromium. Cookies, cache and site storage are cleared
  /// over DevTools in a view of the profile (a hidden one if none is open); a deleted profile's
  /// request context is closed and its directory removed.
  extension ChromiumBrowserEngine {
    /// See `BrowserEngine.removeData(_:for:since:origins:)`. Chromium's DevTools clear cookies
    /// and cache for all time; `since` is not applied to them.
    public func removeData(
      _ types: BrowserDataTypes, for profile: BrowserProfile, since: Date?, origins: [URL]
    ) async throws(BrowserError) {
      let engineTypes = types.intersection(.engineData)
      guard !engineTypes.isEmpty else { return }
      let webProfile = session.profile(
        identifier: profile.identifier,
        persistence: profile.persistence == .persistent ? .persistent : .ephemeral)
      let existing = webProfile.views.first { $0.status == .live }
      let view = existing ?? webProfile.makeWebView(initialURL: URL(string: "about:blank"))
      defer { if existing == nil { view.close() } }
      do throws(WebLayerError) {
        try await waitUntilLive(view)
        try await clear(engineTypes, origins: origins, in: view)
      } catch {
        throw ChromiumBrowserTab.convert(error)
      }
    }

    private func waitUntilLive(_ view: WebView) async throws(WebLayerError) {
      try await session.waitUntilReady()
      let deadline = ContinuousClock.now + .seconds(20)
      while view.status != .live {
        if case .unavailable(let error) = view.status { throw error }
        guard ContinuousClock.now < deadline else { throw .notReady }
        do {
          try await Task.sleep(for: .milliseconds(50))
        } catch {
          throw .notReady
        }
      }
    }

    private func clear(_ types: BrowserDataTypes, origins: [URL], in view: WebView)
      async throws(WebLayerError)
    {
      if types.contains(.cookies) {
        _ = try await view.callDevToolsMethod("Network.clearBrowserCookies")
      }
      if types.contains(.cache) {
        _ = try await view.callDevToolsMethod("Network.clearBrowserCache")
      }
      guard types.contains(.siteData) else { return }
      for origin in Set(origins.compactMap(Self.origin)) {
        let params = Self.json([
          "origin": origin,
          "storageTypes":
            "local_storage,indexeddb,websql,service_workers,cache_storage,file_systems,shader_cache",
        ])
        _ = try await view.callDevToolsMethod("Storage.clearDataForOrigin", paramsJSON: params)
      }
    }

    /// See `BrowserEngine.deleteProfileData(_:)`.
    public func deleteProfileData(_ profile: BrowserProfile) async throws(BrowserError) {
      switch profile.persistence {
      case .ephemeral:
        session.existingProfile(identifier: profile.identifier, persistence: .ephemeral)?.close()
      case .persistent:
        try await deletePersistentStorage(profile.identifier)
      }
    }

    /// The host lets go of the context shortly after it is closed; until then Chromium may still
    /// write into the directory. Whatever is left goes before the next host starts.
    func deletePersistentStorage(_ identifier: String, retryDelay: Duration = .milliseconds(200))
      async throws(BrowserError)
    {
      do {
        for attempt in 0..<5 {
          if try session.deletePersistentStorage(identifier: identifier) { return }
          try await Task.sleep(for: retryDelay * (attempt + 1))
        }
      } catch {
        throw .storageFailed(error.localizedDescription)
      }
    }

    private static func origin(_ url: URL) -> String? {
      guard let scheme = url.scheme, scheme == "http" || scheme == "https",
        let host = url.host(percentEncoded: false)
      else {
        return nil
      }
      return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }

    private static func json(_ object: [String: String]) -> String {
      let data = try? JSONEncoder().encode(object)
      precondition(data != nil, "Encoding strings as JSON cannot fail.")
      return String(bytes: data ?? Data(), encoding: .utf8) ?? ""
    }
  }
#endif

internal import AppKit
internal import CoreGraphics
internal import Foundation
internal import OmnigentBrowser
internal import OmnigentWebLayer

/// Sign-in capability spikes: WebAuthn (platform, security key and a CDP virtual authenticator),
/// Okta FastPass's loopback probe, and custom-scheme launches. They log what each engine does;
/// see apps/apple/docs/browser-engine-decision.md for the results.
extension Proofs {
  static let authentication = [
    "webauthn", "webauthn-virtual", "webauthn-tab", "loopback", "external-scheme",
  ]

  /// The FastPass loopback port Okta Verify listens on first.
  static let oktaLoopbackPort: UInt16 = 8769

  static let authenticationPages: [String: String] = [
    "external-scheme": """
    <!doctype html><title>OWL external scheme</title>\(pageStyle)
    <h2>External schemes</h2>
    <p><a id=okta href="com-okta-authenticator:/deviceChallenge?challengeRequest=owl-spike">
    Open Okta Verify</a></p>
    <p><a id=unregistered href="omnigent-unregistered-scheme:owl-spike">Unregistered scheme</a></p>
    <p id=result>idle</p>
    """
  ]

  /// Feature detection and real-authenticator requests on a public HTTPS origin. example.com,
  /// because demo sites start a conditional (autofill) request that blocks a second one.
  func webAuthnProbe() async throws {
    try await load(try url("https://example.com/"), title: "Example Domain")
    Clock.log("webauthn features: \(try await awaitScript(Self.webAuthnFeatures))")
    // A normal window level, as in the app, so the stacking of Chromium's dialogs is realistic.
    window?.level = .normal
    defer { window?.level = .floating }
    for attachment in ["platform", "cross-platform"] {
      let before = hostWindowSummary()
      // Security keys are asked for presence only: no resident key and no user verification, so
      // an attached key is never prompted to set a PIN or store a credential.
      async let outcome = awaitScript(
        Self.createCredential(
          attachment: attachment, timeout: 8, demanding: attachment == "platform"))
      try await settle(3)
      let during = hostWindowSummary()
      try await shootHostWindows("webauthn-\(attachment)")
      Clock.log(
        "webauthn \(attachment): host windows before \(before), during \(during); \(stackingSummary())"
      )
      Clock.log("webauthn \(attachment) result: \(try await outcome)")
    }
  }

  /// Whether a host window is in front of the app's window, and which app is active.
  func stackingSummary() -> String {
    guard let pid = model.session.hostInfo?.pid,
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else { return "no window list" }
    let owners = windows.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
    let hostIndex = owners.firstIndex(of: pid).map(String.init) ?? "none"
    let appIndex = owners.firstIndex(of: getpid()).map(String.init) ?? "none"
    let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
    return "front-to-back index: host \(hostIndex), app \(appIndex); active app \(active)"
  }

  /// The same requests through the shared UI on `--engine` (WebKit has no CDP), with results
  /// polled from the page.
  func webAuthnTab() async throws {
    let (harness, tab) = try await harness(try url("https://example.com/"), title: "Example Domain")
    defer { harness.close() }
    let scripts = [
      ("features", Self.webAuthnFeatures),
      ("platform", Self.createCredential(attachment: "platform", timeout: 8)),
      (
        "security key",
        Self.createCredential(attachment: "cross-platform", timeout: 8, demanding: false)
      ),
    ]
    for (name, script) in scripts {
      let wrapped = "window.owlResult = ''; (\(script)).then(r => { window.owlResult = r; }); true"
      try await eval(tab, wrapped)
      let deadline = ContinuousClock.now + .seconds(12)
      var result = ""
      while result.isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(200))
        result = try await eval(tab, "window.owlResult").stringValue ?? ""
      }
      Clock.log("\(engine.rawValue) webauthn \(name): \(result.isEmpty ? "no answer" : result)")
    }
  }

  /// The WebAuthn pipeline end to end with a CDP virtual authenticator (no hardware).
  func webAuthnVirtual() async throws {
    for site in ["https://webauthn.io/", "https://www.passkeys.io/"] {
      webView.load(try url(site))
      try await waitUntil("load \(site)", timeout: 30) {
        self.webView.status == .live && !self.webView.isLoading && !self.webView.title.isEmpty
      }
      _ = try await webView.callDevToolsMethod(
        "WebAuthn.enable", paramsJSON: "{\"enableUI\":false}")
      let added = try await webView.callDevToolsMethod(
        "WebAuthn.addVirtualAuthenticator",
        paramsJSON: """
          {"options":{"protocol":"ctap2","ctap2Version":"ctap2_1","transport":"internal",\
          "hasResidentKey":true,"hasUserVerification":true,"isUserVerified":true,\
          "automaticPresenceSimulation":true}}
          """)
      Clock.log("\(site) virtual authenticator: \(added)")
      let createScript = Self.createCredential(attachment: "platform", timeout: 10)
      let created = try await awaitScript(createScript)
      let asserted = try await awaitScript(Self.getCredential(timeout: 10))
      let authenticatorID =
        (try JSONSerialization.jsonObject(with: Data(added.utf8)) as? [String: Any])?[
          "authenticatorId"] as? String ?? ""
      let stored = try await webView.callDevToolsMethod(
        "WebAuthn.getCredentials", paramsJSON: "{\"authenticatorId\":\"\(authenticatorID)\"}")
      Clock.log("\(site) create: \(created)")
      Clock.log("\(site) get: \(asserted)")
      Clock.log("\(site) authenticator holds: \(stored.prefix(300))")
      _ = try await webView.callDevToolsMethod("WebAuthn.disable")
      guard created.hasPrefix("ok"), asserted.hasPrefix("ok") else {
        throw ProofFailure("The virtual authenticator flow failed on \(site).")
      }
    }
  }

  /// Okta FastPass probes Okta Verify at http://127.0.0.1:8769 from the sign-in page. When Okta
  /// Verify is not running, a mock listener answers like it does (CORS and Private Network Access
  /// preflight headers).
  func loopbackProbe() async throws {
    let listener = try ProofServer(port: Self.oktaLoopbackPort)
    do {
      try await listener.start()
      Clock.log("loopback: mock listener on \(Self.oktaLoopbackPort)")
    } catch {
      Clock.log(
        "loopback: port \(Self.oktaLoopbackPort) is taken (\(error)); probing that listener")
    }
    defer { listener.stop() }
    // Without a UI delegate the web layer denies prompts and reports them, which shows whether
    // Chromium asked at all.
    try await load(try url("https://example.com/"), title: "Example Domain")
    _ = try await webView.evaluateJavaScript(Self.startLoopbackFetch(port: Self.oktaLoopbackPort))
    try await settle(2)
    Clock.log(
      "loopback without UI: \(try await webView.evaluateJavaScript("window.loopbackResult")), last error \(String(describing: webView.lastError))"
    )
    let profile = BrowserProfile(identifier: "owl2-loopback-\(UUID())", persistence: .persistent)
    let (harness, tab) = try await harness(
      try url("https://example.com/"), title: "Example Domain", profile: profile)
    defer {
      harness.presenter.permissionStore.reset(profile: profile)
      harness.close()
    }
    try await eval(tab, Self.startLoopbackFetch(port: Self.oktaLoopbackPort))
    let deadline = ContinuousClock.now + .seconds(10)
    var answered = false
    while ContinuousClock.now < deadline {
      if let alert = harness.presenter.presentedAlert, !answered {
        Clock.log("loopback prompt: \(alert.messageText) / \(alert.informativeText)")
        try await shoot(harness.window, "loopback-prompt")
        alert.buttons[0].performClick(nil)  // Allow.
        answered = true
      }
      if case .string(let result) = try await eval(tab, "window.loopbackResult || ''"),
        !result.isEmpty
      {
        Clock.log("loopback fetch from https://example.com: \(result); prompted \(answered)")
        guard result.hasPrefix("ok") else {
          throw ProofFailure("The loopback probe failed: \(result)")
        }
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ProofFailure("The loopback probe never finished; prompted \(answered).")
  }

  /// A link to a custom scheme (Okta Verify's `com-okta-authenticator:`), clicked by the user.
  func externalScheme() async throws {
    let (harness, tab) = try await harness(
      try await pageURL("external-scheme"), title: "OWL external scheme")
    defer { harness.close() }
    for link in ["#okta", "#unregistered"] {
      tab.load(try await pageURL("external-scheme"))
      try await waitForTab(tab, title: "OWL external scheme")
      try await userClick(tab, link, in: harness.window)
      let deadline = ContinuousClock.now + .seconds(4)
      var seen: BrowserPrompt?
      while seen == nil, ContinuousClock.now < deadline {
        seen = tab.state.pendingPrompts.first
        try await Task.sleep(for: .milliseconds(100))
      }
      if case .dialog(let dialog) = seen {
        Clock.log("\(link): prompt '\(dialog.message)'")
        try await shoot(harness.window, "external-scheme\(link.dropFirst())")
        dialog.cancel()  // Never launch an app from the proof.
      } else {
        Clock.log(
          "\(link): no prompt; url \(tab.state.url?.absoluteString ?? "-"), error \(String(describing: tab.state.lastError))"
        )
      }
    }
  }

  // MARK: Helpers

  /// Runs `script`, a promise-returning expression, and returns its string result.
  func awaitScript(_ script: String) async throws -> String {
    let params = try JSONSerialization.data(withJSONObject: [
      "expression": script, "awaitPromise": true, "returnByValue": true, "userGesture": true,
    ])
    guard let paramsJSON = String(bytes: params, encoding: .utf8) else {
      throw ProofFailure("Runtime.evaluate parameters are not UTF-8.")
    }
    let reply = try await webView.callDevToolsMethod("Runtime.evaluate", paramsJSON: paramsJSON)
    guard let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
      let result = object["result"] as? [String: Any]
    else {
      throw ProofFailure("Unexpected Runtime.evaluate reply: \(reply.prefix(300))")
    }
    return result["value"] as? String ?? "\(result)"
  }

  /// On-screen windows owned by the web host process: ID, title and bounds.
  func hostWindows() -> [(id: Int, summary: String)] {
    guard let pid = model.session.hostInfo?.pid,
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else { return [] }
    return windows.compactMap { window in
      guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
        let id = window[kCGWindowNumber as String] as? Int
      else { return nil }
      let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
      let name = window[kCGWindowName as String] as? String ?? ""
      let frame =
        "\(Int(bounds["X"] ?? 0)),\(Int(bounds["Y"] ?? 0)) \(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))"
      return (id, "'\(name)' at \(frame)")
    }
  }

  func hostWindowSummary() -> [String] { hostWindows().map(\.summary) }

  /// Captures each on-screen host window (Chromium's own dialogs) by window ID.
  func shootHostWindows(_ name: String) async throws {
    for (index, window) in hostWindows().enumerated() {
      _ = try await capture("\(name)-host\(index)", ["-l\(window.id)"])
    }
  }

  static let webAuthnFeatures = """
    (async () => {
      const out = { publicKeyCredential: typeof PublicKeyCredential };
      const run = async (name, call) => {
        try { out[name] = await call(); } catch (error) { out[name] = 'error: ' + error.name; }
      };
      await run('uvpaa', () => PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable());
      await run('conditional', () => PublicKeyCredential.isConditionalMediationAvailable());
      await run('capabilities', () => PublicKeyCredential.getClientCapabilities
        ? PublicKeyCredential.getClientCapabilities() : 'absent');
      return JSON.stringify(out);
    })()
    """

  static func createCredential(attachment: String, timeout: Int, demanding: Bool = true) -> String {
    let requirement = demanding ? "preferred" : "discouraged"
    return """
      (async () => {
        const abort = new AbortController();
        const timer = setTimeout(() => abort.abort(), \(timeout * 1000));
        try {
          const credential = await navigator.credentials.create({ signal: abort.signal, publicKey: {
            rp: { id: location.hostname, name: 'OWL spike' },
            user: { id: crypto.getRandomValues(new Uint8Array(16)), name: 'owl@example.com',
                    displayName: 'OWL spike' },
            challenge: crypto.getRandomValues(new Uint8Array(32)),
            pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
            authenticatorSelection: { authenticatorAttachment: '\(attachment)',
                                      residentKey: '\(requirement)',
                                      userVerification: '\(requirement)' },
            timeout: \(timeout * 1000) } });
          return 'ok ' + credential.authenticatorAttachment + ' ' +
            JSON.stringify(credential.response.getTransports ? credential.response.getTransports() : []);
        } catch (error) {
          return (abort.signal.aborted ? 'aborted after timeout: ' : 'error: ') + error.name + ': ' +
            error.message;
        } finally { clearTimeout(timer); }
      })()
      """
  }

  static func getCredential(timeout: Int) -> String {
    """
    (async () => {
      try {
        const credential = await navigator.credentials.get({ publicKey: {
          rpId: location.hostname, challenge: crypto.getRandomValues(new Uint8Array(32)),
          userVerification: 'preferred', timeout: \(timeout * 1000) } });
        return 'ok ' + credential.type + ' ' + credential.authenticatorAttachment;
      } catch (error) { return 'error: ' + error.name + ': ' + error.message; }
    })()
    """
  }

  static func startLoopbackFetch(port: UInt16) -> String {
    """
    window.loopbackResult = '';
    fetch('http://127.0.0.1:\(port)/probe', { method: 'GET' })
      .then(async response => { window.loopbackResult = 'ok ' + response.status + ' ' +
        (await response.text()); })
      .catch(error => { window.loopbackResult = 'error: ' + error.name + ': ' + error.message; });
    true
    """
  }
}

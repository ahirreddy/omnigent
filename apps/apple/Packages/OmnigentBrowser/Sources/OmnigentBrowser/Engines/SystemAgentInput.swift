internal import CoreGraphics
internal import Foundation

#if os(macOS)
  internal import AppKit
#else
  internal import UIKit
#endif

/// Agent input on WebKit. WKWebView has no public API for synthetic trusted input, so events
/// are dispatched from script: pages see `isTrusted == false`, and default actions come from
/// `click()`, `execCommand('insertText')` and `requestSubmit()`. Nothing reaches app chrome.
final class SystemAgentInput: BrowserAgentInput {
  private weak var tab: SystemBrowserTab?

  init(tab: SystemBrowserTab) {
    self.tab = tab
  }

  var isRendererDirect: Bool { false }
  var needsHostWindow: Bool { true }

  func prepareForAgent(viewport: CGSize) {
    tab?.platformView.frame = CGRect(origin: .zero, size: viewport)
  }

  private func run(_ script: String) async throws(BrowserError) {
    guard let tab else { throw .tabClosed }
    let result = try await tab.evaluateJavaScript(script)
    if case .string(let message) = result, message.hasPrefix("error:") {
      throw .agentActionFailed(String(message.dropFirst("error:".count)))
    }
  }

  func click(at point: CGPoint, clickCount: Int) async throws(BrowserError) {
    try await run(
      """
      (() => {
        const x = \(point.x), y = \(point.y), detail = \(max(1, clickCount));
        const el = document.elementFromPoint(x, y);
        if (!el) return 'error:no element at (' + x + ', ' + y + ')';
        const init = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y,
                       view: window, detail, button: 0 };
        el.dispatchEvent(new PointerEvent('pointerdown', init));
        el.dispatchEvent(new MouseEvent('mousedown', init));
        if (typeof el.focus === 'function') el.focus();
        el.dispatchEvent(new PointerEvent('pointerup', init));
        el.dispatchEvent(new MouseEvent('mouseup', init));
        el.click();
        return 'ok';
      })()
      """)
  }

  func scroll(at point: CGPoint, deltaX: Double, deltaY: Double) async throws(BrowserError) {
    try await run(
      """
      (() => {
        const el = document.elementFromPoint(\(point.x), \(point.y));
        let target = el;
        while (target && target !== document.body && target.scrollHeight <= target.clientHeight)
          target = target.parentElement;
        (target && target !== document.body ? target : window).scrollBy(\(deltaX), \(deltaY));
        return 'ok';
      })()
      """)
  }

  func insertText(_ text: String) async throws(BrowserError) {
    let quoted = try Self.jsString(text)
    try await run(
      """
      (() => {
        const el = document.activeElement;
        if (!el || el === document.body) return 'error:no element is focused';
        if (document.execCommand('insertText', false, \(quoted))) return 'ok';
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
        if (!setter) return 'error:the focused element is not editable';
        setter.call(el, (el.value || '') + \(quoted));
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return 'ok';
      })()
      """)
  }

  func press(_ key: BrowserAgentKey, modifiers: BrowserAgentModifiers) async throws(BrowserError) {
    if case .character(let character) = key, modifiers.isEmpty {
      try await insertText(String(character))
      return
    }
    let domKey = try Self.jsString(key.domKey)
    try await run(
      """
      (() => {
        const el = document.activeElement || document.body;
        const init = { key: \(domKey), bubbles: true, cancelable: true,
                       shiftKey: \(modifiers.contains(.shift)),
                       ctrlKey: \(modifiers.contains(.control)),
                       altKey: \(modifiers.contains(.option)),
                       metaKey: \(modifiers.contains(.command)) };
        const proceed = el.dispatchEvent(new KeyboardEvent('keydown', init));
        el.dispatchEvent(new KeyboardEvent('keyup', init));
        if (!proceed) return 'ok';
        if (init.key === 'Enter' && el.form && el.tagName !== 'TEXTAREA') el.form.requestSubmit();
        if (init.key === 'Backspace') document.execCommand('delete');
        if (init.key === 'Delete') document.execCommand('forwardDelete');
        return 'ok';
      })()
      """)
  }

  /// A JavaScript string literal for `text`.
  static func jsString(_ text: String) throws(BrowserError) -> String {
    try AgentBrowserScripts.literal(text)
  }
}

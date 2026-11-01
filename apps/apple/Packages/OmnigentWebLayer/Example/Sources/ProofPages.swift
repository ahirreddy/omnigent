internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// Test pages as data URLs.
extension Proofs {

  static func page(_ html: String) -> URL? {
    URL(
      string: "data:text/html;charset=utf-8,"
        + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
  }

  static let formPage = page(
    """
    <!doctype html><title>OWL form</title>
    <body style="font: 18px -apple-system; padding: 24px">
    <h2>OWL input proof</h2>
    <form onsubmit="window.submitted = (window.submitted || 0) + 1; return false">
    <input id=name style="font-size: 20px; width: 320px" placeholder="type here">
    </form>
    <p><button id=go style="font-size: 20px" onclick="window.clicks = (window.clicks || 0) + 1;
      document.querySelector('#out').textContent = 'clicked ' + window.clicks +
      ' with ' + document.querySelector('#name').value">Click me</button></p>
    <p id=out>not clicked</p>
    <script>window.clicks = 0; window.submitted = 0;</script>
    """)

  static let selectPage = page(
    """
    <!doctype html><title>OWL select</title>
    <body style="font: 18px -apple-system; padding: 24px">
    <h2>OWL select proof</h2>
    <select id=fruit style="font-size: 20px">
    <option value=apple>Apple</option><option value=banana>Banana</option>
    <option value=cherry>Cherry</option><option value=date>Date</option>
    </select>
    """)

  static let animationPage = page(
    """
    <!doctype html><title>OWL animation</title>
    <style>@keyframes spin { to { transform: rotate(360deg) } }
    #box { width: 160px; height: 160px; background: linear-gradient(45deg, #36f, #f63);
      animation: spin 1s linear infinite; margin: 40px }</style>
    <div id=box></div><p id=count></p>
    <script>window.rafFrames = 0; (function tick() { window.rafFrames++;
      document.getElementById('count').textContent = window.rafFrames;
      requestAnimationFrame(tick) })();</script>
    """)
}

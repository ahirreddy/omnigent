internal import Foundation

/// Pages for the browsing proofs (profiles, restore, find, zoom, audio, favicons).
extension Proofs {
  static func navPage(_ name: String, next: String?) -> String {
    let link = next.map { "<p><a id=next href=\"/page/\($0)\">Next page</a></p>" } ?? ""
    return """
      <!doctype html><title>\(name)</title><link rel=icon href="/icon.png">\(pageStyle)
      <h2>\(name)</h2><p id=result>\(name)</p>\(link)
      """
  }

  static let browsingPages: [String: String] = [
    "nav-one": navPage("Nav One", next: "nav-two"),
    "nav-two": navPage("Nav Two", next: "nav-three"),
    "nav-three": navPage("Nav Three", next: nil),
    "find": """
    <!doctype html><title>OWL find</title><link rel=icon href="/icon.png">\(pageStyle)
    <h2>Find in page</h2>
    <p>The owl flew. An owl hooted. Owls and one more owl. Owl, owl.</p>
    <p id=result>find</p>
    """,
    "audio": """
    <!doctype html><title>OWL audio</title>\(pageStyle)<h2>Audio</h2>
    <audio id=tone loop></audio><p id=result>idle</p>
    <script>
    // One second of a 440 Hz sine as a WAV blob, so the page plays sound without a network.
    const rate = 22050, samples = rate;
    const buffer = new ArrayBuffer(44 + samples * 2);
    const view = new DataView(buffer);
    const text = (offset, value) => [...value].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)));
    text(0, 'RIFF'); view.setUint32(4, 36 + samples * 2, true); text(8, 'WAVE'); text(12, 'fmt ');
    view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
    view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true);
    view.setUint16(34, 16, true); text(36, 'data'); view.setUint32(40, samples * 2, true);
    for (let i = 0; i < samples; i++) {
      view.setInt16(44 + i * 2, Math.sin(2 * Math.PI * 440 * i / rate) * 3000, true);
    }
    document.querySelector('#tone').src = URL.createObjectURL(new Blob([buffer], { type: 'audio/wav' }));
    window.playTone = () => document.querySelector('#tone').play()
      .then(() => { document.querySelector('#result').textContent = 'playing'; return true; },
        (e) => { document.querySelector('#result').textContent = 'error ' + e.name; return false; });
    </script>
    """,
  ]
}

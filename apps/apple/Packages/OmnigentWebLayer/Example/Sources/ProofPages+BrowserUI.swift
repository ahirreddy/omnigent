internal import Foundation

/// Pages for the 1.1 browser-UI proofs, served from `ProofServer` at `/page/<name>`.
extension Proofs {
  static let pageStyle = """
    <style>body { font: 18px -apple-system; padding: 24px } button, input { font-size: 18px;
    margin: 6px } #target, #drop { width: 260px; height: 90px; border: 2px dashed #36f;
    display: flex; align-items: center; justify-content: center; margin: 10px 0 }</style>
    """

  static let servedPages: [String: String] = [
    "dialogs": """
    <!doctype html><title>OWL dialogs</title>\(pageStyle)<h2>JavaScript dialogs</h2>
    <p id=result>none</p>
    <script>
    const log = (text) => { document.querySelector('#result').textContent = text; };
    window.runAlert = () => { alert('Hello from the page'); log('alert:done'); };
    window.runConfirm = () => log('confirm:' + confirm('Delete everything?'));
    window.runPrompt = () => log('prompt:' + prompt('Your name?', 'default name'));
    window.armUnload = () => { window.onbeforeunload = (e) => { e.preventDefault();
      e.returnValue = ''; }; log('armed'); };
    </script><button id=arm onclick="armUnload()">Arm leave warning</button>
    """,
    "permissions": """
    <!doctype html><title>OWL permissions</title>\(pageStyle)<h2>Permissions</h2>
    <p id=result>none</p>
    <script>
    const log = (text) => { document.querySelector('#result').textContent = text; };
    window.askCamera = () => navigator.mediaDevices.getUserMedia({ video: true })
      .then(() => log('camera:granted'), (e) => log('camera:' + e.name));
    window.askNotifications = () => Notification.requestPermission()
      .then((r) => log('notifications:' + r), (e) => log('notifications:' + e.name));
    </script>
    """,
    "file": """
    <!doctype html><title>OWL file</title>\(pageStyle)<h2>File input</h2>
    <input id=file type=file accept=".txt,text/plain" multiple>
    <p id=result>none</p>
    <script>document.querySelector('#file').onchange = async (e) => {
      const files = [...e.target.files];
      const texts = await Promise.all(files.map((f) => f.text()));
      document.querySelector('#result').textContent =
        files.map((f, i) => f.name + '=' + texts[i]).join(',');
    };</script>
    """,
    "download": """
    <!doctype html><title>OWL download</title>\(pageStyle)<h2>Download</h2>
    <a id=link href="/download">Download the proof file</a>
    """,
    "menu": """
    <!doctype html><title>OWL menu</title>\(pageStyle)<h2>Context menu</h2>
    <p><a id=link href="https://example.com/owl2-menu-link">A link to copy</a></p>
    <p id=text>Selectable proof text</p>
    """,
    "popup": """
    <!doctype html><title>OWL popup</title>\(pageStyle)<h2>window.open</h2>
    <button id=open onclick="window.child = window.open('/page/child', 'owlchild',
      'width=420,height=320')">Open popup</button>
    <p id=result>waiting</p>
    <script>
    window.addEventListener('message', (e) => {
      document.querySelector('#result').textContent = 'child says ' + e.data; });
    setTimeout(() => window.open('/page/child?unrequested'), 300);
    </script>
    """,
    "child": """
    <!doctype html><title>OWL child</title>\(pageStyle)<h2>Popup child</h2>
    <p id=result></p><script>
    const opener = window.opener;
    document.querySelector('#result').textContent = opener ? 'has opener' : 'no opener';
    if (opener) opener.postMessage('hi from ' + document.title, '*');
    </script>
    """,
    "ime": """
    <!doctype html><title>OWL IME</title>\(pageStyle)<h2>IME composition</h2>
    <input id=field placeholder="compose here" style="width: 320px">
    <p id=result></p><script>
    const events = []; const field = document.querySelector('#field');
    for (const type of ['compositionstart', 'compositionupdate', 'compositionend'])
      field.addEventListener(type, (e) => { events.push(type + ':' + (e.data || ''));
        document.querySelector('#result').textContent = events.join(' '); });
    window.imeEvents = events;
    </script>
    """,
    "drag": """
    <!doctype html><title>OWL drag</title>\(pageStyle)<h2>Drag and drop</h2>
    <div id=drop>Drop here</div>
    <div id=source draggable=true>drag me out</div>
    <p id=result>none</p><script>
    const drop = document.querySelector('#drop');
    drop.addEventListener('dragover', (e) => e.preventDefault());
    drop.addEventListener('drop', (e) => { e.preventDefault();
      const names = [...e.dataTransfer.files].map((f) => f.name).join('|');
      document.querySelector('#result').textContent =
        'text=' + e.dataTransfer.getData('text/plain') + ' files=' + names; });
    document.querySelector('#source').addEventListener('dragstart', (e) =>
      e.dataTransfer.setData('text/plain', 'drag me out'));
    </script>
    """,
    "color": """
    <!doctype html><title>OWL color</title>\(pageStyle)<h2>Color input</h2>
    <input id=color type=color value="#ff0000" style="width: 120px; height: 60px">
    <p id=result>none</p><script>
    document.querySelector('#color').addEventListener('change', (e) =>
      document.querySelector('#result').textContent = 'changed:' + e.target.value);
    </script>
    """,
    "agent": """
    <!doctype html><title>OWL agent</title>\(pageStyle)<h2>Agent form</h2>
    <form onsubmit="event.preventDefault(); document.querySelector('#result').textContent =
      'submitted ' + document.querySelector('#query').value">
    <label>Search <input id=query name=q placeholder="search terms"></label>
    <button id=go type=submit>Search</button></form>
    <select id=fruit><option>Apple</option><option>Banana</option></select>
    <button id=warn onclick="alert('agent alert')">Warn</button>
    <p id=result>idle</p>
    """,
  ]
}

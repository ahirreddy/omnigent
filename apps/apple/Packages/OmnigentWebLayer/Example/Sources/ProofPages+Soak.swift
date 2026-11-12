internal import Foundation

/// One page of the soak proof and what the soak may expect of it.
struct SoakPage {
  /// The page's name under `/page/`, without the `soak-` prefix.
  let name: String
  let title: String
  /// Seconds between frames the page draws with nobody touching it; nil for a page that only
  /// draws when it changes.
  let frameInterval: Double?

  static let all = [
    Self(name: "animation", title: "OWL soak animation", frameInterval: 1.0 / 60),
    Self(name: "document", title: "OWL soak document", frameInterval: nil),
    Self(name: "timers", title: "OWL soak timers", frameInterval: 0.5),
    Self(name: "app", title: "OWL soak app", frameInterval: nil),
    Self(name: "form", title: "OWL soak form", frameInterval: nil),
  ]
}

/// Pages for the soak proof, served from `ProofServer` at `/page/soak-<name>`: what a browser
/// tab spends its day showing. Each counts the input it handled in `window.soak.inputs`, and
/// draws the state its script is in as a strip of cells (`window.soak.shown`).
extension Proofs {
  /// A strip of sixteen black or white cells in the page's corner that spells a number, so a
  /// snapshot of the frame on screen can be compared with what the page's script believes.
  private static let soakState = """
    <div id=state style="position: fixed; top: 0; right: 0; display: flex"></div>
    <script>
    window.soakShow = (value) => {
      const strip = document.querySelector('#state');
      while (strip.children.length < 16) {
        const cell = document.createElement('i');
        cell.style.cssText = 'display: block; width: 12px; height: 12px';
        strip.append(cell);
      }
      window.soak.shown = value & 0xffff;
      [...strip.children].forEach((cell, index) => {
        cell.style.background = (value >> index) & 1 ? '#fff' : '#000';
      });
    };
    window.soakShow(0);
    </script>
    """

  static let soakPages: [String: String] = [
    // A compositor animation and a script animation, with a button that changes the page.
    "soak-animation": """
    <!doctype html><title>OWL soak animation</title>\(pageStyle)<h2>Animation</h2>
    <style>@keyframes spin { to { transform: rotate(360deg) } }
    #spinner { width: 120px; height: 120px; background: linear-gradient(45deg, #36f, #f63);
      animation: spin 1.5s linear infinite; margin: 24px }
    #bar { height: 16px; background: #2a6; width: 0 }</style>
    <button id=tap>Tap</button> <span id=result>0</span>
    <div id=spinner></div><div id=bar></div><p id=count></p>
    <script>
    window.soak = { inputs: 0, frames: 0 };
    </script>\(soakState)<script>
    document.querySelector('#tap').addEventListener('click', () => {
      document.querySelector('#result').textContent = ++window.soak.inputs;
      window.soakShow(window.soak.inputs);
    });
    (function tick(time) {
      window.soak.frames++;
      document.querySelector('#count').textContent = window.soak.frames;
      document.querySelector('#bar').style.width = (50 + 50 * Math.sin(time / 400)) + '%';
      requestAnimationFrame(tick);
    })(0);
    </script>
    """,
    // A long article with images, scrolled by wheel.
    "soak-document": """
    <!doctype html><title>OWL soak document</title>\(pageStyle)<h2>Document</h2>
    <p id=result>0</p><div id=sections></div>
    <script>
    window.soak = { inputs: 0 };
    </script>\(soakState)<script>
    const picture = (hue) => 'data:image/svg+xml,' + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="200"><defs><linearGradient '
      + 'id="g"><stop offset="0" stop-color="hsl(' + hue + ',70%,55%)"/><stop offset="1" '
      + 'stop-color="hsl(' + (hue + 80) + ',70%,35%)"/></linearGradient></defs><rect width="640" '
      + 'height="200" fill="url(#g)"/><circle cx="' + (60 + hue) + '" cy="100" r="70" '
      + 'fill="rgba(255,255,255,.35)"/></svg>');
    const sections = document.querySelector('#sections');
    for (let index = 1; index <= 240; index++) {
      const section = document.createElement('section');
      section.innerHTML = '<h3>Section ' + index + '</h3><img width=640 height=200 src="'
        + picture(index * 17 % 360) + '"><p>' + ('Paragraph ' + index + ' of the document. ')
          .repeat(24) + '</p>';
      sections.append(section);
    }
    addEventListener('scroll', () => {
      document.querySelector('#result').textContent = ++window.soak.inputs;
      window.soakShow(Math.round(scrollY));
    });
    </script>
    """,
    // A dashboard: cells that change twice a second, a log that grows, a button that adds to it.
    "soak-timers": """
    <!doctype html><title>OWL soak timers</title>\(pageStyle)<h2>Timers</h2>
    <style>#cells { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px }
    #cells div { border: 1px solid #99a; padding: 12px; font: 20px ui-monospace }</style>
    <button id=tap>Add a row</button> <span id=result>0</span>
    <div id=cells></div><ol id=rows></ol>
    <script>
    window.soak = { inputs: 0, ticks: 0 };
    </script>\(soakState)<script>
    const cells = document.querySelector('#cells');
    for (let index = 0; index < 12; index++) cells.append(document.createElement('div'));
    const rows = document.querySelector('#rows');
    const addRow = (text) => {
      const row = document.createElement('li');
      row.textContent = text;
      rows.prepend(row);
      while (rows.children.length > 40) rows.lastChild.remove();
    };
    setInterval(() => {
      window.soak.ticks++;
      [...cells.children].forEach((cell, index) => {
        cell.textContent = ((window.soak.ticks * (index + 3) * 7919) % 10000) / 100;
      });
      if (window.soak.ticks % 4 === 0) addRow('tick ' + window.soak.ticks);
      window.soakShow(window.soak.inputs + window.soak.ticks);
    }, 500);
    document.querySelector('#tap').addEventListener('click', () => {
      document.querySelector('#result').textContent = ++window.soak.inputs;
      addRow('tap ' + window.soak.inputs);
      window.soakShow(window.soak.inputs + window.soak.ticks);
    });
    </script>
    """,
    // A single-page app: links change the route with pushState and replace the view, and a card
    // can be dragged.
    "soak-app": """
    <!doctype html><title>OWL soak app</title>\(pageStyle)<h2>App</h2>
    <style>nav a { display: inline-block; padding: 8px 14px; margin-right: 6px;
      border: 1px solid #36f; border-radius: 6px; text-decoration: none }</style>
    <nav><a id=nav-home href="/page/soak-app/home">Home</a><a id=nav-list
    href="/page/soak-app/list">List</a><a id=nav-detail href="/page/soak-app/detail">Detail</a><a
    id=nav-settings href="/page/soak-app/settings">Settings</a><span id=card draggable=true
    style="padding: 8px 14px; border: 1px dashed #99a">Card</span></nav>
    <p id=result>0</p><main id=view>Start</main>
    <script>
    window.soak = { inputs: 0, route: 'start' };
    </script>\(soakState)<script>
    const views = {
      home: () => '<h1>Home</h1><p>' + 'Welcome back. '.repeat(40) + '</p>',
      list: () => '<h1>List</h1><ul>' + Array.from({ length: 60 }, (_, index) =>
        '<li>Item ' + index + ' of visit ' + window.soak.inputs + '</li>').join('') + '</ul>',
      detail: () => '<h1>Detail</h1><table>' + Array.from({ length: 30 }, (_, index) =>
        '<tr><td>Field ' + index + '</td><td>' + (index * window.soak.inputs) + '</td></tr>')
        .join('') + '</table>',
      settings: () => '<h1>Settings</h1>' + Array.from({ length: 12 }, (_, index) =>
        '<p><label><input type=checkbox ' + (index % 2 ? 'checked' : '') + '> Option ' + index
        + '</label></p>').join(''),
    };
    const show = (route) => {
      window.soak.route = route;
      document.querySelector('#view').innerHTML = views[route]();
      document.querySelector('#result').textContent = ++window.soak.inputs + ' ' + route;
      window.soakShow(window.soak.inputs);
    };
    // A card that is dragged within the page, as a board's are: its data is the page's own.
    document.querySelector('#card').addEventListener('dragstart', (e) => {
      e.dataTransfer.setData('application/x-soak-card', '1');
    });
    document.querySelectorAll('nav a').forEach((link) => link.addEventListener('click', (e) => {
      e.preventDefault();
      history.pushState({}, '', link.getAttribute('href'));
      show(link.id.slice(4));
    }));
    </script>
    """,
    // A form: a text field that takes typing, and a button that submits and clears it.
    "soak-form": """
    <!doctype html><title>OWL soak form</title>\(pageStyle)<h2>Form</h2>
    <form><input id=name placeholder="type here" size=40> <button id=send>Send</button></form>
    <p id=result>0</p><ol id=sent></ol>
    <script>
    window.soak = { inputs: 0, typed: 0 };
    </script>\(soakState)<script>
    const field = document.querySelector('#name');
    field.addEventListener('input', () => {
      window.soakShow(++window.soak.typed + window.soak.inputs);
    });
    document.querySelector('form').addEventListener('submit', (e) => {
      e.preventDefault();
      const row = document.createElement('li');
      row.textContent = field.value.length + ' characters';
      const sent = document.querySelector('#sent');
      sent.prepend(row);
      while (sent.children.length > 20) sent.lastChild.remove();
      field.value = '';
      document.querySelector('#result').textContent = ++window.soak.inputs;
      window.soakShow(window.soak.typed + window.soak.inputs);
    });
    </script>
    """,
  ]
}

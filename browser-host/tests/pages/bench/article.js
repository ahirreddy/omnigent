// Fills #article with deterministic dense text (headings, paragraphs, small colored text,
// a table) so every bench page renders the same content on every machine.
(() => {
  const words = ("remote browser agent stream encoder frame damage viewer cookie profile " +
    "session runner host socket protocol keyframe latency bitrate scroll render chromium " +
    "window cursor input keyboard pointer network relay tunnel decode hardware").split(" ");
  let seed = 7;
  const next = () => (seed = (seed * 1103515245 + 12345) % 2147483648);
  const sentence = (count) => {
    const parts = [];
    for (let index = 0; index < count; index++) parts.push(words[next() % words.length]);
    const text = parts.join(" ");
    return text[0].toUpperCase() + text.slice(1) + ".";
  };
  const article = document.getElementById("article");
  for (let section = 0; section < 60; section++) {
    const heading = document.createElement("h2");
    heading.textContent = `${section + 1}. ${sentence(4)}`;
    article.appendChild(heading);
    for (let paragraph = 0; paragraph < 3; paragraph++) {
      const p = document.createElement("p");
      for (let line = 0; line < 5; line++) p.append(sentence(8 + (next() % 10)) + " ");
      const note = document.createElement("span");
      note.className = "note";
      note.textContent = sentence(6);
      p.appendChild(note);
      article.appendChild(p);
    }
    if (section % 5 === 0) {
      const table = document.createElement("table");
      for (let row = 0; row < 4; row++) {
        const tr = table.insertRow();
        for (let cell = 0; cell < 5; cell++) tr.insertCell().textContent = sentence(2);
      }
      article.appendChild(table);
    }
  }
})();

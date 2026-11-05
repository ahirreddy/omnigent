"use strict";

// Called by RichBlockRenderer through callAsyncJavaScript. Each call draws one block into #out
// and returns its size in CSS pixels (and, for math, its baseline from the top), or
// { error } with the library's message.
(() => {
  const out = document.getElementById("out");
  let mermaidTheme = null;
  let diagramCount = 0;

  function measure(extra) {
    const box = out.getBoundingClientRect();
    return { width: Math.ceil(box.width), height: Math.ceil(box.height), ...extra };
  }

  function message(error) {
    return String((error && error.message) || error || "Unknown error");
  }

  async function math(tex, display, fontSize) {
    out.replaceChildren();
    out.style.fontSize = `${fontSize}px`;
    try {
      katex.render(tex, out, { displayMode: display, throwOnError: true, strict: "ignore" });
    } catch (error) {
      out.replaceChildren();
      return { error: message(error) };
    }
    const probe = document.createElement("span");
    probe.className = "baseline-probe";
    out.appendChild(probe);
    await document.fonts.ready;
    const top = out.getBoundingClientRect().top;
    return measure({ baseline: probe.getBoundingClientRect().bottom - top });
  }

  async function mermaidDiagram(source, dark) {
    out.replaceChildren();
    out.style.fontSize = "";
    if (typeof mermaid === "undefined") return { error: "Mermaid is not loaded." };
    const theme = dark ? "dark" : "default";
    if (theme !== mermaidTheme) {
      mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme });
      mermaidTheme = theme;
    }
    diagramCount += 1;
    const id = `diagram-${diagramCount}`;
    try {
      const { svg } = await mermaid.render(id, source);
      out.innerHTML = svg;
    } catch (error) {
      // A failed render leaves its error graphic in the body.
      document.getElementById(`d${id}`)?.remove();
      out.replaceChildren();
      return { error: message(error) };
    }
    // Draw at the diagram's natural size rather than the page width.
    const drawing = out.querySelector("svg");
    const box = drawing?.viewBox?.baseVal;
    if (drawing && box && box.width > 0) {
      drawing.style.maxWidth = "none";
      drawing.setAttribute("width", String(box.width));
      drawing.setAttribute("height", String(box.height));
    }
    await document.fonts.ready;
    return measure({ baseline: 0 });
  }

  window.omnigentRender = { math, mermaid: mermaidDiagram };
})();

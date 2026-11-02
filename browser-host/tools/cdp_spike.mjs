// Playwright connectOverCDP spike against omnigent-browser-host's CDP port (design doc
// section 6, "Agent-created tabs"). Prints one JSON line per check.
//   node cdp_spike.mjs <cdp_port> <page_url> <screenshot_dir>
import { chromium } from "playwright-core";

const [port, pageUrl, shots] = process.argv.slice(2);
const report = (check, ok, detail = {}) =>
  console.log(JSON.stringify({ check, ok, ...detail }));

const started = Date.now();
const browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`, { timeout: 15000 });
report("connectOverCDP", true, { ms: Date.now() - started, version: browser.version() });
const contexts = browser.contexts();
report("contexts", contexts.length > 0, {
  contexts: contexts.length,
  pages: contexts.map((context) => context.pages().map((page) => page.url())),
});

const existing = contexts[0]?.pages()[0];
if (existing) {
  try {
    await existing.goto(pageUrl, { timeout: 15000 });
    report("existing_page_goto", true, { title: await existing.title() });
    const shot = await existing.screenshot({ path: `${shots}/existing.png`, timeout: 15000 });
    report("existing_page_screenshot", shot.length > 1000, { bytes: shot.length });
    const actions = Date.now();
    await existing.click("#button", { timeout: 10000 });
    await existing.fill("#field", "from playwright", { timeout: 10000 });
    report("existing_page_click_fill_ms", true, { ms: Date.now() - actions });
    report("existing_page_input", (await existing.title()) === "typed:from playwright", {
      title: await existing.title(),
    });
  } catch (error) {
    report("existing_page", false, { error: String(error).slice(0, 400) });
  }
}

for (const [name, open] of [
  ["context_newPage", () => contexts[0].newPage()],
  ["browser_newContext_newPage", async () => (await browser.newContext()).newPage()],
]) {
  try {
    const opened = Date.now();
    const page = await open();
    report(`${name}_created`, true, { ms: Date.now() - opened });
    await page.goto(pageUrl, { timeout: 15000 });
    report(`${name}_goto`, true, { title: await page.title() });
    const shot = await page.screenshot({ path: `${shots}/${name}.png`, timeout: 15000 });
    report(`${name}_screenshot`, shot.length > 1000, { bytes: shot.length });
  } catch (error) {
    report(name, false, { error: String(error).slice(0, 400) });
  }
}

const session = await browser.newBrowserCDPSession();
try {
  const created = await session.send("Target.createTarget", { url: pageUrl });
  report("raw_Target.createTarget", true, created);
} catch (error) {
  report("raw_Target.createTarget", false, { error: String(error).slice(0, 400) });
}
const { targetInfos } = await session.send("Target.getTargets");
report("targets", true, {
  targets: targetInfos.filter((t) => t.type === "page").map((t) => ({ id: t.targetId, url: t.url })),
});
await browser.close();

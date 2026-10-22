// Compile and run every gallery sample in slides.html with the browser-built
// compiler: each must print exactly its recorded `expect`, or be refused with
// a compile error containing its `refuse`.
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { chromium } from "playwright";

const base = "http://127.0.0.1:4174/";
const server = spawn("pnpm", ["exec", "vite", "preview", "--host", "127.0.0.1", "--port", "4174", "--strictPort"], {
  stdio: ["ignore", "pipe", "pipe"],
});
let serverOutput = "";
server.stdout.on("data", (chunk) => { serverOutput += chunk; });
server.stderr.on("data", (chunk) => { serverOutput += chunk; });

async function waitForServer() {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (server.exitCode !== null) throw new Error(`Vite exited: ${serverOutput}`);
    try {
      const response = await fetch(`${base}slides.html`);
      if (response.ok) return;
    } catch { /* wait for Vite */ }
    await delay(100);
  }
  throw new Error(`Vite did not start: ${serverOutput}`);
}

let browser;
try {
  await waitForServer();
  browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1600, height: 900 } });
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(String(error)));
  await page.goto(`${base}slides.html#1`);
  await page.locator("#compiler-state.ready").waitFor({ timeout: 30000 });
  const demos = await page.evaluate(() => window.__slideDemos);
  if (!Array.isArray(demos) || demos.length === 0) throw new Error("slides: no demos registered");
  const failures = [];
  for (const demo of demos) {
    const label = `${demo.id}#${demo.sample + 1} (${demo.title})`;
    await page.evaluate((slide) => { location.hash = `#${slide}`; }, demo.slide);
    const host = page.locator(`.slide.active .demo[data-demo="${demo.id}"]`);
    await host.locator("button.run").waitFor({ timeout: 10000 });
    const tab = host.locator(`.tabs button[data-index="${demo.sample}"]`);
    if (await tab.count()) await tab.click();
    await host.locator("button.run").click();
    await page.waitForFunction(
      (id) => {
        const output = document.querySelector(`.slide.active .demo[data-demo="${id}"] .output`);
        return output && !output.classList.contains("idle");
      },
      demo.id,
      { timeout: 30000 },
    );
    const output = host.locator(".output");
    const actual = await output.textContent();
    const refused = (await output.getAttribute("class")).includes("error");
    if (demo.refuse !== undefined) {
      if (!refused || !actual.includes(demo.refuse)) {
        failures.push(`${label}: expected a refusal containing ${JSON.stringify(demo.refuse)}, got ${JSON.stringify(actual)}`);
      }
    } else if (refused || actual !== demo.expect) {
      failures.push(`${label}: expected ${JSON.stringify(demo.expect)}, got ${JSON.stringify(actual)}`);
    }
  }
  if (pageErrors.length > 0) failures.push(`page errors: ${pageErrors.join("; ")}`);
  if (failures.length > 0) throw new Error(`slides: ${failures.length} demo(s) failed\n${failures.join("\n")}`);
  console.log(`slides: ${demos.length} samples ran in Chromium (${demos.filter((d) => d.refuse !== undefined).length} refused as recorded)`);
} finally {
  await browser?.close();
  server.kill("SIGTERM");
}

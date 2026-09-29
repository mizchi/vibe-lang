import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { chromium } from "playwright";

const url = "http://127.0.0.1:4173/";
const server = spawn("pnpm", ["exec", "vite", "preview", "--host", "127.0.0.1", "--port", "4173", "--strictPort"], {
  stdio: ["ignore", "pipe", "pipe"],
});
let serverOutput = "";
server.stdout.on("data", (chunk) => { serverOutput += chunk; });
server.stderr.on("data", (chunk) => { serverOutput += chunk; });

async function waitForServer() {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (server.exitCode !== null) throw new Error(`Vite exited: ${serverOutput}`);
    try {
      const response = await fetch(url);
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
  const page = await browser.newPage();
  await page.goto(url);
  await page.getByText("Ready", { exact: true }).waitFor({ timeout: 30000 });
  for (const [preset, expected] of [
    ["effects-error", "3"],
    ["enum-match", "87"],
    ["collections", "20"],
    ["suberror", "-1"],
  ]) {
    await page.locator("#preset-select").selectOption(preset);
    await page.getByRole("button", { name: "Run", exact: true }).click();
    await page.waitForFunction(
      (value) => document.querySelector("#output")?.textContent?.trimEnd() === value,
      expected,
      { timeout: 5000 },
    );
  }
  if (!page.url().includes("#code=")) throw new Error("Editing did not produce a shareable URL");
  await page.reload();
  await page.getByText("Ready", { exact: true }).waitFor({ timeout: 30000 });
  if (await page.locator("#preset-select").inputValue() !== "suberror") {
    throw new Error("The shared URL did not restore the selected source");
  }
  const withStdout = Buffer.from(
    'export let _start = () -> Int with Console { println("hello, vibe"); Console::write_char(33); 0 }\n',
  ).toString("base64url");
  await page.goto(`${url}#code=${withStdout}`);
  await page.reload();
  await page.getByText("Ready", { exact: true }).waitFor({ timeout: 30000 });
  await page.getByRole("button", { name: "Run", exact: true }).click();
  try {
    await page.waitForFunction(
      () => document.querySelector("#output")?.textContent === "hello, vibe\n!0\n",
      null,
      { timeout: 5000 },
    );
  } catch (error) {
    throw new Error(`Stdout result was ${JSON.stringify(await page.locator("#output").textContent())}`, { cause: error });
  }
  const invalid = Buffer.from("export let _start = () -> Int { missing_name }\n").toString("base64url");
  await page.goto(`${url}#code=${invalid}`);
  await page.reload();
  await page.getByText("Ready", { exact: true }).waitFor({ timeout: 30000 });
  await page.getByRole("button", { name: "Run", exact: true }).click();
  try {
    await page.waitForFunction(
      () => document.querySelector("#output")?.textContent?.includes("missing_name"),
      null,
      { timeout: 5000 },
    );
  } catch (error) {
    throw new Error(`Compile diagnostic was ${JSON.stringify(await page.locator("#output").textContent())}`, { cause: error });
  }
  console.log("playground: four presets, stdout, shared URL, and compile diagnostic passed in Chromium");
} finally {
  await browser?.close();
  server.kill("SIGTERM");
}

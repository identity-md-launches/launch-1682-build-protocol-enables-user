// Renders web/scripts/og.html to web/public/og.png (1200x630) with Playwright.
// Playwright is not a project dependency: point IMD_PLAYWRIGHT at a Playwright index.mjs
// (for example from an npx cache) or have it importable from the current directory.
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const target = process.env.IMD_PLAYWRIGHT ? pathToFileURL(process.env.IMD_PLAYWRIGHT).href : "playwright";
const { chromium } = await import(target);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await page.goto(pathToFileURL(path.join(here, "og.html")).href);
await page.screenshot({ path: path.join(here, "..", "public", "og.png"), type: "png" });
await browser.close();
console.log("wrote web/public/og.png");

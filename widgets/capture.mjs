#!/usr/bin/env node
/**
 * Widget screenshot capture tool.
 *
 * Usage:
 *   node capture.mjs lib/calculator/widget.html [--width 360] [--height 400] [--out screenshot.png]
 *
 * If --width/--height are omitted, reads defaults from the widget's meta.json.
 * If --out is omitted, saves to the same directory as widget.html as screenshot.png.
 */
import { readFile } from "fs/promises";
import { dirname, join, resolve } from "path";
import { fileURLToPath } from "url";
import puppeteer from "puppeteer";

const __dirname = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const args = { widgetPath: null, width: null, height: null, out: null };
  let i = 2;
  while (i < argv.length) {
    const a = argv[i];
    if (a === "--width" && argv[i + 1]) {
      args.width = parseInt(argv[++i], 10);
    } else if (a === "--height" && argv[i + 1]) {
      args.height = parseInt(argv[++i], 10);
    } else if (a === "--out" && argv[i + 1]) {
      args.out = argv[++i];
    } else if (!a.startsWith("--")) {
      args.widgetPath = a;
    }
    i++;
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv);

  if (!args.widgetPath) {
    console.error("Usage: node capture.mjs <widget.html> [--width N] [--height N] [--out path.png]");
    process.exit(1);
  }

  const widgetAbsolute = resolve(__dirname, args.widgetPath);
  const widgetDir = dirname(widgetAbsolute);

  // Try to read meta.json for defaults
  let meta = { defaultWidth: 360, defaultHeight: 400 };
  try {
    const raw = await readFile(join(widgetDir, "meta.json"), "utf-8");
    meta = { ...meta, ...JSON.parse(raw) };
  } catch {
    // No meta.json, use defaults
  }

  const width = args.width || meta.defaultWidth;
  const height = args.height || meta.defaultHeight;
  const outPath = args.out ? resolve(args.out) : join(widgetDir, "screenshot.png");

  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
  });

  const page = await browser.newPage();
  await page.setViewport({ width, height, deviceScaleFactor: 2 });

  // Dark background to match iPad canvas
  await page.evaluate(() => {
    document.body.style.margin = "0";
    document.body.style.background = "#000000";
  });

  await page.goto(`file://${widgetAbsolute}`, { waitUntil: "networkidle0" });

  // Small delay for any CSS transitions / JS renders
  await new Promise((r) => setTimeout(r, 300));

  await page.screenshot({ path: outPath, type: "png" });
  await browser.close();

  console.log(outPath);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

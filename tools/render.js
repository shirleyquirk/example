// Render an SVG (or HTML) file to PNG for a quick look.
//   node tools/render.js in.svg out.png [scale]
// Uses the pre-installed Playwright Chromium. Loads via file:// (not
// setContent, which can't read local images).
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const [input, output, scale = '2'] = process.argv.slice(2);
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1200, height: 900 }, deviceScaleFactor: Number(scale) });
  await p.goto('file://' + path.resolve(input));
  const svg = await p.$('svg');
  if (svg) await svg.screenshot({ path: output }); else await p.screenshot({ path: output, fullPage: true });
  await b.close();
})();

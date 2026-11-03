// Regression test for the built app (index.html) in headless Chromium.
//   node tools/browser-test.js          (after `nim build`)
// Expected values are hand-worked or Monte Carlo checked (see tests/test_odds.nim).
const { chromium } = require('playwright');
const path = require('path');
const page = 'file://' + path.resolve(__dirname, '..', 'index.html');

(async () => {
  const browser = await chromium.launch();
  const p = await browser.newPage({ viewport: { width: 390, height: 844 } });
  const errors = [];
  p.on('pageerror', e => errors.push(e.message));
  p.on('dialog', d => d.accept());
  let failed = 0;
  const big = async () => (await p.textContent('#oddsOut')).slice(0, 6);
  const expect = async (label, got, want) => {
    const ok = got.startsWith(want);
    if (!ok) failed++;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}: got ${got}, want ${want}`);
  };

  await p.goto(page);
  await p.evaluate(() => localStorage.clear());
  await p.reload();
  await p.click('.chip[data-symbol="0"] .g');                       // Void, tap on the glyph
  await expect('Void, danger, blank safe (31/40)', await big(), '77.5%');
  await p.click('#modeSeg button[data-v="0"]');
  await expect('Void, safe (9/40)', await big(), '22.5%');
  await p.click('#blankSeg2 button[data-v="0"]');
  await expect('Void, safe, blank danger (8/40)', await big(), '20.0%');
  await p.click('#blankSeg2 button[data-v="1"]');
  await p.fill('#played', '5'); await p.fill('#safePlayed', '2');
  await expect('5 played, 2 safe (7/35)', await big(), '20.0%');
  await p.click('.chip[data-symbol="1"]');                          // + Caves
  await p.fill('#played', '10'); await p.fill('#safePlayed', '4');
  await p.fill('#playedVoid', '1'); await p.fill('#draw', '2');
  await p.click('#modeSeg button[data-v="1"]');
  await expect('Monte Carlo case (0.6491)', await big(), '64.8%');
  await p.click('.chip[data-symbol="2"]'); await p.click('.chip[data-symbol="2"]');
  await expect('typed per-symbol count survives chip toggles', await p.inputValue('#playedVoid'), '1');
  await p.click('.step[data-t="played"][data-d="1"]');
  await expect('stepper', await p.inputValue('#played'), '11');

  // matrix editing: persist, reject garbage, restore
  await p.click('#gear'); await p.click('#lockBtn');
  await p.click('td[data-card="0"][data-symbol="1"]');
  await expect('edit marks deck as changed', await p.textContent('#matrixNote'), 'Edited');
  await p.reload();
  await expect('edit persists across reload', await p.textContent('#matrixNote'), 'Edited');
  await p.evaluate(() => localStorage.setItem('vo.deckBySymbol', 'A:0,99;B:'));
  await p.reload();
  await expect('malformed save is ignored', await p.textContent('#matrixNote'), 'Matches');
  await expect('matrix has header + 40 cards + totals', String(await p.locator('#matrix tr').count()), '42');

  if (errors.length) { failed++; console.log('page errors:', errors); }
  await browser.close();
  console.log(failed ? `${failed} FAILED` : 'all passed');
  process.exit(failed ? 1 : 0);
})();

# Working notes

State of the project, decisions and why, open questions, and how to pick it up
again in a fresh environment. Kept for whoever (human or Claude) continues.

## Branches

- `symbol-odds`: the phone app (orphan branch, no shared history with `main`).
  Also contains the first hardware commit (`744bed9`); reverting it there is an
  open offer, not done.
- `hardware`: everything on `symbol-odds` plus the physical version. **Work here.**
- `main`: unrelated original repo content.

## The game and the data

- Game: **ISS Vanguard** (Awaken Realms). 40 cards, 12 biome symbols (the 13th,
  Tutorial, isn't in this deck). Letters A–M (no J) are the owner's notebook
  columns: A Void, B Caves, C Volcanic, D Hostile, E Crystalline, F Deadly,
  G Vegetation, H Water, I Ruins, K Frigid, L Rocky, M Desert (owner confirmed).
- Source photos: `docs/source/notebook-grid.jpg` (the 40 × 12 grid) and
  `notebook-symbols.jpg` (sketches + counts). Rulebook icon page:
  `hardware/icons/source/biome-icons.png`.
- Transcription method (photo → `NotebookDeck`): crops rotated about −3.6°,
  ruled lines found from row-darkness profiles at several x positions, a
  linear model of line position vs x fitted, and each mark assigned to the
  band it falls in. Every mark sat 0.3–0.7 of the way between lines (no
  ambiguous ones). Checks: all 12 column totals match the owner's
  (A8 B13 C11 D5 E4 F11 G11 H10 I13 K9 L13 M12 = 120). 39 rows have marks; the
  owner's note says 40 cards, so card 40 is blank. A scribble in column C,
  row 2, was excluded (including it would make C = 12).
- Blank card: owner believes it's **safe** (matches everything). It's a
  setting in the app; physically, the blank-safe token.
- Game semantics: cards that MATCH the selected symbols are safe (time tracks
  don't advance). Danger = no selected symbol. Danger chance, next card =
  danger cards left / cards left.

## App (`src/`)

- Nim → JS (`nim build`), single self-contained `index.html`, service worker for
  offline after adding to the Home Screen. "Save as" on iPhone probably won't
  run JS from Files (unverified), hence the Home Screen route.
- Model: `Deck = array[Symbol, Cards]`, `Cards = set[CardIndex]`, per symbol the
  cards showing it. Everything (notebook data, matrix view, save format) uses
  this per-symbol form, at the owner's request.
- Maths (`odds.nim`): played cards a uniform random subset; observed counts
  over card sets; DP over "kinds" of interchangeable cards; hypergeometric for
  the next N cards. Verified by hand cases and Monte Carlo (see tests).
- Owner preferences learned: proper types over ints, no globals, readable
  names, comments explaining the maths; Nim-only build (`config.nims` tasks run
  commands, generators are compiled programs, NOT NimScript); for docs and
  tests use whatever tool fits (gnuplot, Python/schemdraw are fine).

## Hardware (`hardware/`) — current design

- **Tokens**: 3 mm plywood regular octagons, 80 mm across flats, icon engraved
  in the centre (40 mm), no text. 40 equal leaning slots (6 × 2.2 mm), 5 per side.
  Card i = slot (i mod 5) on side (i div 5). A slot is cut where the card does
  NOT show the symbol, so stacking (an AND of open slots) lights exactly the
  danger cards.
- **Keyed corner**: the stand's corner pieces are all alike, but at the upper-left
  corner one strip is set in by one wall thickness (3 mm), parallel to its side;
  the token has a matching step on that side of that corner only (owner's
  design). Flip test passes for all 8 rotations.
- **Stand**: tab-and-slot plywood: base, floor (= baffle, 40 slots), four corner
  pieces (two strips each, meeting at the corner with 135° finger joints: fingers
  reach the far side of the slabs' overlap parallelogram, gaps stop at the near
  side), lid on the strip tops. `Fit` = 0.1 mm per side, to be tuned after a
  test cut. History: stacked glued rings (owner: ugly/fussy) → separate strips
  + key fin + notch → uneven clipped corner + angled strip → corner pieces that
  meet with finger joints, keyed by setting one strip in (owner's design).
- Token outline is non-convex (the key step): geometry tests use proper
  point-in-polygon and distance-to-segment, not the convex shortcut.
- **Light**: lid with 40 LEDs, one over each slot, battery powered. Owner says
  light leaks are fine (no skirt).
- **Detection**: octagonal sensor board, 40 visible-light detectors (e.g.
  ALS-PT19 class) + 74HC14 Schmitt triggers + 40 equal resistors into one node
  (popcount ∝ voltage, linear by construction). Factory-assembled (JLCPCB/PCBWay
  PCBA, ~$40–70 for 5 boards). Single-photodiode option considered: cheaper but
  unproven (~±1 card, speculation).
- **Inputs**: two pots with printed 0–40 dials (owner OK trading accuracy for
  simplicity; thumbwheels were the precise option).
- **Maths**: pot divider: the "cards played" pot as the input resistor of an
  inverting amp (gain ∝ 1/cards left), one quad op-amp:
  V_P = 10 V·(D − d)/(40 − n). `schematics/rheostat-divider.svg`. Not yet
  simulated with pot error. Precise alternative: duty-cycle servo divider
  (simulated, 0.08 % FS; `schematics/duty-cycle-divider.svg`).
- **Display**: **danger meter**: analog panel meter with green/yellow/red dial
  (`nim meter`; zones at 33 / 66 %, owner may change). IN-13 kept as an option
  (`in13-scale.svg`); its specs in the README are from memory, check the datasheet.
- Owner has a Moog Matriarch only (no Eurorack rack), so Eurorack patching of
  the divider is off the table.

## Findings worth remembering

- The resistor-tolerance Monte Carlo showed my first error budget was wrong:
  late in the game the precision chain subtracts nearly equal large voltages,
  so 0.1 % resistors give up to 1.4 % FS; 0.01 % matched pairs give 0.44 %.
- Black acrylic can pass infrared; most phototransistors peak in IR. Use
  visible-light detectors, and test the token material.
- Divider sims need ~0.3 s settling (output filter dominates), `uic` for the
  transient (the integrator has no DC operating point), and `wrdata` before
  `meas` (a meas named vp hides the node vector vp).

## Environment (container is ephemeral; reinstall)

```
apt-get install -y nim ngspice gnuplot-nox potrace imagemagick   # nim 1.6.14 from Ubuntu
pip install schemdraw                                            # schematics only
# Chromium + Playwright are pre-installed: require('playwright') works anywhere
```
nim-lang.org and most game/rules sites are blocked by the network policy;
the Ubuntu archive, PyPI, npm and GitHub (git) are reachable.

## Tasks and checks

```
nim test      unit tests (odds, deck, tokens, stand geometry)
nim build     tests + app → index.html;  then: node tools/browser-test.js
nim plates    token SVGs            nim cup     stand + board outlines
nim meter     danger meter dial     nim sim     chain vs app (ngspice)
nim results   all simulations → hardware/results/ (ngspice, gnuplot)
nim icons     re-trace icons (ImageMagick, potrace)
python3 hardware/schematics/draw.py   schematics (schemdraw)
node tools/render.js file.svg out.png  quick visual check of any SVG
```

## Open questions / next steps

1. Owner: measure the panel meter (face, pivot, sweep) → set `meter.nim` constants.
2. Test cut: one strip, key strip, floor corner, two tokens; tune `Fit`; check
   the clipped corner keys and how icons engrave on ply.
3. Breadboard one channel: LED, visible detector, 74HC14, through 2–3 ply tokens.
4. KiCad: sensor board from `hardware/cup/sensor-board.svg` (positions in blue),
   then the LED board (mirrored positions).
5. Simulate the pot divider with realistic pot linearity; draw the meter driver.
6. Zone thresholds: 33 / 66 % is a guess.
7. Offer pending: revert the hardware commit from `symbol-odds`.

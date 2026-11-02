# Symbol Odds (ISS Vanguard)

A one-page phone tool for a card game: 40 cards, 12 symbols (A–M, no J), each card shows zero or more symbols.

- **Count**: tap symbols → how many cards show at least one of them (and how many show all).
- **Odds**: enter how many cards have been played and whatever you know about them
  (how many matched any selected symbol, and/or how many showed each symbol; blank = unknown).
  It gives the exact chance that the next *S* cards include at least one selected symbol.

The maths is exact: played cards are treated as a uniformly random subset, conditioned on what you entered
(cards are grouped by which selected symbols they show, and a small DP sums over the possibilities), then a
hypergeometric draw from what's left.

## Use on iPhone
Open the GitHub Pages URL in Safari → Share → **Add to Home Screen**. After one online visit it works offline
(service worker). `index.html` is fully self-contained, so it also works opened from any local copy that runs JavaScript.

## Data
Letters map to ISS Vanguard biomes: A Void, B Water, C Volcanic, D Hostile, E Caves, F Deadly, G Vegetation, H Desert, I Ruins, K Frigid, L Rocky, M Crystalline (E/M least certain).
Transcribed from the notebook grid in `src/app.nim` (`CardRows`). Column totals: A8 B13 C11 D5 E4 F11 G11 H10 I13 K9 L13 M12 = 120 marks
over 39 cards; the 40th card has no symbols. Glyphs are emoji stand-ins for the hand-drawn symbols (`Glyphs`).

## Build
Source is Nim (JS backend). Requires `nim` (tested with 1.6.14) and `python3`:

    ./build.sh      # src/app.nim -> build/app.js -> inlined into index.html

`build/app.js` and `index.html` are committed so Pages serves them without a build step.

# Symbol Odds (ISS Vanguard)

A one-page phone tool for a card game: 40 cards, 12 symbols (A–M, no J), each card shows zero or more symbols.

- **Count**: tap symbols → how many cards show at least one of them (and how many show all).
- **Odds**: Danger (next card has none of the selected symbols) or Safe (has one); defaults to Danger. Blank card counts as Safe by default (Settings ⚙︎).
  (how many matched any selected symbol, and/or how many showed each symbol; blank = unknown).
  It gives the exact chance that the next *S* cards include at least one selected symbol.

The maths is exact: played cards are treated as a uniformly random subset, conditioned on what you entered
(cards are grouped by which selected symbols they show, and a small DP sums over the possibilities), then a
hypergeometric draw from what's left.

## Use on iPhone
Open the GitHub Pages URL in Safari → Share → **Add to Home Screen**. After one online visit it works offline
(service worker). `index.html` is fully self-contained, so it also works opened from any local copy that runs JavaScript.

## Code
- `src/model.nim`: `Symbol` enum; `Cards = set[CardIndex]` with `CardIndex = range[0..39]`; `Deck = array[Symbol, Cards]`, i.e. for each symbol the cards showing it (one notebook column). "Cards with X or Y" is `card(deck[X] + deck[Y])`. The notebook data, matrix view and save format all use this per-symbol form.
- `src/odds.nim`: the probability calculation, explained in comments. Works only on card sets (no symbols, no blank rule, no UI).
- `src/page.nim`: the static page (htmlgen), with `src/style.css` inlined at build time.
- `src/storage.nim`: saving settings and matrix edits in localStorage.
- `src/app.nim`: the page. All state is in one `App` object owned by `main`.
- `tests/test_odds.nim`: checks against hand-worked answers and Monte Carlo results.

## Data
Letters map to ISS Vanguard biomes: A Void, B Caves, C Volcanic, D Hostile, E Crystalline, F Deadly, G Vegetation, H Water, I Ruins, K Frigid, L Rocky, M Desert.
Column totals: A8 B13 C11 D5 E4 F11 G11 H10 I13 K9 L13 M12 = 120 symbols over 39 cards; the 40th card is blank.

## Build and test
Requires only `nim` (tested with 1.6.14). Tasks are in `config.nims`:

    nim test     # unit tests (C backend)
    nim build    # tests, then src/app.nim -> build/app.js, then writes index.html

`src/page.nim` is the page shell, written with `std/htmlgen`; the app renders with htmlgen too.
`build/app.js` and `index.html` are committed so Pages serves them without a build step.

## The cards and their symbols, as transcribed from the notebook grid.
##
## The deck is stored per symbol: for each symbol, the set of cards that show
## it (one column of the notebook grid). Questions like "how many cards show
## X or Y" are then set operations: `card(deck[X] + deck[Y])`.

type
  Symbol* = enum
    ## The ISS Vanguard biome icons (the Tutorial biome isn't in this deck).
    Void, Caves, Volcanic, Hostile, Crystalline, Deadly,
    Vegetation, Water, Ruins, Frigid, Rocky, Desert

const DeckSize* = 40

type
  CardIndex* = range[0 .. DeckSize - 1]
    ## A card's row in the notebook grid.
  Cards* = set[CardIndex]
    ## Some cards of the deck.
  Deck* = array[Symbol, Cards]
    ## For each symbol, the cards that show it. The number of cards is fixed
    ## by `CardIndex`; editing changes which cards show a symbol, never how
    ## many cards there are.

  BlankRule* = enum
    blankIsSafe    ## a blank card matches every symbol
    blankIsDanger  ## a blank card matches nothing

iterator items*(_: typedesc[CardIndex]): CardIndex =
  ## `for index in CardIndex:` visits every card.
  for index in CardIndex.low .. CardIndex.high: yield index

const
  AllCards*: Cards = {CardIndex.low .. CardIndex.high}
  Letter*: array[Symbol, char] =
    ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'K', 'L', 'M']
    ## Column letters used in the notebook (there is no J).
  Glyph*: array[Symbol, string] =
    ["🌀", "🕳️", "🌋", "🎯", "💎", "☠️", "🌿", "💧", "🏛️", "❄️", "🪨", "🏜️"]
    ## Emoji stand-ins for the printed icons.

# The notebook grid, column by column: the rows (0-based) marked in each
# symbol's column. Rows 0-26 are page 1, rows 27-38 are page 2, and row 39 is
# the blank card, which isn't in the notebook.
const NotebookDeck*: Deck = [
  Void:        {0, 4, 9, 13, 14, 16, 22, 34},
  Caves:       {1, 5, 18, 19, 21, 23, 24, 25, 27, 30, 32, 35, 36},
  Volcanic:    {2, 5, 15, 18, 19, 24, 25, 27, 31, 33, 37},
  Hostile:     {2, 6, 7, 11, 28},
  Crystalline: {3, 13, 24, 38},
  Deadly:      {4, 5, 9, 16, 20, 25, 27, 29, 33, 34, 37},
  Vegetation:  {4, 5, 6, 8, 10, 18, 20, 24, 26, 28, 38},
  Water:       {4, 9, 14, 17, 22, 23, 28, 29, 34, 38},
  Ruins:       {5, 8, 12, 18, 19, 21, 25, 27, 30, 32, 34, 35, 36},
  Frigid:      {16, 18, 20, 21, 25, 27, 32, 34, 38},
  Rocky:       {18, 19, 20, 21, 22, 23, 24, 26, 28, 30, 33, 36, 38},
  Desert:      {20, 25, 26, 27, 28, 29, 31, 32, 34, 35, 37, 38}]

const NotebookPage1Rows = 27

proc notebookLabel*(index: CardIndex): string =
  ## Where a card sits in the notebook, as "page·row", for checking against
  ## the paper copy.
  if index < NotebookPage1Rows: "1·" & $(index + 1)
  elif index < DeckSize - 1: "2·" & $(index - NotebookPage1Rows + 1)
  else: "extra"

# ---------------------------------------------------------------- queries

proc withAny*(deck: Deck, symbols: set[Symbol]): Cards =
  ## Cards showing at least one of `symbols`.
  for symbol in symbols: result = result + deck[symbol]

proc withAll*(deck: Deck, symbols: set[Symbol]): Cards =
  ## Cards showing every one of `symbols` (none if `symbols` is empty).
  if symbols == {}: return {}
  result = AllCards
  for symbol in symbols: result = result * deck[symbol]

proc blank*(deck: Deck): Cards =
  ## Cards with no symbols at all.
  AllCards - deck.withAny({Symbol.low .. Symbol.high})

proc safe*(deck: Deck, selected: set[Symbol], rule: BlankRule): Cards =
  ## The cards that count as a match for the selected symbols.
  result = deck.withAny(selected)
  if rule == blankIsSafe: result = result + deck.blank

proc toggle*(deck: var Deck, index: CardIndex, symbol: Symbol) =
  if index in deck[symbol]: deck[symbol].excl index
  else: deck[symbol].incl index

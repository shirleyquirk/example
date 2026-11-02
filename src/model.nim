## The cards and their symbols, as transcribed from the notebook grid.
##
## The deck is stored per symbol: for each symbol, the set of cards that show
## it. Questions like "how many cards show X or Y" are then set operations:
## `card(deck[X] + deck[Y])`.

type
  Symbol* = enum
    ## The ISS Vanguard biome icons (the Tutorial biome isn't in this deck).
    Void, Caves, Volcanic, Hostile, Crystalline, Deadly,
    Vegetation, Water, Ruins, Frigid, Rocky, Desert

const DeckSize* = 40

type
  CardIndex* = range[0 .. DeckSize - 1]
    ## A card's position in the notebook transcription.
  Cards* = set[CardIndex]
    ## Some cards of the deck.
  Deck* = array[Symbol, Cards]
    ## For each symbol, the cards that show it. The number of cards is fixed
    ## by `CardIndex`; editing changes which cards show a symbol, never how
    ## many cards there are.

  BlankRule* = enum
    blankIsSafe    ## a blank card matches every symbol
    blankIsDanger  ## a blank card matches nothing

const
  AllCards*: Cards = {CardIndex.low .. CardIndex.high}
  Letter*: array[Symbol, char] =
    ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'K', 'L', 'M']
    ## Column letters used in the notebook (there is no J).
  Glyph*: array[Symbol, string] =
    ["🌀", "🕳️", "🌋", "🎯", "💎", "☠️", "🌿", "💧", "🏛️", "❄️", "🪨", "🏜️"]
    ## Emoji stand-ins for the printed icons.

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

proc symbolsOn*(deck: Deck, index: CardIndex): set[Symbol] =
  ## The symbols printed on one card.
  for symbol in Symbol:
    if index in deck[symbol]: result.incl symbol

proc toggle*(deck: var Deck, index: CardIndex, symbol: Symbol) =
  if index in deck[symbol]: deck[symbol].excl index
  else: deck[symbol].incl index

# ---------------------------------------------------------------- text form
# One string of letters per card, e.g. "BCF" for {Caves, Volcanic, Deadly}.
# Used for the notebook data and for saving edits.

proc parseRows*(rows: openArray[string], deck: var Deck): bool =
  ## Fills `deck` from exactly `DeckSize` rows; false (deck untouched) otherwise.
  if rows.len != DeckSize: return false
  var parsed: Deck
  for index, row in rows:
    for ch in row:
      for symbol in Symbol:
        if Letter[symbol] == ch: parsed[symbol].incl CardIndex(index)
  deck = parsed
  true

proc toRows*(deck: Deck): seq[string] =
  for index in AllCards:
    var row = ""
    for symbol in deck.symbolsOn(index): row.add Letter[symbol]
    result.add row

const
  NotebookPage1Rows = 27  ## rows on the first notebook page; the rest are on page 2
  NotebookRows: array[DeckSize, string] = [
    # page 1
    "A", "B", "CD", "E", "AFGH", "BCFGI", "DG", "D", "GI", "AFH",
    "G", "D", "I", "AE", "AH", "C", "AFK", "H", "BCGIKL", "BCIL",
    "FGKLM", "BIKL", "AHL", "BHL", "BCEGL", "BCFIKM", "GLM",
    # page 2
    "BCFIKM", "DGHLM", "FHM", "BIL", "CM", "BIKM", "CFL", "AFHIKM", "BIM",
    "BIL", "CFM", "EGHKLM",
    # not in the notebook: the one blank card
    ""]

proc notebookDeck(): Deck =
  doAssert parseRows(NotebookRows, result)

const NotebookDeck*: Deck = notebookDeck()
  ## The deck as transcribed. Column totals: A8 B13 C11 D5 E4 F11 G11 H10
  ## I13 K9 L13 M12 = 120 symbols.

proc notebookLabel*(index: CardIndex): string =
  ## Where a card sits in the notebook, as "page·row", for checking against
  ## the paper copy.
  if index < NotebookPage1Rows: "1·" & $(index + 1)
  elif index < DeckSize - 1: "2·" & $(index - NotebookPage1Rows + 1)
  else: "extra"

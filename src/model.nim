## The cards and their symbols, as transcribed from the notebook grid.

type
  Symbol* = enum
    ## The ISS Vanguard biome icons (the Tutorial biome isn't in this deck).
    Void, Caves, Volcanic, Hostile, Crystalline, Deadly,
    Vegetation, Water, Ruins, Frigid, Rocky, Desert

  Card* = set[Symbol]
    ## The symbols printed on one card. `{}` is a blank card.

const DeckSize* = 40

type Deck* = array[DeckSize, Card]
  ## The whole deck, blank card included. Being an array, it always has
  ## exactly `DeckSize` cards; editing can change a card's symbols but never
  ## the number of cards.

const
  Letter*: array[Symbol, char] =
    ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'K', 'L', 'M']
    ## Column letters used in the notebook (there is no J).
  Glyph*: array[Symbol, string] =
    ["🌀", "🕳️", "🌋", "🎯", "💎", "☠️", "🌿", "💧", "🏛️", "❄️", "🪨", "🏜️"]
    ## Emoji stand-ins for the printed icons.

proc parseCard*(letters: string): Card =
  ## "BCF" -> {Caves, Volcanic, Deadly}. Unknown characters are ignored.
  for ch in letters:
    for symbol in Symbol:
      if Letter[symbol] == ch: result.incl symbol

proc toLetters*(card: Card): string =
  for symbol in card: result.add Letter[symbol]

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

proc parseDeck(rows: array[DeckSize, string]): Deck =
  for index, row in rows: result[index] = parseCard(row)

const NotebookDeck*: Deck = parseDeck(NotebookRows)
  ## The deck as transcribed. Column totals: A8 B13 C11 D5 E4 F11 G11 H10
  ## I13 K9 L13 M12 = 120 symbols.

proc notebookLabel*(index: int): string =
  ## Where card `index` sits in the notebook, as "page·row", for checking
  ## against the paper copy.
  if index < NotebookPage1Rows: "1·" & $(index + 1)
  elif index < DeckSize - 1: "2·" & $(index - NotebookPage1Rows + 1)
  else: "extra"

proc cardsWith*(deck: Deck, symbol: Symbol): int =
  for card in deck:
    if symbol in card: inc result

proc cardsWithAll*(deck: Deck, symbols: set[Symbol]): int =
  for card in deck:
    if symbols <= card: inc result

proc cardsWithAny*(deck: Deck, symbols: set[Symbol]): int =
  for card in deck:
    if card * symbols != {}: inc result

proc blankCards*(deck: Deck): int =
  for card in deck:
    if card == {}: inc result

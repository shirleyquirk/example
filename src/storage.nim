## Saving settings and matrix edits in the browser (localStorage).
## Every access is guarded: storage can be missing or blocked (private mode),
## in which case reads return "" and writes do nothing.

import std/[strutils, options]
import model, odds

proc storageGet(key: cstring): cstring {.importjs:
  "(function(k){try{return localStorage.getItem(k)||''}catch(e){return ''}})(#)".}
proc storageSet(key, value: cstring) {.importjs:
  "(function(k,v){try{localStorage.setItem(k,v)}catch(e){}})(#,#)".}
proc storageRemove(key: cstring) {.importjs:
  "(function(k){try{localStorage.removeItem(k)}catch(e){}})(#)".}

const
  BlankRuleKey = "vo.blankRule"
  HeadlineKey = "vo.headline"
  DeckKey = "vo.deckBySymbol"   # per-symbol format; older "vo.deck" saves are ignored


proc loadBlankRule*(default: BlankRule): BlankRule =
  case $storageGet(BlankRuleKey)
  of "safe": blankIsSafe
  of "danger": blankIsDanger
  else: default

proc saveBlankRule*(rule: BlankRule) =
  storageSet(BlankRuleKey, if rule == blankIsSafe: cstring"safe" else: cstring"danger")

proc loadHeadline*(default: Outcome): Outcome =
  case $storageGet(HeadlineKey)
  of "safe": Safe
  of "danger": Danger
  else: default

proc saveHeadline*(outcome: Outcome) =
  storageSet(HeadlineKey, if outcome == Safe: cstring"safe" else: cstring"danger")

# The deck is saved the same way it is stored: per symbol, the cards that
# show it, e.g. "A:0,4,9;B:1,5;...;M:20,25". A symbol with no cards is "C:".

proc encodeDeck(deck: Deck): string =
  var parts: seq[string]
  for symbol in Symbol:
    var indices: seq[string]
    for index in deck[symbol]: indices.add $index
    parts.add Letter[symbol] & ":" & indices.join(",")
  parts.join(";")

proc decodeDeck(text: string): Option[Deck] =
  ## None unless every symbol appears exactly once with valid card indices.
  var deck: Deck
  var seen: set[Symbol]
  for part in text.split(';'):
    let fields = part.split(':')
    if fields.len != 2 or fields[0].len != 1: return
    var found = false
    for symbol in Symbol:
      if Letter[symbol] == fields[0][0] and symbol notin seen:
        seen.incl symbol
        found = true
        if fields[1].len > 0:
          for item in fields[1].split(','):
            let index = try: parseInt(item) except ValueError: -1
            if index notin CardIndex.low .. CardIndex.high: return
            deck[symbol].incl CardIndex(index)
    if not found: return
  if seen == {Symbol.low .. Symbol.high}: result = some(deck)

proc loadDeck*(): Deck =
  ## The edited deck if a valid one was saved, otherwise the notebook's.
  decodeDeck($storageGet(DeckKey)).get(NotebookDeck)

proc saveDeck*(deck: Deck) =
  if deck == NotebookDeck: storageRemove(DeckKey)
  else: storageSet(DeckKey, cstring(encodeDeck(deck)))

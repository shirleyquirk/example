## Saving settings and matrix edits in the browser (localStorage).
## Every access is guarded: storage can be missing or blocked (private mode),
## in which case reads return "" and writes do nothing.

import std/strutils
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
  DeckKey = "vo.deck"

proc encodeDeck(deck: Deck): string =
  var rows: seq[string]
  for card in deck: rows.add card.toLetters
  rows.join(",")

proc decodeDeck(text: string, deck: var Deck): bool =
  ## Only accepts exactly `DeckSize` rows, so a bad save can't break the
  ## deck-size invariant.
  let rows = text.split(',')
  if rows.len != DeckSize: return false
  for index, row in rows: deck[index] = parseCard(row)
  true

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

proc loadDeck*(): Deck =
  ## The edited deck if one was saved, otherwise the notebook transcription.
  result = NotebookDeck
  var edited: Deck
  if decodeDeck($storageGet(DeckKey), edited): result = edited

proc saveDeck*(deck: Deck) =
  if deck == NotebookDeck: storageRemove(DeckKey)
  else: storageSet(DeckKey, cstring(encodeDeck(deck)))

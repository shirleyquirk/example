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
  ## A save with the wrong number of rows is ignored (see `parseRows`).
  result = NotebookDeck
  discard parseRows(($storageGet(DeckKey)).split(','), result)

proc saveDeck*(deck: Deck) =
  if deck == NotebookDeck: storageRemove(DeckKey)
  else: storageSet(DeckKey, cstring(deck.toRows.join(",")))

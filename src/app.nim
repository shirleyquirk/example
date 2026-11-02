## The page: reads the inputs, calls `odds`, renders the results.
## Compiled with `nim js` (see build.sh).

import std/[dom, strutils, options]
import model, odds, storage

const MaxDrawRows = 8  ## rows in the "next N cards" table

type
  App = ref object
    ## All page state. Owned by `main`; event handlers close over it.
    deck: Deck
    selected: set[Symbol]
    played: Natural                         ## cards already played
    safePlayed: Option[Natural]             ## how many of them were safe, if known
    symbolPlayed: array[Symbol, Option[Natural]]  ## how many showed each symbol, if known
    draw: Positive               ## how many cards the headline asks about
    blankRule: BlankRule
    headline: Outcome            ## which outcome the big number shows
    editingMatrix: bool

# ---------------------------------------------------------------- helpers

proc element(id: string): Element = document.getElementById(id.cstring)

proc percent(chance: float): string =
  if chance >= 0.9995 and chance < 1.0: return ">99.9%"
  if chance > 0 and chance < 0.0005: return "<0.1%"
  formatFloat(chance * 100, ffDecimal, 1) & "%"

proc readCount(id: string): Option[Natural] =
  ## A number box; empty or invalid means "unknown".
  try:
    let value = parseInt(strip($element(id).value))
    if value >= 0: result = some(Natural(value))
  except ValueError: discard

proc label(symbol: Symbol): string = Glyph[symbol] & " " & $symbol

proc describe(symbols: set[Symbol]): string =
  var parts: seq[string]
  for symbol in symbols: parts.add symbol.label
  parts.join(" or ")

proc plural(n: int, word: string): string =
  $n & " " & word & (if n == 1: "" else: "s")

proc outcomeWord(outcome: Outcome): string =
  if outcome == Safe: "<b class=ok>safe</b>" else: "<b class=bad>danger</b>"

proc blankRuleWords(rule: BlankRule): string =
  if rule == blankIsSafe: "<b class=ok>matches all (safe)</b>"
  else: "<b class=bad>matches none (danger)</b>"

proc highlightSegment(id: string, firstOn: bool) =
  ## Two-button toggles: mark the first or the second button as selected.
  for index, button in element(id).querySelectorAll("button"):
    if (index == 0) == firstOn: button.classList.add("on")
    else: button.classList.remove("on")

proc closestWith(target: EventTarget, selector: string): Element =
  ## The element matching `selector` that contains the tapped element.
  {.emit: [result, " = ", target, ".closest(", selector.cstring, ");"].}

proc dataInt(element: Element, name: string): int =
  ## Integer `data-` attribute, or -1 if absent.
  if element == nil: return -1
  try: parseInt($element.getAttribute(cstring("data-" & name)))
  except ValueError: -1

# ---------------------------------------------------------------- reading input

proc readInputs(app: App) =
  app.played = readCount("played").get(Natural 0)
  app.safePlayed = readCount("safePlayed")
  for symbol in Symbol:
    app.symbolPlayed[symbol] =
      if symbol in app.selected: readCount("played" & $symbol)
      else: none(Natural)
  app.draw = max(1, readCount("draw").get(Natural 1).int)

proc safeCards(app: App): Cards = app.deck.safe(app.selected, app.blankRule)

proc observation(app: App): Observation =
  ## Turns the numbers typed in into counts over sets of cards.
  result.played = app.played
  if app.safePlayed.isSome:
    result.counts.add Count(cards: app.safeCards, played: app.safePlayed.get)
  for symbol in app.selected:
    if app.symbolPlayed[symbol].isSome:
      result.counts.add Count(cards: app.deck[symbol], played: app.symbolPlayed[symbol].get)

# ---------------------------------------------------------------- rendering

proc renderChips(app: App) =
  var html = ""
  for symbol in Symbol:
    html.add "<button class='chip" & (if symbol in app.selected: " on" else: "") &
      "' data-symbol=" & $ord(symbol) & "><span class=g>" & Glyph[symbol] &
      "</span><b>" & $symbol & "</b><small>" & Letter[symbol] & " · " &
      $card(app.deck[symbol]) & "</small></button>"
  element("chips").innerHTML = html.cstring

proc renderSymbolInputs(app: App) =
  ## One "played with X" box per selected symbol, keeping typed values.
  var html = ""
  for symbol in app.selected:
    let known = app.symbolPlayed[symbol]
    html.add "<label>played with " & symbol.label & "<input id='played" & $symbol &
      "' type=number inputmode=numeric min=0 placeholder='?' value='" &
      (if known.isSome: $known.get else: "") & "'></label>"
  element("symbolPlayed").innerHTML = html.cstring

proc renderCount(app: App) =
  if app.selected == {}:
    element("countOut").innerHTML = "<p class=muted>Tap symbols above.</p>"
    return
  var html = "<div class=big>" & $card(app.deck.withAny(app.selected)) &
    "<span> / " & $DeckSize & " cards</span></div>" &
    "<p>have at least one of " & describe(app.selected) & ".</p>"
  let blanks = card(app.deck.blank)
  if blanks > 0:
    html.add "<p class=muted>+ " & plural(blanks, "blank card") & ", which " &
      blankRuleWords(app.blankRule) & ".</p>"
  if app.selected.card > 1:
    html.add "<p class=muted>" & $card(app.deck.withAll(app.selected)) &
      " have all of them.</p>"
  element("countOut").innerHTML = html.cstring

proc renderOdds(app: App) =
  let output = element("oddsOut")
  if app.selected == {}:
    output.innerHTML = "<p class=muted>Select symbols first.</p>"
    return
  if app.played > DeckSize:
    output.innerHTML = cstring("<p class=err>Only " & $DeckSize & " cards in the deck.</p>")
    return
  let odds = analyse(app.safeCards, app.observation)
  if not odds.possible:
    output.innerHTML = "<p class=err>That information is impossible with this deck — check the numbers.</p>"
    return
  if odds.remaining == 0:
    output.innerHTML = "<p class=muted>No cards left.</p>"
    return

  let draw = min(app.draw, odds.remaining)
  let cls = if app.headline == Safe: "ok" else: "bad"
  var html = "<div class='big " & cls & "'>" &
    percent(odds.chanceAtLeastOne(draw, app.headline)) & "</div>"
  if draw == 1:
    let blankNote =
      if app.blankRule == blankIsSafe and app.deck.blank != {}:
        (if app.headline == Safe: ", or blank" else: ", not blank")
      else: ""
    html.add "<p>chance the next card is " & outcomeWord(app.headline) &
      (if app.headline == Safe: " (has " else: " (none of ") &
      describe(app.selected) & blankNote & ").</p>"
  else:
    html.add "<p>chance at least one of the next " & $draw & " cards is " &
      outcomeWord(app.headline) & ".</p>"
  let safeLeft = odds.expectedSafeLeft
  html.add "<p class=muted>" & plural(odds.remaining, "card") & " left: about " &
    formatFloat(safeLeft, ffDecimal, 1) & " safe, " &
    formatFloat(float(odds.remaining) - safeLeft, ffDecimal, 1) & " danger.</p>"

  html.add "<table><tr><th>next</th><th>≥1 danger</th><th>≥1 safe</th></tr>"
  for n in 1 .. min(MaxDrawRows, odds.remaining):
    html.add "<tr" & (if n == draw: " class=hl" else: "") & "><td>" & $n &
      "</td><td class=bad>" & percent(odds.chanceAtLeastOne(n, Danger)) &
      "</td><td class=ok>" & percent(odds.chanceAtLeastOne(n, Safe)) & "</td></tr>"
  html.add "</table>"

  var possibleCounts = 0
  for chance in odds.safePlayedChance:
    if chance > 0: inc possibleCounts
  if possibleCounts > 1:
    html.add "<details><summary>Safe cards still in the deck</summary><table>"
    for safePlayed in countdown(odds.safePlayedChance.high, 0):
      let chance = odds.safePlayedChance[safePlayed]
      if chance > 0:
        html.add "<tr><td>" & $(odds.safeInDeck - safePlayed) & "</td><td>" &
          percent(chance) & "</td></tr>"
    html.add "</table></details>"
  output.innerHTML = html.cstring

proc renderMatrix(app: App) =
  var html = "<table class=mxt><tr><th></th>"
  for symbol in Symbol:
    html.add "<th title='" & $symbol & "'>" & Glyph[symbol] & "<br>" & Letter[symbol] & "</th>"
  html.add "</tr>"
  for index in AllCards:
    let symbols = app.deck.symbolsOn(index)
    html.add "<tr" & (if symbols == {}: " class=blank" else: "") & "><th>" &
      notebookLabel(index) & "</th>"
    for symbol in Symbol:
      html.add "<td data-card=" & $index & " data-symbol=" & $ord(symbol) &
        (if symbol in symbols: " class=on" else: "") & "></td>"
    html.add "</tr>"
  html.add "<tr class=tot><th>Σ</th>"
  for symbol in Symbol: html.add "<th>" & $card(app.deck[symbol]) & "</th>"
  html.add "</tr></table>"
  let matrix = element("matrix")
  matrix.innerHTML = html.cstring
  if app.editingMatrix: matrix.classList.add("unlocked")
  else: matrix.classList.remove("unlocked")

  element("lockBtn").innerHTML =
    if app.editingMatrix: "🔓 Done editing" else: "🔒 Locked — edit…"
  let edited = app.deck != NotebookDeck
  element("matrixNote").innerHTML =
    if edited: "<span class=err>Edited — differs from the notebook transcription.</span>"
    else: "Matches the notebook transcription."
  if edited: element("restoreBtn").removeAttribute("hidden")
  else: element("restoreBtn").setAttribute("hidden", "")

proc renderToggles(app: App) =
  highlightSegment("modeSeg", app.headline == Danger)
  highlightSegment("blankSeg", app.blankRule == blankIsSafe)
  highlightSegment("blankSeg2", app.blankRule == blankIsSafe)

proc renderResults(app: App) =
  app.renderCount()
  app.renderOdds()

proc renderAll(app: App) =
  app.renderChips()
  app.renderSymbolInputs()
  app.readInputs()
  app.renderResults()
  app.renderMatrix()
  app.renderToggles()

# ---------------------------------------------------------------- events

proc confirmed(message: cstring): bool {.importjs: "confirm(#)".}

proc wireEvents(app: App) =
  proc onNumbers(ev: Event) =
    app.readInputs()
    app.renderResults()

  proc onChip(ev: Event) =
    let index = closestWith(ev.target, ".chip").dataInt("symbol")
    if index < 0: return
    let symbol = Symbol(index)
    if symbol in app.selected: app.selected.excl symbol
    else: app.selected.incl symbol
    app.renderChips()
    app.renderSymbolInputs()   # rebuilt from app.observation, so typed values survive
    app.readInputs()
    app.renderResults()

  proc onStep(ev: Event) =
    let button = closestWith(ev.target, ".step")
    let input = element($button.getAttribute("data-t"))
    let current = try: parseInt(strip($input.value)) except ValueError: 0
    input.value = cstring($max(0, current + button.dataInt("d")))
    onNumbers(ev)

  proc onHeadline(ev: Event) =
    let choice = closestWith(ev.target, "button").dataInt("v")
    if choice < 0: return
    app.headline = if choice == 1: Danger else: Safe
    saveHeadline(app.headline)
    app.renderToggles()
    app.renderResults()

  proc onBlankRule(ev: Event) =
    let choice = closestWith(ev.target, "button").dataInt("v")
    if choice < 0: return
    app.blankRule = if choice == 1: blankIsSafe else: blankIsDanger
    saveBlankRule(app.blankRule)
    app.renderToggles()
    app.renderResults()

  proc onMatrixCell(ev: Event) =
    if not app.editingMatrix: return
    let cell = closestWith(ev.target, "td")
    let index = cell.dataInt("card")
    let symbolIndex = cell.dataInt("symbol")
    if index < 0 or symbolIndex < 0: return
    app.deck.toggle(CardIndex(index), Symbol(symbolIndex))
    saveDeck(app.deck)
    app.renderAll()

  proc onLock(ev: Event) =
    if app.editingMatrix: app.editingMatrix = false
    elif confirmed("Edit the card matrix? Tap cells to toggle symbols. Changes are saved on this device."):
      app.editingMatrix = true
    app.renderMatrix()

  proc onRestore(ev: Event) =
    if confirmed("Discard edits and restore the notebook transcription?"):
      app.deck = NotebookDeck
      app.editingMatrix = false
      saveDeck(app.deck)
      app.renderAll()

  proc onSettings(ev: Event) =
    let panel = element("settings")
    if panel.hasAttribute("hidden"):
      panel.removeAttribute("hidden")
      panel.scrollIntoView()
    else: panel.setAttribute("hidden", "")

  proc onReset(ev: Event) =
    ## Clears the current question; settings and matrix edits are kept.
    app.selected = {}
    app.played = 0
    app.safePlayed = none(Natural)
    app.symbolPlayed = default(array[Symbol, Option[Natural]])
    element("played").value = "0"
    element("safePlayed").value = ""
    element("draw").value = "1"
    app.renderAll()

  element("chips").addEventListener("click", onChip)
  for id in ["played", "safePlayed", "draw", "symbolPlayed"]:
    element(id).addEventListener("input", onNumbers)
  for button in document.querySelectorAll(".step"):
    button.addEventListener("click", onStep)
  element("modeSeg").addEventListener("click", onHeadline)
  element("blankSeg").addEventListener("click", onBlankRule)
  element("blankSeg2").addEventListener("click", onBlankRule)
  element("matrix").addEventListener("click", onMatrixCell)
  element("lockBtn").addEventListener("click", onLock)
  element("restoreBtn").addEventListener("click", onRestore)
  element("gear").addEventListener("click", onSettings)
  element("closeSettings").addEventListener("click", onSettings)
  element("clear").addEventListener("click", onReset)

proc main() =
  let app = App(
    deck: loadDeck(),
    draw: 1,
    blankRule: loadBlankRule(default = blankIsSafe),
    headline: loadHeadline(default = Danger))
  app.wireEvents()
  app.renderAll()

main()

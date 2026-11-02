## The page: reads the inputs, calls `odds`, renders the results.
## Compiled with `nim js` (see build.sh).

import std/[dom, strutils, options, htmlgen]
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
  if chance >= 0.9995 and chance < 1.0: return "&gt;99.9%"  # htmlgen does not escape text
  if chance > 0 and chance < 0.0005: return "&lt;0.1%"
  formatFloat(chance * 100, ffDecimal, 1) & "%"

proc readCount(id: string): Option[Natural] =
  ## A number box; empty or invalid means "unknown".
  try:
    let value = parseInt(strip($element(id).value))
    if value >= 0: result = some(Natural(value))
  except ValueError: discard

proc named(symbol: Symbol): string = Glyph[symbol] & " " & $symbol

proc describe(symbols: set[Symbol]): string =
  var parts: seq[string]
  for symbol in symbols: parts.add symbol.named
  parts.join(" or ")

proc plural(n: int, word: string): string =
  $n & " " & word & (if n == 1: "" else: "s")

proc outcomeWord(outcome: Outcome): string =
  if outcome == Safe: b(class = "ok", "safe") else: b(class = "bad", "danger")

proc blankRuleWords(rule: BlankRule): string =
  if rule == blankIsSafe: b(class = "ok", "matches all (safe)")
  else: b(class = "bad", "matches none (danger)")

proc classIf(condition: bool, name: string): string =
  if condition: name else: ""

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
  var chips = ""
  for symbol in Symbol:
    chips.add button(class = "chip " & classIf(symbol in app.selected, "on"),
      `data-symbol` = $ord(symbol),
      span(class = "g", Glyph[symbol]),
      b($symbol),
      small(Letter[symbol] & " · " & $card(app.deck[symbol])))
  element("chips").innerHTML = chips.cstring

proc renderSymbolInputs(app: App) =
  ## One "played with X" box per selected symbol, keeping typed values.
  var boxes = ""
  for symbol in app.selected:
    let known = app.symbolPlayed[symbol]
    boxes.add label("played with " & symbol.named,
      input(id = "played" & $symbol, `type` = "number", inputmode = "numeric",
            min = "0", placeholder = "?",
            value = (if known.isSome: $known.get else: "")))
  element("symbolPlayed").innerHTML = boxes.cstring

proc renderCount(app: App) =
  if app.selected == {}:
    element("countOut").innerHTML = p(class = "muted", "Tap symbols above.").cstring
    return
  var html =
    `div`(class = "big", $card(app.deck.withAny(app.selected)),
      span(" / " & $DeckSize & " cards")) &
    p("have at least one of " & describe(app.selected) & ".")
  let blanks = card(app.deck.blank)
  if blanks > 0:
    html.add p(class = "muted", "+ " & plural(blanks, "blank card") & ", which " &
      blankRuleWords(app.blankRule) & ".")
  if app.selected.card > 1:
    html.add p(class = "muted",
      $card(app.deck.withAll(app.selected)) & " have all of them.")
  element("countOut").innerHTML = html.cstring

proc oddsHtml(app: App): string =
  if app.selected == {}:
    return p(class = "muted", "Select symbols first.")
  if app.played > DeckSize:
    return p(class = "err", "Only " & $DeckSize & " cards in the deck.")
  let odds = analyse(app.safeCards, app.observation)
  if not odds.possible:
    return p(class = "err",
      "That information is impossible with this deck — check the numbers.")
  if odds.remaining == 0:
    return p(class = "muted", "No cards left.")

  let draw = min(app.draw, odds.remaining)
  result.add `div`(class = "big " & (if app.headline == Safe: "ok" else: "bad"),
    percent(odds.chanceAtLeastOne(draw, app.headline)))
  if draw == 1:
    let blankNote =
      if app.blankRule == blankIsSafe and app.deck.blank != {}:
        (if app.headline == Safe: ", or blank" else: ", not blank")
      else: ""
    result.add p("chance the next card is " & outcomeWord(app.headline) &
      (if app.headline == Safe: " (has " else: " (none of ") &
      describe(app.selected) & blankNote & ").")
  else:
    result.add p("chance at least one of the next " & $draw & " cards is " &
      outcomeWord(app.headline) & ".")
  let safeLeft = odds.expectedSafeLeft
  result.add p(class = "muted", plural(odds.remaining, "card") & " left: about " &
    formatFloat(safeLeft, ffDecimal, 1) & " safe, " &
    formatFloat(float(odds.remaining) - safeLeft, ffDecimal, 1) & " danger.")

  var rows = tr(th("next"), th("≥1 danger"), th("≥1 safe"))
  for n in 1 .. min(MaxDrawRows, odds.remaining):
    rows.add tr(class = classIf(n == draw, "hl"),
      td($n),
      td(class = "bad", percent(odds.chanceAtLeastOne(n, Danger))),
      td(class = "ok", percent(odds.chanceAtLeastOne(n, Safe))))
  result.add table(rows)

  var possibleCounts = 0
  for chance in odds.safePlayedChance:
    if chance > 0: inc possibleCounts
  if possibleCounts > 1:
    var spread = ""
    for safePlayed in countdown(odds.safePlayedChance.high, 0):
      let chance = odds.safePlayedChance[safePlayed]
      if chance > 0:
        spread.add tr(td($(odds.safeInDeck - safePlayed)), td(percent(chance)))
    result.add details(summary("Safe cards still in the deck"), table(spread))

proc renderOdds(app: App) =
  element("oddsOut").innerHTML = app.oddsHtml.cstring

proc renderMatrix(app: App) =
  var header = th("")
  for symbol in Symbol:
    header.add th(title = $symbol, Glyph[symbol], br(), $Letter[symbol])
  var rows = tr(header)
  let blank = app.deck.blank
  for index in CardIndex:
    var cells = th(notebookLabel(index))
    for symbol in Symbol:
      cells.add td(`data-card` = $index, `data-symbol` = $ord(symbol),
                   class = classIf(index in app.deck[symbol], "on"))
    rows.add tr(class = classIf(index in blank, "blank"), cells)
  var totals = th("Σ")
  for symbol in Symbol: totals.add th($card(app.deck[symbol]))
  rows.add tr(class = "tot", totals)

  let matrix = element("matrix")
  matrix.innerHTML = table(class = "mxt", rows).cstring
  if app.editingMatrix: matrix.classList.add("unlocked")
  else: matrix.classList.remove("unlocked")

  element("lockBtn").innerHTML =
    if app.editingMatrix: "🔓 Done editing" else: "🔒 Locked — edit…"
  let edited = app.deck != NotebookDeck
  element("matrixNote").innerHTML =
    if edited: span(class = "err",
      "Edited — differs from the notebook transcription.").cstring
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

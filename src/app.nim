## Symbol odds: card/symbol probability helper. Compiled with `nim js`.
import std/[dom, tables, strutils]

const
  NSym = 12
  Letters = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "K", "L", "M"]
  # ISS Vanguard biome for each notebook letter (confirmed by the owner).
  Names = ["Void", "Caves", "Volcanic", "Hostile", "Crystalline", "Deadly",
    "Vegetation", "Water", "Ruins", "Frigid", "Rocky", "Desert"]
  Glyphs = ["🌀", "🕳️", "🌋", "🎯", "💎", "☠️", "🌿", "💧", "🏛️", "❄️", "🪨", "🏜️"]
  # One string per card, transcribed from the notebook grid (39 rows).
  # The 40th card has no symbols; extra blank cards come from DefaultDeck - len.
  CardRows = ["A", "B", "CD", "E", "AFGH", "BCFGI", "DG", "D", "GI", "AFH",
    "G", "D", "I", "AE", "AH", "C", "AFK", "H", "BCGIKL", "BCIL", "FGKLM",
    "BIKL", "AHL", "BHL", "BCEGL", "BCFIKM", "GLM",
    "BCFIKM", "DGHLM", "FHM", "BIL", "CM", "BIKM", "CFL", "AFHIKM", "BIM",
    "BIL", "CFM", "EGHKLM"]
  DefaultDeck = 40

type Mask = int

proc symIndex(c: char): int =
  for i, l in Letters:
    if l[0] == c: return i
  -1

proc parseCards(): seq[Mask] =
  for row in CardRows:
    var m = 0
    for c in row: m = m or (1 shl symIndex(c))
    result.add m

var cards = parseCards()   # may be replaced by an edited copy from storage
let defaultCards = parseCards()

proc popcount(m: Mask): int =
  var x = m
  while x != 0:
    x = x and (x - 1)
    inc result

proc choose(n, k: int): float =
  if k < 0 or n < 0 or k > n: return 0.0
  var kk = min(k, n - k)
  result = 1.0
  for i in 1 .. kk:
    result = result * float(n - kk + i) / float(i)

# ---------------------------------------------------------------- state
var
  sel: Mask = 0
  deckSize = DefaultDeck
  played = 0
  anyObs = -1                 # -1 = unknown
  symObs: array[NSym, int]
  drawMax = 8
  blankSafe = true            # blank card counts as a match (safe)
  showDanger = true           # headline shows danger (no-match) odds
  unlocked = false            # matrix editing
for i in 0 ..< NSym: symObs[i] = -1

const BlankBit = 1 shl NSym   # pseudo-pattern for blank cards (no symbols)

proc blanks(): int =
  ## Cards with no symbols: missing rows up to the deck size, plus empty rows.
  result = max(0, deckSize - cards.len)
  for c in cards:
    if c == 0: inc result

proc symCount(i: int): int =
  for c in cards:
    if (c and (1 shl i)) != 0: inc result

proc symMatchCount(t: Mask): int =
  for c in cards:
    if (c and t) != 0: inc result

proc matchCount(t: Mask): int =
  ## Cards that count as a match (safe): any selected symbol, plus blanks if set.
  symMatchCount(t) + (if blankSafe: blanks() else: 0)

proc allCount(t: Mask): int =
  if t == 0: return 0
  for c in cards:
    if (c and t) == t: inc result

# ---------------------------------------------------------------- odds
type Posterior = object
  ok: bool
  weights: seq[float]   # index u = played cards matching the target set
  total: float

proc posterior(t: Mask): Posterior =
  ## Played cards are a uniformly random subset of size `played`,
  ## conditioned on the observed counts. Group cards by pattern (card ∩ t)
  ## and run a DP over (matching played, per-constrained-symbol counts).
  var cons: seq[int]
  for i in 0 ..< NSym:
    if (t and (1 shl i)) != 0 and symObs[i] >= 0: cons.add i
  var groups = initTable[Mask, int]()
  var n0 = 0                  # cards that do not match
  for c in cards:
    let p = c and t
    if c == 0: discard        # blank, handled below
    elif p == 0: inc n0
    else: groups[p] = groups.getOrDefault(p, 0) + 1
  let nb = max(0, deckSize - cards.len) + (block:
    var z = 0
    for c in cards:
      if c == 0: inc z
    z)
  if blankSafe and nb > 0: groups[BlankBit] = nb
  else: n0 += nb
  const B = 41
  proc enc(u: int, cs: seq[int]): int =
    result = u
    var mul = B
    for c in cs:
      result += c * mul
      mul *= B
  proc dec(k: int, q: int): (int, seq[int]) =
    var x = k
    result[0] = x mod B
    x = x div B
    for i in 0 ..< q:
      result[1].add x mod B
      x = x div B
  var dp = initTable[int, float]()
  dp[enc(0, newSeq[int](cons.len))] = 1.0
  for pat, n in groups:
    var nd = initTable[int, float]()
    for key, w in dp:
      let (u, cs) = dec(key, cons.len)
      for m in 0 .. min(n, played - u):
        var ncs = cs
        var bad = false
        for j, s in cons:
          if (pat and (1 shl s)) != 0:
            ncs[j] += m
            if ncs[j] > symObs[s]: bad = true
        if bad: break
        if anyObs >= 0 and u + m > anyObs: break
        let k2 = enc(u + m, ncs)
        nd[k2] = nd.getOrDefault(k2, 0.0) + w * choose(n, m)
    dp = nd
  result.weights = newSeq[float](played + 1)
  for key, w in dp:
    let (u, cs) = dec(key, cons.len)
    var good = true
    for j, s in cons:
      if cs[j] != symObs[s]: good = false
    if anyObs >= 0 and u != anyObs: good = false
    if good:
      let ww = w * choose(n0, played - u)
      result.weights[u] += ww
      result.total += ww
  result.ok = result.total > 0

proc hitProb(post: Posterior, g: int, s: int, danger: bool): float =
  ## P(at least one of the next s cards is safe (matches), or, with
  ## `danger`, at least one is a non-match).
  let r = deckSize - played
  for u, w in post.weights:
    if w == 0: continue
    let safeLeft = g - u
    let other = if danger: safeLeft else: r - safeLeft
    if s > r: result += w * (if r - other > 0: 1.0 else: 0.0)
    else: result += w * (1.0 - choose(other, s) / choose(r, s))
  result /= post.total

# ---------------------------------------------------------------- DOM
proc el(id: string): Element = document.getElementById(id.cstring)

proc pct(x: float): string =
  if x >= 0.9995 and x < 1.0: return ">99.9%"
  if x > 0 and x < 0.0005: return "<0.1%"
  formatFloat(x * 100, ffDecimal, 1) & "%"

proc readInt(id: string, def: int): int =
  let v = strip($el(id).value)
  if v.len == 0: return def
  try: parseInt(v) except ValueError: def

proc selNames(t: Mask): string =
  var parts: seq[string]
  for i in 0 ..< NSym:
    if (t and (1 shl i)) != 0: parts.add Glyphs[i] & " " & Names[i]
  parts.join(" or ")

proc renderResults() =
  let nSel = popcount(sel)
  let nb = blanks()
  # --- count section
  var h = ""
  if nSel == 0:
    h = "<p class=muted>Tap symbols above.</p>"
  else:
    let any = symMatchCount(sel)
    h.add "<div class=big>" & $any & "<span> / " & $deckSize & " cards</span></div>"
    h.add "<p>have at least one of " & selNames(sel) & ".</p>"
    if nb > 0:
      h.add "<p class=muted>+ " & $nb & " blank card" & (if nb == 1: "" else: "s") &
        ", counted as " & (if blankSafe: "<b class=ok>safe</b>" else: "<b class=bad>danger</b>") &
        " (settings).</p>"
    if nSel > 1:
      h.add "<p class=muted>" & $allCount(sel) & " have all of them.</p>"
  el("countOut").innerHTML = h.cstring

  # --- odds section
  var o = ""
  if nSel == 0:
    o = "<p class=muted>Select symbols first.</p>"
  elif played > deckSize:
    o = "<p class=err>Played exceeds deck size.</p>"
  else:
    let post = posterior(sel)
    if not post.ok:
      o = "<p class=err>That information is impossible with this deck — check the numbers.</p>"
    else:
      let g = matchCount(sel)
      var expLeft = 0.0
      for u, w in post.weights: expLeft += w * float(g - u)
      expLeft /= post.total
      let r = deckSize - played
      let s1 = max(1, readInt("draw", 1))
      let cls = if showDanger: "bad" else: "ok"
      o.add "<div class='big " & cls & "'>" & pct(hitProb(post, g, s1, showDanger)) & "</div>"
      if s1 == 1:
        o.add "<p>chance the next card is " & (if showDanger:
          "<b class=bad>danger</b> (none of " else: "<b class=ok>safe</b> (has ") &
          selNames(sel) & (if blankSafe and nb > 0: (if showDanger: ", not blank" else: ", or blank") else: "") &
          ").</p>"
      else:
        o.add "<p>chance at least one of the next " & $s1 & " cards is " &
          (if showDanger: "<b class=bad>danger</b>" else: "<b class=ok>safe</b>") & ".</p>"
      o.add "<p class=muted>" & $r & " cards left: about " &
        formatFloat(expLeft, ffDecimal, 1) & " safe, " &
        formatFloat(float(r) - expLeft, ffDecimal, 1) & " danger.</p>"
      o.add "<table><tr><th>next</th><th>≥1 danger</th><th>≥1 safe</th></tr>"
      for s in 1 .. min(drawMax, r):
        o.add "<tr" & (if s == s1: " class=hl" else: "") & "><td>" & $s &
          "</td><td class=bad>" & pct(hitProb(post, g, s, true)) &
          "</td><td class=ok>" & pct(hitProb(post, g, s, false)) & "</td></tr>"
      o.add "</table>"
      var nz = 0
      for w in post.weights:
        if w > 0: inc nz
      if nz > 1:
        o.add "<details><summary>Safe cards still in the deck</summary><table>"
        for u in countdown(post.weights.high, 0):
          let w = post.weights[u]
          if w > 0:
            o.add "<tr><td>" & $(g - u) & "</td><td>" & pct(w / post.total) & "</td></tr>"
        o.add "</table></details>"
  el("oddsOut").innerHTML = o.cstring

proc readInputs() =
  deckSize = max(cards.len, readInt("deck", DefaultDeck))
  el("blankNote").innerHTML = cstring($(cards.len - (blanks() - max(0, deckSize - cards.len))) &
    " cards with symbols + " & $blanks() & " blank")
  played = max(0, readInt("played", 0))
  anyObs = readInt("anyObs", -1)
  for i in 0 ..< NSym:
    if (sel and (1 shl i)) != 0:
      symObs[i] = readInt("obs" & $i, -1)

proc onInput(ev: Event) =
  readInputs()
  renderResults()

proc renderObsInputs() =
  var h = ""
  for i in 0 ..< NSym:
    if (sel and (1 shl i)) != 0:
      let v = if symObs[i] >= 0: $symObs[i] else: ""
      h.add "<label>played with " & Glyphs[i] & " " & Names[i] &
        "<input id=obs" & $i & " type=number inputmode=numeric min=0 placeholder='?' value='" &
        v & "'></label>"
  el("symObs").innerHTML = h.cstring
  for i in 0 ..< NSym:
    if (sel and (1 shl i)) != 0:
      el("obs" & $i).addEventListener("input", onInput)

proc renderChips()

proc onChip(ev: Event) =
  let i = parseInt($ev.currentTarget.getAttribute("data-i"))
  sel = sel xor (1 shl i)
  renderChips()
  renderObsInputs()
  readInputs()
  renderResults()

proc renderChips() =
  var h = ""
  for i in 0 ..< NSym:
    let on = (sel and (1 shl i)) != 0
    h.add "<button class='chip" & (if on: " on" else: "") & "' data-i=" & $i &
      "><span class=g>" & Glyphs[i] & "</span><b>" & Names[i] & "</b><small>" & Letters[i] & " · " &
      $symCount(i) & "</small></button>"
  el("chips").innerHTML = h.cstring
  for b in document.querySelectorAll(".chip"):
    b.addEventListener("click", onChip)

proc onStep(ev: Event) =
  let t = ev.currentTarget
  let target = el($t.getAttribute("data-t"))
  let d = parseInt($t.getAttribute("data-d"))
  let cur = strip($target.value)
  var v = (if cur.len == 0: 0 else: (try: parseInt(cur) except ValueError: 0)) + d
  if v < 0: v = 0
  target.value = cstring($v)
  readInputs()
  renderResults()

proc onClear(ev: Event) =
  sel = 0
  played = 0
  anyObs = -1
  for i in 0 ..< NSym: symObs[i] = -1
  el("played").value = "0"
  el("anyObs").value = ""
  el("draw").value = "1"
  renderChips()
  renderObsInputs()
  renderResults()

# ---------------------------------------------------------------- storage
proc lsGet(k: cstring): cstring {.importjs:
  "(function(k){try{return localStorage.getItem(k)||''}catch(e){return ''}})(#)".}
proc lsSet(k, v: cstring) {.importjs:
  "(function(k,v){try{localStorage.setItem(k,v)}catch(e){}})(#,#)".}
proc lsDel(k: cstring) {.importjs:
  "(function(k){try{localStorage.removeItem(k)}catch(e){}})(#)".}
proc jsConfirm(msg: cstring): bool {.importjs: "confirm(#)".}

proc encodeCards(cs: seq[Mask]): string =
  var parts: seq[string]
  for c in cs:
    var r = ""
    for i in 0 ..< NSym:
      if (c and (1 shl i)) != 0: r.add Letters[i]
    parts.add r
  parts.join(",")

proc decodeCards(s: string): seq[Mask] =
  for row in s.split(','):
    var m = 0
    for c in row:
      let i = symIndex(c)
      if i >= 0: m = m or (1 shl i)
    result.add m

proc saveSettings() =
  lsSet("vo.blankSafe", cstring(if blankSafe: "1" else: "0"))
  lsSet("vo.danger", cstring(if showDanger: "1" else: "0"))
  lsSet("vo.deck", cstring($deckSize))
  if cards == defaultCards: lsDel("vo.cards")
  else: lsSet("vo.cards", cstring(encodeCards(cards)))

proc loadSettings() =
  let b = $lsGet("vo.blankSafe")
  if b.len > 0: blankSafe = b == "1"
  let d = $lsGet("vo.danger")
  if d.len > 0: showDanger = d == "1"
  let n = $lsGet("vo.deck")
  if n.len > 0:
    try: deckSize = parseInt(n) except ValueError: discard
  let c = $lsGet("vo.cards")
  if c.len > 0:
    let dc = decodeCards(c)
    if dc.len > 0: cards = dc

# ---------------------------------------------------------------- settings UI
proc setSeg(id: string, first: bool) =
  let kids = el(id).querySelectorAll("button")
  for k, b in kids:
    if (k == 0) == first: b.classList.add("on") else: b.classList.remove("on")

proc renderMatrix() =
  var h = "<table class=mxt><tr><th></th>"
  for i in 0 ..< NSym:
    h.add "<th title='" & Names[i] & "'>" & Glyphs[i] & "<br>" & Letters[i] & "</th>"
  h.add "</tr>"
  for r, c in cards:
    # Notebook position: page 1 has the first 27 rows, page 2 the rest.
    let lbl = if r < 27: "1·" & $(r + 1) else: "2·" & $(r - 26)
    h.add "<tr><th>" & lbl & "</th>"
    for i in 0 ..< NSym:
      let on = (c and (1 shl i)) != 0
      h.add "<td data-c='" & $r & "," & $i & "'" & (if on: " class=on" else: "") & "></td>"
    h.add "</tr>"
  let extra = max(0, deckSize - cards.len)
  for k in 0 ..< extra:
    h.add "<tr class=blank><th>blank</th><td colspan=12></td></tr>"
  h.add "<tr class=tot><th>Σ</th>"
  for i in 0 ..< NSym: h.add "<th>" & $symCount(i) & "</th>"
  h.add "</tr></table>"
  el("matrix").innerHTML = h.cstring
  let mx = el("matrix")
  if unlocked: mx.classList.add("unlocked") else: mx.classList.remove("unlocked")
  el("lockBtn").innerHTML = (if unlocked: "🔓 Done editing" else: "🔒 Locked — edit…")
  var note = ""
  if cards != defaultCards:
    note = "<span class=err>Edited — differs from the notebook transcription.</span>"
  else:
    note = "Matches the notebook transcription."
  el("mxNote").innerHTML = note.cstring
  if cards != defaultCards: el("restoreBtn").removeAttribute("hidden")
  else: el("restoreBtn").setAttribute("hidden", "")

proc refreshAll() =
  renderChips()
  renderObsInputs()
  readInputs()
  renderResults()
  renderMatrix()

proc onMatrix(ev: Event) =
  if not unlocked: return
  let t = cast[Element](ev.target)
  let a = $t.getAttribute("data-c")
  if a.len == 0 or a == "null": return
  let parts = a.split(',')
  let r = parseInt(parts[0])
  let i = parseInt(parts[1])
  cards[r] = cards[r] xor (1 shl i)
  saveSettings()
  refreshAll()

proc onLock(ev: Event) =
  if unlocked: unlocked = false
  elif jsConfirm("Edit the card matrix? Tap cells to toggle symbols. Changes are saved on this device."):
    unlocked = true
  renderMatrix()

proc onRestore(ev: Event) =
  if jsConfirm("Discard edits and restore the notebook transcription?"):
    cards = defaultCards
    unlocked = false
    saveSettings()
    refreshAll()

proc onSettingsToggle(ev: Event) =
  let s = el("settings")
  if s.hasAttribute("hidden"):
    s.removeAttribute("hidden")
    s.scrollIntoView()
  else: s.setAttribute("hidden", "")

proc onBlankSeg(ev: Event) =
  blankSafe = $ev.currentTarget.getAttribute("data-v") == "1"
  setSeg("blankSeg", blankSafe)
  saveSettings()
  readInputs()
  renderResults()

proc onModeSeg(ev: Event) =
  showDanger = $ev.currentTarget.getAttribute("data-v") == "1"
  setSeg("modeSeg", showDanger)
  saveSettings()
  renderResults()

proc onDeck(ev: Event) =
  readInputs()
  saveSettings()
  renderResults()
  renderMatrix()

proc main() =
  loadSettings()
  el("deck").value = cstring($deckSize)
  setSeg("blankSeg", blankSafe)
  setSeg("modeSeg", showDanger)
  for b in el("blankSeg").querySelectorAll("button"): b.addEventListener("click", onBlankSeg)
  for b in el("modeSeg").querySelectorAll("button"): b.addEventListener("click", onModeSeg)
  el("gear").addEventListener("click", onSettingsToggle)
  el("closeSettings").addEventListener("click", onSettingsToggle)
  el("matrix").addEventListener("click", onMatrix)
  el("lockBtn").addEventListener("click", onLock)
  el("restoreBtn").addEventListener("click", onRestore)
  el("deck").addEventListener("input", onDeck)
  for id in ["played", "anyObs", "draw"]:
    el(id).addEventListener("input", onInput)
  for b in document.querySelectorAll(".step"):
    b.addEventListener("click", onStep)
  el("clear").addEventListener("click", onClear)
  refreshAll()

main()

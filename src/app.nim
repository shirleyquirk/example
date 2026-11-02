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

let cards = parseCards()

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
for i in 0 ..< NSym: symObs[i] = -1

proc blanks(): int = max(0, deckSize - cards.len)

proc symCount(i: int): int =
  for c in cards:
    if (c and (1 shl i)) != 0: inc result

proc matchCount(t: Mask): int =
  for c in cards:
    if (c and t) != 0: inc result

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
  var n0 = blanks()
  for c in cards:
    let p = c and t
    if p == 0: inc n0
    else: groups[p] = groups.getOrDefault(p, 0) + 1
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

proc hitProb(post: Posterior, g: int, s: int): float =
  ## P(at least one of the next s cards is in the target set).
  let r = deckSize - played
  if s > r: return 1.0
  for u, w in post.weights:
    if w == 0: continue
    let left = g - u
    result += w * (1.0 - choose(r - left, s) / choose(r, s))
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
  # --- count section
  var h = ""
  if nSel == 0:
    h = "<p class=muted>Tap symbols above.</p>"
  else:
    let any = matchCount(sel)
    h.add "<div class=big>" & $any & "<span> / " & $deckSize & " cards</span></div>"
    h.add "<p>have at least one of " & selNames(sel) & ".</p>"
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
      o.add "<div class=big>" & pct(hitProb(post, g, s1)) & "</div>"
      o.add "<p>chance the next " & $s1 & " card" & (if s1 == 1: "" else: "s") &
        " include at least one " & selNames(sel) & ".</p>"
      o.add "<p class=muted>" & $r & " cards left; about " &
        formatFloat(expLeft, ffDecimal, 1) & " of them match.</p>"
      o.add "<table><tr><th>next</th><th>P(≥1 match)</th></tr>"
      for s in 1 .. min(drawMax, r):
        o.add "<tr" & (if s == s1: " class=hl" else: "") & "><td>" & $s &
          "</td><td>" & pct(hitProb(post, g, s)) & "</td></tr>"
      o.add "</table>"
      var nz = 0
      for w in post.weights:
        if w > 0: inc nz
      if nz > 1:
        o.add "<details><summary>Matching cards still in the deck</summary><table>"
        for u in countdown(post.weights.high, 0):
          let w = post.weights[u]
          if w > 0:
            o.add "<tr><td>" & $(g - u) & "</td><td>" & pct(w / post.total) & "</td></tr>"
        o.add "</table></details>"
  el("oddsOut").innerHTML = o.cstring

proc readInputs() =
  deckSize = max(cards.len, readInt("deck", DefaultDeck))
  el("blankNote").innerHTML = cstring($cards.len & " cards with symbols + " &
    $blanks() & " blank (from your notebook grid)")
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

proc main() =
  el("deck").value = cstring($DefaultDeck)
  renderChips()
  renderObsInputs()
  for id in ["deck", "played", "anyObs", "draw"]:
    el(id).addEventListener("input", onInput)
  for b in document.querySelectorAll(".step"):
    b.addEventListener("click", onStep)
  el("clear").addEventListener("click", onClear)
  readInputs()
  renderResults()

main()

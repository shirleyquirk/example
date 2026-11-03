## The plates' optics must agree with the app: for any stack, the lit
## positions are exactly the danger cards.
import std/[unittest, math]
import ../src/[model, odds]
import ../hardware/[plates, simgen, receptacle]


proc dot2(a, b: Point): float = a.x * b.x + a.y * b.y

proc outsideBy(p: Point): float =
  ## Signed distance from the token outline: positive outside, negative inside.
  ## Works for the non-convex outline (the key step).
  let poly = outline()
  var best = Inf
  var inside = false
  for i in 0 ..< poly.len:
    let (a, b) = (poly[i], poly[(i + 1) mod poly.len])
    let (dx, dy) = (b.x - a.x, b.y - a.y)
    let t = clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy), 0.0, 1.0)
    best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
    if (a.y > p.y) != (b.y > p.y) and p.x < a.x + (p.y - a.y) * dx / dy:
      inside = not inside
  if inside: -best else: best

suite "plates":
  test "every combination of symbols, both blank rules (8190 stacks)":
    for mask in 1 ..< (1 shl 12):
      var symbols: set[Symbol]
      var stack: seq[Plate]
      for symbol in Symbol:
        if (mask shr ord(symbol) and 1) == 1:
          symbols.incl symbol
          stack.add plateFor(symbol)
      check litPositions(stack) == AllCards - NotebookDeck.safe(symbols, blankIsDanger)
      stack.add blankSafePlate()
      check litPositions(stack) == AllCards - NotebookDeck.safe(symbols, blankIsSafe)
  test "every slot has the same area":
    proc area(c: array[4, Point]): float =
      for i in 0 .. 3:
        let j = (i + 1) mod 4
        result += c[i].x * c[j].y - c[j].x * c[i].y
      abs(result) / 2
    for index in CardIndex:
      check abs(area(slotCorners(index)) - SlotLength * SlotWidth) < 1e-9
  test "slots stay inside the token and clear the icon":
    for index in CardIndex:
      for p in slotCorners(index):
        check sqrt(p.x * p.x + p.y * p.y) > IconSize / sqrt(2.0)   # outside the icon's square
        check outsideBy(p) < -1.0                                   # at least 1 mm of material

suite "stand":
  test "every strip stays outside the token by the clearance":
    for s in strips():
      for p in s.footprint(0, s.gapEnd, 0, Ply):
        check outsideBy(p) >= GuideClearance - 1e-9
  test "the key strip is set in by one wall thickness":
    var keyed = 0
    for s in strips():
      if s.keyed:
        inc keyed
        check abs(dot2(s.origin, s.m) - (InnerApothem - Wall)) < 1e-9
    check keyed == 1
  test "fingers interlock: each strip's fingers reach past the other's gaps":
    for (a, b) in corners():
      check a.fingerEnd > a.gapEnd and b.fingerEnd > b.gapEnd
      check a.ownsEven != b.ownsEven
  test "a flipped token doesn't fit":
    # Turn the token over and try every rotation by 45°: some corner of it
    # must land inside a strip.
    for turn in 0 .. 7:
      let a = float(turn) * PI / 4
      var hits = false
      for q in outline():
        let p: Point = (-q.x, q.y)
        let r: Point = (p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a))
        for s in strips():
          let d: Point = (r.x - s.origin.x, r.y - s.origin.y)
          let along = dot2(d, s.u)
          let outward = dot2(d, s.m)
          if along > 0 and along < s.gapEnd and outward > -GuideClearance and outward < Ply:
            hits = true
      check hits

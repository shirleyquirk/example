## The plates' optics must agree with the app: for any stack, the lit
## positions are exactly the danger cards.
import std/[unittest, math]
import ../src/[model, odds]
import ../hardware/[plates, simgen, receptacle]

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
  test "keyed corner has no mirror image":
    # An evenly clipped corner would be symmetric about the corner's own
    # mirror axis, so a flipped token would still fit.
    check ChamferLong != ChamferShort and ChamferLong > 0 and ChamferShort > 0
  test "every slot has the same area":
    proc area(c: array[4, Point]): float =
      for i in 0 .. 3:
        let j = (i + 1) mod 4
        result += c[i].x * c[j].y - c[j].x * c[i].y
      abs(result) / 2
    for index in CardIndex:
      check abs(area(slotCorners(index)) - SlotLength * SlotWidth) < 1e-9
  test "slots stay inside the token and clear the icon":
    let edges = outline()
    for index in CardIndex:
      for p in slotCorners(index):
        check sqrt(p.x * p.x + p.y * p.y) > IconSize / sqrt(2.0)   # outside the icon's square
        for i in 0 ..< edges.len:
          # distance inward from each outline edge (outline is convex, clockwise)
          let (a, b) = (edges[i], edges[(i + 1) mod edges.len])
          let (dx, dy) = (b.x - a.x, b.y - a.y)
          let inward = ((p.x - a.x) * dy - (p.y - a.y) * dx) / sqrt(dx * dx + dy * dy)
          check inward < -1.0 or inward > 1.0
          check inward < 0          # inside

suite "stand":
  proc outsideBy(p: Point): float =
    ## How far p is outside the token outline (negative = inside).
    let edges = outline()
    result = -Inf
    for i in 0 ..< edges.len:
      let (a, b) = (edges[i], edges[(i + 1) mod edges.len])
      let (dx, dy) = (b.x - a.x, b.y - a.y)
      result = max(result, ((p.x - a.x) * dy - (p.y - a.y) * dx) / sqrt(dx * dx + dy * dy))
  test "every guide strip stays outside the token by the clearance":
    for g in guides():
      for p in g.footprint(0, g.width, 0, Ply):
        check outsideBy(p) >= Clearance - 1e-9
  test "the key strip touches the clipped corner":
    # its inner face is exactly Clearance from the clipped edge
    let key = guides()[^1]
    let mid = key.origin + (key.width / 2) * key.u
    check abs(outsideBy(mid) - Clearance) < 1e-9
  test "a flipped token doesn't fit":
    # Mirror the token about its vertical axis (turning it over) and try every
    # rotation by 45°: some corner of it must cut into a guide strip.
    for turn in 0 .. 7:
      let a = float(turn) * PI / 4
      var hits = false
      for q in outline():
        let p: Point = (-q.x, q.y)                         # turned over
        let r: Point = (p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a))
        for g in guides():
          # inside the strip's footprint?
          let d = (x: r.x - g.origin.x, y: r.y - g.origin.y)
          let along = d.x * g.u.x + d.y * g.u.y
          let outward = d.x * g.m.x + d.y * g.m.y
          if along > 0 and along < g.width and outward > -Clearance and outward < Ply:
            hits = true
      check hits

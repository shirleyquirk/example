## The plywood stand the tokens stack in (`nim cup`), tab-and-slot, from the
## token geometry in plates.nim. Everything is Wall (3 mm) plywood.
##
##   lid        plate resting on the strip tops; LED board underneath (40 LEDs
##              over the 40 slots), batteries on top
##   corners    four corner pieces at alternate corners of the octagon. Each is
##              two strips, one along each side, meeting at the corner and
##              finger-jointed together. The four open corners between them
##              are finger access. At the keyed corner the strip on side KeySide
##              is set in by one wall thickness; the tokens have a matching
##              step there, so only the right-way-up token fits.
##   floor      plate with the 40 slots (the baffle) and slots the strips pass
##              through; it rests on a shoulder at each strip's far end
##   (gap)      the sensor board sits here on spacers, 40 sensors facing up
##   base       plate with slots for the strips' bottom tabs
##
## Finger joints at an octagon corner meet at 135°, so the two strips' slabs
## overlap in a slanted parallelogram (plan view). Each strip's fingers reach
## the far side of that overlap and its gaps stop at the near side, so they
## always interlock; the finger tips stand a little proud on the outside of the
## corner, as usual for angled laser-cut finger joints.

import std/[math, strformat]
import plates

const
  Ply* = Wall
  Fit* = 0.1                  ## slot clearance for plywood tabs, per side
  BoardGap* = 6.0             ## base top to floor bottom: sensor board + parts
  PocketTokens* = 6
  PocketHeight* = float(PocketTokens) * Ply
  Shoulder* = 2.0             ## below the floor, strips are this much longer at the far end
  PlateApothem* = 50.0        ## base, floor and lid
  Fingers* = 5                ## finger joint segments over the strip height (odd)
  BottomTab = (2.0, 8.0)      ## along the strip from its far end
  TopTab = (2.5, 7.5)

  InnerApothem* = Apothem + GuideClearance    ## strips' inner faces
  StripTop* = BoardGap + Ply + PocketHeight   ## from the base's top face
  CornerSides* = [0, 2, 4, 6]                 ## corner pieces at the corners after these sides

static: doAssert KeySide in CornerSides

type
  Strip* = object
    ## One strip of a corner piece, in plan view: it starts at `origin` (its
    ## far end, away from the corner) and runs along `u` towards the corner.
    ## Its inner face is on the line through `origin`; it is Ply thick along
    ## the outward direction `m`.
    origin*, u*, m*: Point
    gapEnd*, fingerEnd*: float   ## lengths at its gaps and at its fingers
    ownsEven*: bool              ## fingers on segments 0, 2, 4…  (else 1, 3…)
    keyed*: bool

  Corner* = tuple[first, second: Strip]

proc dot(a, b: Point): float = a.x * b.x + a.y * b.y
proc sub(a, b: Point): Point = (a.x - b.x, a.y - b.y)

proc corners*(): seq[Corner] =
  for c in CornerSides:
    let (a, b) = (c, c + 1)                     # sides either side of the corner
    let keyed = c == KeySide
    let ra = InnerApothem - (if keyed: Ply else: 0.0)
    let rb = InnerApothem
    let start = SideLength / 2 - GuideReach     # far end, along each side from its centre
    var sa = Strip(origin: ra * normal(a) + start * tangent(a), u: tangent(a),
                   m: normal(a), ownsEven: true, keyed: keyed)
    var sb = Strip(origin: rb * normal(b) + (-start) * tangent(b),
                   u: (-1.0) * tangent(b), m: normal(b), ownsEven: false)
    # The overlap of the two slabs: corners where their faces cross.
    var overlap: seq[Point]
    for da in [0.0, Ply]:
      for db in [0.0, Ply]:
        overlap.add meet(normal(a), ra + da, normal(b), rb + db)
    for s in [addr sa, addr sb]:
      var lo = Inf
      var hi = -Inf
      for p in overlap:
        let x = dot(sub(p, s.origin), s.u)
        lo = min(lo, x)
        hi = max(hi, x)
      s.gapEnd = lo
      s.fingerEnd = hi
    result.add (sa, sb)

proc strips*(): seq[Strip] =
  for (a, b) in corners(): result.add [a, b]

proc footprint*(s: Strip, x0, x1, out0, out1: float): seq[Point] =
  @[s.origin + x0 * s.u + out0 * s.m, s.origin + x0 * s.u + out1 * s.m,
    s.origin + x1 * s.u + out1 * s.m, s.origin + x1 * s.u + out0 * s.m]

proc plateSlots(cx, cy: float, tab: (float, float)): string =
  ## Slots in the base or lid for each strip's tab.
  for s in strips():
    result.add polygon(s.footprint(tab[0] - Fit, tab[1] + Fit, -Fit, Ply + Fit), cx, cy)

proc floorSlots(cx, cy: float): string =
  ## The strips pass right through the floor, joint and all.
  for s in strips():
    result.add polygon(s.footprint(-Fit, s.fingerEnd + Fit, -Fit, Ply + Fit), cx, cy)

proc stripProfile*(s: Strip, cx, cy: float): string =
  ## The strip cut out flat: x along it from its far end, y up from the
  ## base's top face. Bottom tab into the base, shoulder carrying the floor at
  ## the far end, finger joint at the corner end, top tab into the lid.
  let h = StripTop / float(Fingers)
  var p: seq[(float, float)]
  p.add [(BottomTab[0], -Ply), (BottomTab[1], -Ply), (BottomTab[1], 0.0)]
  # corner end, bottom to top
  for j in 0 ..< Fingers:
    let mine = (j mod 2 == 0) == s.ownsEven
    let x = if mine: s.fingerEnd else: s.gapEnd
    p.add [(x, float(j) * h), (x, float(j + 1) * h)]
  p.add [(TopTab[1], StripTop), (TopTab[1], StripTop + Ply), (TopTab[0], StripTop + Ply),
         (TopTab[0], StripTop), (0.0, StripTop), (0.0, BoardGap),
         (-Shoulder, BoardGap), (-Shoulder, 0.0), (BottomTab[0], 0.0)]
  var pts: seq[Point]
  let w = s.fingerEnd
  for (x, y) in p: pts.add (cx - w / 2 + x, cy + StripTop / 2 - y)
  polygon(pts, 0, 0)

type PartKind* = enum
  base, floor, stripA, stripB, keyStripA, keyStripB, lid, sensorBoard, ledBoard

proc name*(part: PartKind): string =
  ["base", "floor", "strip-a", "strip-b", "key-strip-a", "key-strip-b", "lid",
   "sensor-board", "led-board"][ord(part)]

proc title*(part: PartKind): string =
  case part
  of base: "Base (slots for the strips' bottom tabs)"
  of floor: "Floor = baffle (40 slots + strip slots)"
  of stripA: "Corner strip A (first side of a corner; fingers at bottom and top)"
  of stripB: "Corner strip B (second side; fingers in between)"
  of keyStripA: "Key corner strip A (set in one wall thickness)"
  of keyStripB: "Key corner strip B"
  of lid: "Lid (rests on the strip tops; LED board underneath)"
  of sensorBoard: "Sensor board outline (for KiCad); blue = sensor positions"
  of ledBoard: "LED board outline (faces down; blue = LED positions, mirrored)"

proc count*(part: PartKind): int =
  case part
  of stripA, stripB: CornerSides.len - 1
  else: 1

proc sensorMarks(cx, cy: float, mirrored: bool): string =
  for index in 0 ..< 40:
    var c = slotCentre(index)
    if mirrored: c.x = -c.x
    result.add &"<circle cx=\"{mm(cx + c.x)}\" cy=\"{mm(cy + c.y)}\" r=\"0.8\" class=\"mark\"/>\n"

proc keyCorner(): Corner =
  for c in corners():
    if c.first.keyed: return c

proc plainCorner(): Corner =
  for c in corners():
    if not c.first.keyed: return c

proc body*(part: PartKind, cx, cy: float): string =
  case part
  of base: polygon(octagon(PlateApothem), cx, cy) & plateSlots(cx, cy, BottomTab)
  of floor:
    var s = polygon(octagon(PlateApothem), cx, cy) & floorSlots(cx, cy)
    for index in 0 ..< 40: s.add polygon(slotCorners(index), cx, cy)
    s
  of stripA: stripProfile(plainCorner().first, cx, cy)
  of stripB: stripProfile(plainCorner().second, cx, cy)
  of keyStripA: stripProfile(keyCorner().first, cx, cy)
  of keyStripB: stripProfile(keyCorner().second, cx, cy)
  of lid: polygon(octagon(PlateApothem), cx, cy) & plateSlots(cx, cy, TopTab)
  of sensorBoard: polygon(outline(), cx, cy) & sensorMarks(cx, cy, mirrored = false)
  of ledBoard: polygon(octagon(Apothem), cx, cy) & sensorMarks(cx, cy, mirrored = true)

proc partSvg*(part: PartKind): string =
  let size = 2 * PlateApothem / cos(PI / 8) + 8
  svgDocument(size, size, &"{part.title} ×{part.count}", part.body(size / 2, size / 2))

proc topViewSvg*(): string =
  ## Not a cut file: plan view to check fit. Red = floor plate, token outline,
  ## slots; blue = strips (out to their finger ends) and shoulders.
  let size = 2 * PlateApothem / cos(PI / 8) + 8
  let (cx, cy) = (size / 2, size / 2)
  proc blue(points: seq[Point]): string =
    var coords = ""
    for p in points: coords.add &"{mm(cx + p.x)},{mm(cy + p.y)} "
    &"<polygon points=\"{coords}\" fill=\"#2a78d6\" fill-opacity=\"0.35\" stroke=\"#2a78d6\" stroke-width=\"0.15\"/>\n"
  var body = polygon(octagon(PlateApothem), cx, cy) & polygon(outline(), cx, cy)
  for s in strips():
    body.add blue(s.footprint(0, s.fingerEnd, 0, Ply))
    body.add blue(s.footprint(-Shoulder, 0, 0, Ply))
  for index in 0 ..< 40: body.add polygon(slotCorners(index), cx, cy)
  svgDocument(size, size, "Top view (not a cut file)", body)

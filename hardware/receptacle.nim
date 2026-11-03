## The plywood stand the tokens stack in (`nim cup`), tab-and-slot, from the
## token geometry in plates.nim. Everything is 3 mm plywood.
##
##   lid        plate resting on the strip tops; LED board underneath (40 LEDs
##              over the 40 slots), batteries on top
##   strips     upright guides at 4 of the octagon's 8 corners. Three corners
##              have a pair of strips, one on each side near the corner. The
##              keyed corner has one angled strip lying against the tokens'
##              unevenly clipped corner, so only the right-way-up token fits.
##              The open corners in between are finger access. Strips tab into
##              the base, carry the floor on a shoulder, and tab into the lid.
##   floor      plate with the 40 slots (the baffle) and slots for the strips
##   (gap)      the sensor board sits here on spacers, 40 sensors facing up
##   base       plate with slots for the strip tabs

import std/[math, strformat]
import plates

const
  Ply* = 3.0
  Fit* = 0.1                  ## slot clearance for plywood tabs, per side
  Clearance* = 0.3            ## token to strips, per side
  StripWidth* = 10.0
  KeyStripWidth* = 14.0       ## the angled strip at the keyed corner
  BoardGap* = 6.0             ## base top to floor bottom: sensor board + parts
  PocketTokens* = 6
  PocketHeight* = float(PocketTokens) * Ply
  Shoulder* = 2.0             ## strips are this much wider below the floor
  PlateApothem* = 50.0        ## base, floor and lid

  InnerApothem* = Apothem + Clearance         ## strips' inner faces
  StripTop* = BoardGap + Ply + PocketHeight   ## from the base's top face
  CornerSides* = [0, 2, 4, 6]                 ## guides at the corners after these sides

type Guide* = object
  ## One upright strip, as a frame in plan view: it runs along `u` from
  ## `origin`, its inner face on the line, its thickness outward along `m`.
  origin*, u*, m*: Point
  width*: float
  shoulderAtStart*: bool      ## which end gets the shoulder (away from the corner)

proc sub(a, b: Point): Point = (a.x - b.x, a.y - b.y)
proc length(a: Point): float = sqrt(a.x * a.x + a.y * a.y)

proc guides*(): seq[Guide] =
  let edge = SideLength / 2 - 1.0
  for side in 0 .. 7:
    if side in [KeySide, KeySide + 1]: continue        # replaced by the key strip
    let (n, t) = (normal(side), tangent(side))
    if side in CornerSides:     # corner at the clockwise end
      result.add Guide(origin: InnerApothem * n + (edge - StripWidth) * t, u: t, m: n,
                       width: StripWidth, shoulderAtStart: true)
    else:                       # corner at the anticlockwise end
      result.add Guide(origin: InnerApothem * n + (-edge) * t, u: t, m: n,
                       width: StripWidth, shoulderAtStart: false)
  # the key strip, against the clipped corner, Clearance outside it
  let (a, b) = chamferEnds(Apothem)
  let d = sub(b, a)
  let u = (1 / length(d)) * d
  let m: Point = (u.y, -u.x)                 # outward; tests/test_plates checks the side
  let mid = 0.5 * (a + b)
  result.add Guide(origin: mid + Clearance * m + (-KeyStripWidth / 2) * u, u: u, m: m,
                   width: KeyStripWidth, shoulderAtStart: true)

proc footprint*(g: Guide, along0, along1, out0, out1: float): seq[Point] =
  @[g.origin + along0 * g.u + out0 * g.m, g.origin + along0 * g.u + out1 * g.m,
    g.origin + along1 * g.u + out1 * g.m, g.origin + along1 * g.u + out0 * g.m]

proc guideSlots(cx, cy: float, inset: float): string =
  ## A slot for each strip, `inset` narrower than the strip at each end.
  for g in guides():
    result.add polygon(g.footprint(inset - Fit, g.width - inset + Fit, -Fit, Ply + Fit), cx, cy)

proc profile(points: openArray[(float, float)], cx, cy: float): string =
  ## A flat part drawn in its own plane (x across, y up), centred at (cx, cy).
  var p: seq[Point]
  for (x, y) in points: p.add (x, -y)
  polygon(p, cx, cy)

proc stripProfile(w, cx, cy: float): string =
  ## Bottom tab into the base, shoulder (carries the floor) on one end, top
  ## tab into the lid. Flip the part to put the shoulder on the other end.
  profile([(2.0, -Ply), (w - 2.0, -Ply), (w - 2.0, 0.0), (w, 0.0), (w, StripTop),
           (w - 2.5, StripTop), (w - 2.5, StripTop + Ply), (2.5, StripTop + Ply),
           (2.5, StripTop), (0.0, StripTop), (0.0, BoardGap), (-Shoulder, BoardGap),
           (-Shoulder, 0.0), (2.0, 0.0)], cx - w / 2, cy + StripTop / 2)

type PartKind* = enum
  base, floor, strip, keyStrip, lid, sensorBoard, ledBoard

proc name*(part: PartKind): string =
  ["base", "floor", "strip", "key-strip", "lid", "sensor-board", "led-board"][ord(part)]

proc title*(part: PartKind): string =
  case part
  of base: "Base (slots for the strip tabs)"
  of floor: "Floor = baffle (40 slots + strip slots)"
  of strip: "Guide strip (6 identical; shoulder on the end away from the corner)"
  of keyStrip: "Key strip (angled, at the clipped corner)"
  of lid: "Lid (rests on the strip tops; LED board underneath)"
  of sensorBoard: "Sensor board outline (for KiCad); blue = sensor positions"
  of ledBoard: "LED board outline (faces down; blue = LED positions, mirrored)"

proc count*(part: PartKind): int = (if part == strip: 6 else: 1)

proc sensorMarks(cx, cy: float, mirrored: bool): string =
  for index in 0 ..< 40:
    var c = slotCentre(index)
    if mirrored: c.x = -c.x
    result.add &"<circle cx=\"{mm(cx + c.x)}\" cy=\"{mm(cy + c.y)}\" r=\"0.8\" class=\"mark\"/>\n"

proc body*(part: PartKind, cx, cy: float): string =
  case part
  of base: polygon(octagon(PlateApothem), cx, cy) & guideSlots(cx, cy, inset = 2.0)
  of floor:
    var s = polygon(octagon(PlateApothem), cx, cy) & guideSlots(cx, cy, inset = 0.0)
    for index in 0 ..< 40: s.add polygon(slotCorners(index), cx, cy)
    s
  of strip: stripProfile(StripWidth, cx, cy)
  of keyStrip: stripProfile(KeyStripWidth, cx, cy)
  of lid: polygon(octagon(PlateApothem), cx, cy) & guideSlots(cx, cy, inset = 2.5)
  of sensorBoard: polygon(outline(), cx, cy) & sensorMarks(cx, cy, mirrored = false)
  of ledBoard: polygon(octagon(Apothem), cx, cy) & sensorMarks(cx, cy, mirrored = true)

proc partSvg*(part: PartKind): string =
  let size = 2 * PlateApothem / cos(PI / 8) + 8
  svgDocument(size, size, &"{part.title} ×{part.count}", part.body(size / 2, size / 2))

proc topViewSvg*(): string =
  ## Not a cut file: plan view to check fit. Red = floor plate, token outline,
  ## slots; blue = strips with their shoulders.
  let size = 2 * PlateApothem / cos(PI / 8) + 8
  let (cx, cy) = (size / 2, size / 2)
  proc blue(points: seq[Point]): string =
    var coords = ""
    for p in points: coords.add &"{mm(cx + p.x)},{mm(cy + p.y)} "
    &"<polygon points=\"{coords}\" fill=\"#2a78d6\" fill-opacity=\"0.35\" stroke=\"#2a78d6\" stroke-width=\"0.15\"/>\n"
  var body = polygon(octagon(PlateApothem), cx, cy) & polygon(outline(), cx, cy)
  for g in guides():
    body.add blue(g.footprint(0, g.width, 0, Ply))
    body.add blue(if g.shoulderAtStart: g.footprint(-Shoulder, 0, 0, Ply)
                  else: g.footprint(g.width, g.width + Shoulder, 0, Ply))
  for index in 0 ..< 40: body.add polygon(slotCorners(index), cx, cy)
  svgDocument(size, size, "Top view (not a cut file)", body)

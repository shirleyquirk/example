## The plywood stand the tokens stack in (`nim cup`), tab-and-slot, from the
## token geometry in plates.nim. Everything is 3 mm plywood.
##
##   lid        plate resting on the strip tops; LED board underneath (40 LEDs
##              over the 40 slots), batteries on top
##   strips     8 upright guides in pairs at 4 of the octagon's 8 corners. Each
##              side of the octagon gets one strip near one end, so the token is
##              held on all 8 sides; the open corners between pairs are finger
##              access. Strips tab into the base, carry the floor on shoulders,
##              and tab into the lid.
##   key fin    one small upright piece, tabbed into the floor, sitting in the
##              tokens' notch: the only way a token fits is right way up
##   floor      plate with the 40 slots (the baffle) and slots for the strips
##   (gap)      the sensor board sits here on spacers, 40 sensors facing up
##   base       plate with slots for the strip tabs
##
## Coordinates: a strip lies flat against one side of the octagon, outside the
## token, from `along` StripFrom to StripTo measured from the side's centre.

import std/[math, strformat]
import plates

const
  Ply* = 3.0
  Fit* = 0.1                  ## slot clearance for plywood tabs, per side
  Clearance* = 0.3            ## token to strips, per side
  StripWidth* = 10.0
  BoardGap* = 6.0             ## base top to floor bottom: sensor board + parts
  PocketTokens* = 6
  PocketHeight* = float(PocketTokens) * Ply
  Shoulder* = 2.0             ## strips are this much wider below the floor
  PlateApothem* = 50.0        ## base, floor and lid

  InnerApothem* = Apothem + Clearance         ## strips' inner faces
  StripTop* = BoardGap + Ply + PocketHeight   ## from the base's top face
  CornerSides = [0, 2, 4, 6]                  ## pairs at the corners after these sides

  FinWidth* = 4.4
  FinCentre* = (NotchFrom + NotchTo) / 2
  FinInner* = Apothem - NotchDepth + Clearance   ## fin's inner face, radial

proc stripSpan*(side: int): (float, float) =
  ## Along-side range of the strip on `side`: at the end of the side that
  ## belongs to a guide pair, stopping 1 mm short of the corner.
  let edge = SideLength / 2 - 1.0
  if side in CornerSides: (edge - StripWidth, edge)        # clockwise end
  else: (-edge, -edge + StripWidth)                         # anticlockwise end

proc rect*(side: int, along0, along1, radial0, radial1: float): seq[Point] =
  let (n, t) = (normal(side), tangent(side))
  @[radial0 * n + along0 * t, radial1 * n + along0 * t,
    radial1 * n + along1 * t, radial0 * n + along1 * t]

proc stripSlots(cx, cy: float, inset: float): string =
  ## A slot for each strip, `inset` narrower than the strip at each end.
  for side in 0 .. 7:
    let (a0, a1) = stripSpan(side)
    result.add polygon(rect(side, a0 + inset - Fit, a1 - inset + Fit,
                            InnerApothem - Fit, InnerApothem + Ply + Fit), cx, cy)

proc finSlot(cx, cy: float): string =
  ## The fin's tab goes through the floor here.
  polygon(rect(NotchSide, FinCentre - 1.2 - Fit, FinCentre + 1.2 + Fit,
               FinInner - Fit, FinInner + Ply + Fit), cx, cy)

proc profile(points: openArray[(float, float)], cx, cy: float): string =
  ## A flat part drawn in its own plane (x across, y up), centred at (cx, cy).
  var p: seq[Point]
  for (x, y) in points: p.add (x, -y)
  polygon(p, cx, cy)

type PartKind* = enum
  base, floor, strip, keyFin, lid, sensorBoard, ledBoard

proc name*(part: PartKind): string =
  ["base", "floor", "strip", "key-fin", "lid", "sensor-board", "led-board"][ord(part)]

proc title*(part: PartKind): string =
  case part
  of base: "Base (slots for the strip tabs)"
  of floor: "Floor = baffle (40 slots, strip slots, key-fin slot)"
  of strip: "Guide strip (8 identical; shoulder away from the corner)"
  of keyFin: "Key fin"
  of lid: "Lid (rests on the strip tops; LED board underneath)"
  of sensorBoard: "Sensor board outline (for KiCad); blue = sensor positions"
  of ledBoard: "LED board outline (faces down; blue = LED positions, mirrored)"

proc count*(part: PartKind): int = (if part == strip: 8 else: 1)

proc sensorMarks(cx, cy: float, mirrored: bool): string =
  for index in 0 ..< 40:
    var c = slotCentre(index)
    if mirrored: c.x = -c.x
    result.add &"<circle cx=\"{mm(cx + c.x)}\" cy=\"{mm(cy + c.y)}\" r=\"0.8\" class=\"mark\"/>\n"

proc body*(part: PartKind, cx, cy: float): string =
  let w = StripWidth
  case part
  of base:
    # bottom tabs are the strip's middle 6 mm
    polygon(octagon(PlateApothem), cx, cy) & stripSlots(cx, cy, inset = 2.0)
  of floor:
    var s = polygon(octagon(PlateApothem), cx, cy) & stripSlots(cx, cy, inset = 0.0) &
      finSlot(cx, cy)
    for index in 0 ..< 40: s.add polygon(slotCorners(index), cx, cy)
    s
  of strip:
    # bottom tab into the base; wider below the floor (the floor rests on the
    # shoulders); top tab into the lid
    # One shoulder, on the end away from the corner: a shoulder at the corner
    # end would hit the paired strip. Flip the strip over for the other side
    # of each pair, so all 8 are cut from this one shape.
    profile([(2.0, -Ply), (w - 2.0, -Ply), (w - 2.0, 0.0), (w, 0.0), (w, StripTop),
             (w - 2.5, StripTop), (w - 2.5, StripTop + Ply), (2.5, StripTop + Ply),
             (2.5, StripTop), (0.0, StripTop), (0.0, BoardGap), (-Shoulder, BoardGap),
             (-Shoulder, 0.0), (2.0, 0.0)], cx - w / 2, cy + StripTop / 2)
  of keyFin:
    profile([(FinWidth / 2 - 1.2, -Ply), (FinWidth / 2 + 1.2, -Ply), (FinWidth / 2 + 1.2, 0.0),
             (FinWidth, 0.0), (FinWidth, PocketHeight), (0.0, PocketHeight), (0.0, 0.0),
             (FinWidth / 2 - 1.2, 0.0)], cx - FinWidth / 2, cy + PocketHeight / 2)
  of lid:
    polygon(octagon(PlateApothem), cx, cy) & stripSlots(cx, cy, inset = 2.5)
  of sensorBoard: polygon(outline(), cx, cy) & sensorMarks(cx, cy, mirrored = false)
  of ledBoard: polygon(octagon(Apothem), cx, cy) & sensorMarks(cx, cy, mirrored = true)

proc partSvg*(part: PartKind): string =
  let size = 2 * PlateApothem / cos(PI / 8) + 8
  svgDocument(size, size, &"{part.title} ×{part.count}", part.body(size / 2, size / 2))

proc topViewSvg*(): string =
  ## Not a cut file: plan view to check fit. Grey = floor plate and token
  ## outline; blue = strips (with their shoulders), key fin, sensor positions.
  let size = 2 * PlateApothem / cos(PI / 8) + 8
  let (cx, cy) = (size / 2, size / 2)
  proc blue(points: seq[Point]): string =
    var coords = ""
    for p in points: coords.add &"{mm(cx + p.x)},{mm(cy + p.y)} "
    &"<polygon points=\"{coords}\" fill=\"#2a78d6\" fill-opacity=\"0.35\" stroke=\"#2a78d6\" stroke-width=\"0.15\"/>\n"
  var body = polygon(octagon(PlateApothem), cx, cy) & polygon(outline(), cx, cy)
  for side in 0 .. 7:
    let (a0, a1) = stripSpan(side)
    body.add blue(rect(side, a0, a1, InnerApothem, InnerApothem + Ply))
    # shoulder (below the floor), on the end away from the corner
    if side in CornerSides: body.add blue(rect(side, a0 - Shoulder, a0, InnerApothem, InnerApothem + Ply))
    else: body.add blue(rect(side, a1, a1 + Shoulder, InnerApothem, InnerApothem + Ply))
  body.add blue(rect(NotchSide, FinCentre - FinWidth / 2, FinCentre + FinWidth / 2, FinInner, FinInner + Ply))
  for index in 0 ..< 40: body.add polygon(slotCorners(index), cx, cy)
  svgDocument(size, size, "Top view (not a cut file)", body)

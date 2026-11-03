## The plywood cup the tokens stack in, its lid, and the outlines of the two
## circuit boards, all from the token geometry in plates.nim (`nim cup`).
##
## Cross-section (bottom to top), all layers 3 mm plywood unless noted:
##
##   base            solid octagon, screwed on, so the sensor board goes in from below
##   board zone      rings around the sensor board (same outline and notch as a
##                   token, 40 sensors facing up); one has a gap for the cable
##   floor           solid layer with the 40 slots cut through: the pocket's
##                   floor and the baffle in one, glued into the stack
##   pocket          rings with finger slots on two opposite sides; holds up to
##                   PocketTokens tokens
##   lid             slides over the cup. Its skirt covers the finger slots so
##                   room light can't reach the sensors. Inside: the LED board
##                   (40 LEDs, one above each slot) and batteries
##
## Every pocket and board-zone ring has a tab on its inner wall that matches the
## tokens' notch, so tokens, baffle and sensor board all register the same way.

import std/[math, strformat]
import plates

const
  Ply* = 3.0                  ## plywood thickness
  Clearance* = 0.3            ## token to pocket, per side
  Wall* = 8.0
  BoardRings* = 2             ## 6 mm: 1.6 mm board + ≤ 2 mm parts, all on the top side
  PocketTokens* = 6           ## likely stacks are 2–3; room for 6
  CableGapWidth* = 14.0       ## in the board-zone rings, on the bottom flat
  CableSide = 4
  FingerSlotWidth* = 22.0
  FingerSides = [2, 6]        ## right and left flats
  LidClearance* = 0.4
  SkirtWall* = 5.0

  InnerApothem* = Apothem + Clearance
  OuterApothem* = InnerApothem + Wall
  PocketRings* = PocketTokens       ## tokens are Ply thick too
  SkirtApothem* = OuterApothem + LidClearance        ## inside of the lid skirt
  SkirtOuterApothem* = SkirtApothem + SkirtWall
  SkirtRings* = PocketRings                          ## covers the finger slots

proc pocketOutline*(): seq[Point] =
  ## Inside of a ring: octagon with the tab that matches the tokens' notch.
  let tabFace = Apothem - NotchDepth + Clearance     ## tab's inner face
  octagon(InnerApothem, NotchFrom + Clearance, NotchTo - Clearance,
          InnerApothem - tabFace)

proc wallGap(side: int, width, cx, cy: float): string =
  ## A rectangle across the wall on one flat. Cutting it splits the ring there;
  ## the waste between the cuts falls out.
  let (n, t) = (normal(side), tangent(side))
  let w = width / 2
  polygon([(InnerApothem - 1) * n + (-w) * t, (OuterApothem + 1) * n + (-w) * t,
           (OuterApothem + 1) * n + w * t, (InnerApothem - 1) * n + w * t], cx, cy)

proc fingerSlots(cx, cy: float): string =
  for side in FingerSides: result.add wallGap(side, FingerSlotWidth, cx, cy)

proc sensorMarks(cx, cy: float, mirrored: bool): string =
  ## Blue marks (not cut): where each slot's sensor or LED goes. The LED board
  ## faces down, so its positions are mirrored left-right.
  for index in 0 ..< 40:
    var c = slotCentre(index)
    if mirrored: c.x = -c.x
    result.add &"<circle cx=\"{mm(cx + c.x)}\" cy=\"{mm(cy + c.y)}\" r=\"0.8\" class=\"mark\"/>\n"

type PartKind* = enum
  base, boardRing, floor, pocketRing, lidTop, lidSkirt, sensorBoard, ledBoard

proc name*(part: PartKind): string =
  ["base", "board-ring", "floor", "pocket-ring", "lid-top", "lid-skirt",
   "sensor-board", "led-board"][ord(part)]

proc title*(part: PartKind): string =
  case part
  of base: "Base (solid)"
  of boardRing: "Board-zone ring (gap for the cable)"
  of floor: "Pocket floor = baffle (40 slots)"
  of pocketRing: "Pocket ring with finger slots"
  of lidTop: "Lid top (solid)"
  of lidSkirt: "Lid skirt ring"
  of sensorBoard: "Sensor board outline (for KiCad); blue = sensor positions"
  of ledBoard: "LED board outline (faces down; blue = LED positions, mirrored)"

proc count*(part: PartKind): int =
  case part
  of boardRing: BoardRings
  of pocketRing: PocketRings
  of lidSkirt: SkirtRings
  else: 1

proc body*(part: PartKind, cx, cy: float): string =
  case part
  of base: polygon(octagon(OuterApothem), cx, cy)
  of boardRing:
    polygon(octagon(OuterApothem), cx, cy) & polygon(pocketOutline(), cx, cy) &
      wallGap(CableSide, CableGapWidth, cx, cy)
  of floor:
    var slots = polygon(octagon(OuterApothem), cx, cy)
    for index in 0 ..< 40: slots.add polygon(slotCorners(index), cx, cy)
    slots
  of pocketRing:
    polygon(octagon(OuterApothem), cx, cy) & polygon(pocketOutline(), cx, cy) &
      fingerSlots(cx, cy)
  of lidTop: polygon(octagon(SkirtOuterApothem), cx, cy)
  of lidSkirt:
    polygon(octagon(SkirtOuterApothem), cx, cy) & polygon(octagon(SkirtApothem), cx, cy)
  of sensorBoard: polygon(outline(), cx, cy) & sensorMarks(cx, cy, mirrored = false)
  of ledBoard: polygon(octagon(OuterApothem - 1.0), cx, cy) & sensorMarks(cx, cy, mirrored = true)

proc partSvg*(part: PartKind, apothem: float): string =
  let size = 2 * apothem / cos(PI / 8) + 8
  svgDocument(size, size, &"{part.title} ×{part.count}", part.body(size / 2, size / 2))

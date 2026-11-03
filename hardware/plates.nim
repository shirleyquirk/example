## Laser-cutting artwork for the symbol tokens, generated from the same
## `NotebookDeck` the app uses.
##
## Each token is a regular octagon of opaque sheet (black acrylic or black
## card) with 40 slot positions, five along each side, one per card. A token
## for symbol S has a slot cut at card i when card i does NOT show S. Stacking
## tokens lets light through position i only if every token has a slot there,
## i.e. card i shows none of the stacked symbols: the lit positions are exactly
## the danger cards.
##
## Registration: tokens sit in an octagonal pocket. One small notch near one end
## of one side matches a tab in the pocket. A notch at a corner would not do,
## because every corner lies on a mirror axis, so a flipped token would still
## fit. Offset along a side, the notch has no mirror image anywhere: only the
## right-way-up orientation seats.
##
## The icon is engraved in the middle; there is no text on the token. Names
## live in the file name and the SVG <title>.
##
## Units are mm. Red hairlines (#ff0000, 0.1 mm) are cuts; black fills are engraving.

import std/[math, strutils, strformat]
import ../src/model

const
  AcrossFlats* = 80.0                 ## octagon size, flat to flat
  Apothem* = AcrossFlats / 2
  SideLength* = AcrossFlats * tan(PI / 8)
  SlotsPerSide* = 5
  SlotPitch* = 5.0                    ## along the side
  SlotLength* = 6.0                   ## radial
  SlotWidth* = 2.2                    ## along the side (area = length × width, same for every slot)
  SlotLean* = 25.0                    ## degrees: slots are leaning parallelograms
  SlotDepth* = 9.0                    ## slot centre, measured in from the edge (clear of the key notch)
  NotchSide* = 7                      ## the upper-left side
  NotchFrom* = 8.0                    ## along the side from its centre; never 0, so no mirror symmetry
  NotchTo* = 13.0                     ## 5 mm wide: the 4.4 mm key fin + clearance
  NotchDepth* = 4.0                   ## the 3 mm key fin + clearance
  IconSize* = 36.0                    ## square, centred
  Margin = 4.0

static: doAssert DeckSize == 8 * SlotsPerSide

type
  PlateKind* = enum
    symbolPlate   ## slots where the card lacks the symbol
    blankSafe     ## slots everywhere except the blank card(s): stack it to count blanks as safe
    baffle        ## all 40 slots; sits permanently over the detector

  Plate* = object
    kind*: PlateKind
    symbol*: Symbol      ## for symbolPlate only
    holes*: Cards        ## card positions with a slot

proc plateFor*(symbol: Symbol, deck = NotebookDeck): Plate =
  Plate(kind: symbolPlate, symbol: symbol, holes: AllCards - deck[symbol])

proc blankSafePlate*(deck = NotebookDeck): Plate =
  Plate(kind: blankSafe, holes: AllCards - deck.blank)

proc bafflePlate*(): Plate = Plate(kind: baffle, holes: AllCards)

proc title*(plate: Plate): string =
  case plate.kind
  of symbolPlate: $plate.symbol & " (" & Letter[plate.symbol] & ")"
  of blankSafe: "Blank safe"
  of baffle: "Baffle"

proc fileName*(plate: Plate): string =
  case plate.kind
  of symbolPlate: Letter[plate.symbol] & "-" & toLowerAscii($plate.symbol) & ".svg"
  of blankSafe: "blank-safe.svg"
  of baffle: "baffle.svg"

# ---------------------------------------------------------------- geometry

type Point* = tuple[x, y: float]

proc `+`*(a, b: Point): Point = (a.x + b.x, a.y + b.y)
proc `*`*(k: float, a: Point): Point = (k * a.x, k * a.y)

proc normal*(side: int): Point =
  ## Outward unit normal of side 0..7 (0 = top, clockwise); SVG y grows down.
  let a = float(side) * PI / 4
  (sin(a), -cos(a))

proc tangent*(side: int): Point =
  ## Unit vector along the side, clockwise.
  let a = float(side) * PI / 4
  (cos(a), sin(a))

proc slotCentre*(index: CardIndex): Point =
  ## Card i is slot (i mod 5) on side (i div 5), going clockwise from the
  ## top-left of the top side.
  let side = index div SlotsPerSide
  let along = (float(index mod SlotsPerSide) - float(SlotsPerSide - 1) / 2) * SlotPitch
  (Apothem - SlotDepth) * normal(side) + along * tangent(side)

proc slotCorners*(index: CardIndex): array[4, Point] =
  let side = index div SlotsPerSide
  let (n, t) = (normal(side), tangent(side))
  let c = slotCentre(index)
  let lean = SlotLength / 2 * tan(degToRad(SlotLean))
  [c + (-SlotLength / 2) * n + (-SlotWidth / 2 - lean) * t,
   c + (-SlotLength / 2) * n + (SlotWidth / 2 - lean) * t,
   c + (SlotLength / 2) * n + (SlotWidth / 2 + lean) * t,
   c + (SlotLength / 2) * n + (-SlotWidth / 2 + lean) * t]

proc octagon*(apothem: float, notchFrom = 0.0, notchTo = 0.0, notchDepth = 0.0): seq[Point] =
  ## Regular octagon, flat on top, clockwise. With notchDepth > 0, a notch
  ## (or, seen from inside a pocket, a tab) on side NotchSide between
  ## notchFrom and notchTo along the side.
  let side = 2 * apothem * tan(PI / 8)
  for s in 0 .. 7:
    let (n, t) = (normal(s), tangent(s))
    result.add apothem * n + (-side / 2) * t
    if s == NotchSide and notchDepth > 0:
      result.add apothem * n + notchFrom * t
      result.add (apothem - notchDepth) * n + notchFrom * t
      result.add (apothem - notchDepth) * n + notchTo * t
      result.add apothem * n + notchTo * t

proc outline*(): seq[Point] =
  ## The token outline: octagon with its registration notch.
  octagon(Apothem, NotchFrom, NotchTo, NotchDepth)

# ---------------------------------------------------------------- icons
# Traced from the rulebook's Biome Icons page by `nim icons` (potrace output in
# hardware/icons/). Embedded at compile time; black fill = engrave.

proc iconFile(symbol: Symbol): string =
  const files: array[Symbol, string] = [
    staticRead("icons/void.svg"), staticRead("icons/caves.svg"),
    staticRead("icons/volcanic.svg"), staticRead("icons/hostile.svg"),
    staticRead("icons/crystalline.svg"), staticRead("icons/deadly.svg"),
    staticRead("icons/vegetation.svg"), staticRead("icons/water.svg"),
    staticRead("icons/ruins.svg"), staticRead("icons/frigid.svg"),
    staticRead("icons/rocky.svg"), staticRead("icons/desert.svg")]
  files[symbol]

proc mm*(x: float): string = formatFloat(x, ffDecimal, 3)

proc iconAt(symbol: Symbol, cx, cy, size: float): string =
  ## potrace's <g>…</g> in a nested <svg> with potrace's viewBox, `size` mm square.
  let file = iconFile(symbol)
  const key = "viewBox=\""
  let start = file.find(key) + key.len
  let viewBox = file[start ..< file.find('"', start)]
  let paths = file[file.find("<g") .. file.rfind("</g>") + 3]
  &"<svg x=\"{mm(cx - size / 2)}\" y=\"{mm(cy - size / 2)}\" width=\"{mm(size)}\" " &
    &"height=\"{mm(size)}\" viewBox=\"{viewBox}\">{paths}</svg>\n"

# ---------------------------------------------------------------- SVG

proc polygon*(points: openArray[Point], cx, cy: float): string =
  var coords: seq[string]
  for p in points: coords.add mm(cx + p.x) & "," & mm(cy + p.y)
  "<polygon points=\"" & coords.join(" ") & "\" class=\"cut\"/>\n"

proc plateBody*(plate: Plate, cx, cy: float): string =
  ## The token's cut and engrave elements, centred at (cx, cy).
  result.add "<g id=\"" & plate.fileName.replace(".svg", "") & "\"><title>" &
    plate.title & ", " & $card(plate.holes) & " slots</title>\n"
  result.add polygon(outline(), cx, cy)
  for index in CardIndex:
    if index in plate.holes:
      result.add polygon(slotCorners(index), cx, cy)
  if plate.kind == symbolPlate:
    result.add iconAt(plate.symbol, cx, cy, IconSize)
  result.add "</g>\n"

const Style = """<style>
  .cut { fill: none; stroke: #ff0000; stroke-width: 0.1; }
  .mark { fill: none; stroke: #0000ff; stroke-width: 0.1; }
</style>
"""

proc cellSize(): float = 2 * Apothem / cos(PI / 8) + 2 * Margin

proc svgDocument*(width, height: float, title, body: string): string =
  &"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{mm(width)}mm\" height=\"{mm(height)}mm\" " &
    &"viewBox=\"0 0 {mm(width)} {mm(height)}\">\n<title>{title}</title>\n" & Style & body & "</svg>\n"

proc plateSvg*(plate: Plate): string =
  let size = cellSize()
  svgDocument(size, size, plate.title, plateBody(plate, size / 2, size / 2))

proc allPlates*(deck = NotebookDeck): seq[Plate] =
  for symbol in Symbol: result.add plateFor(symbol, deck)
  result.add blankSafePlate(deck)

proc sheetSvg*(plates: seq[Plate], columns = 4): string =
  ## All tokens on one sheet, for a single laser job.
  let cell = cellSize()
  let rows = (plates.len + columns - 1) div columns
  var body = ""
  for i, plate in plates:
    body.add plateBody(plate, cell * (float(i mod columns) + 0.5),
                              cell * (float(i div columns) + 0.5))
  svgDocument(cell * float(columns), cell * float(rows), "All tokens", body)

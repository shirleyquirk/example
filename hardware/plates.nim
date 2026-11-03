## Laser-cutting artwork for the symbol plates, generated from the same
## `NotebookDeck` the app uses.
##
## Each plate is a disc of opaque material with 40 aperture positions on a
## ring, one per card. A plate for symbol S has a hole at card i when card i
## does NOT show S. Stacking plates lets light through position i only if every
## plate in the stack has a hole there, i.e. card i shows none of the stacked
## symbols: the lit positions are exactly the danger cards.
##
## Conventions: units are mm. Red hairlines (#ff0000, 0.1 mm) are cuts; black
## fills are engraving.

import std/[math, strutils]
import ../src/model

const
  PlateDiameter* = 100.0
  ApertureRingRadius* = 40.0     ## centre of the aperture ring
  ApertureDiameter* = 3.0        ## ~6.3 mm pitch at this radius
  SpindleDiameter* = 8.2         ## clearance on an 8 mm spindle
  PinDiameter* = 3.1             ## clearance on a 3 mm locating pin
  PinRadius* = 22.0
  PinAngle* = 20.0
    ## Degrees clockwise from the top. Not 0 or 180, so a plate placed upside
    ## down has its pin hole at -20° and won't seat: one orientation only.
  Margin = 5.0

type
  PlateKind* = enum
    symbolPlate   ## holes where the card lacks the symbol
    blankSafe     ## holes everywhere except the blank card(s): stack it to count blanks as safe
    baffle        ## all 40 holes; sits permanently over the detectors

  Plate* = object
    kind*: PlateKind
    symbol*: Symbol      ## for symbolPlate only
    holes*: Cards        ## card positions with an aperture

proc plateFor*(symbol: Symbol, deck = NotebookDeck): Plate =
  Plate(kind: symbolPlate, symbol: symbol, holes: AllCards - deck[symbol])

proc blankSafePlate*(deck = NotebookDeck): Plate =
  Plate(kind: blankSafe, holes: AllCards - deck.blank)

proc bafflePlate*(): Plate = Plate(kind: baffle, holes: AllCards)

proc title*(plate: Plate): string =
  case plate.kind
  of symbolPlate: $plate.symbol
  of blankSafe: "Blank safe"
  of baffle: "Baffle"

proc fileName*(plate: Plate): string =
  case plate.kind
  of symbolPlate: Letter[plate.symbol] & "-" & toLowerAscii($plate.symbol) & ".svg"
  of blankSafe: "blank-safe.svg"
  of baffle: "baffle.svg"

# ---------------------------------------------------------------- geometry

proc polar(radius, degreesClockwiseFromTop: float): (float, float) =
  ## Offset from the plate centre; SVG y grows downwards.
  let a = degToRad(degreesClockwiseFromTop)
  (radius * sin(a), -radius * cos(a))

proc cardAngle*(index: CardIndex): float = float(index) * 360.0 / DeckSize

proc mm(x: float): string =
  ## Fixed 3 decimals. (strutils.formatFloat calls C sprintf, which the
  ## NimScript VM that runs `nim plates` can't use.)
  let thousandths = int(round(abs(x) * 1000))
  (if x < 0 and thousandths != 0: "-" else: "") & $(thousandths div 1000) & "." &
    align($(thousandths mod 1000), 3, '0')

proc cutCircle(cx, cy, diameter: float): string =
  "<circle cx=\"" & mm(cx) & "\" cy=\"" & mm(cy) & "\" r=\"" & mm(diameter / 2) &
    "\" class=\"cut\"/>\n"

proc engraveText(cx, cy, size: float, text: string): string =
  "<text x=\"" & mm(cx) & "\" y=\"" & mm(cy) & "\" font-size=\"" & mm(size) &
    "\" class=\"engrave\">" & text & "</text>\n"

# ---------------------------------------------------------------- icons
# Traced from the rulebook's Biome Icons page by `nim icons` (potrace output in
# hardware/icons/). Embedded at compile time; black fill = engrave.

const IconSize* = 24.0   ## mm, square

proc iconFile(symbol: Symbol): string =
  ## potrace's SVG: keep its viewBox and the <g>…</g> holding the paths.
  const files: array[Symbol, string] = [
    staticRead("icons/void.svg"), staticRead("icons/caves.svg"),
    staticRead("icons/volcanic.svg"), staticRead("icons/hostile.svg"),
    staticRead("icons/crystalline.svg"), staticRead("icons/deadly.svg"),
    staticRead("icons/vegetation.svg"), staticRead("icons/water.svg"),
    staticRead("icons/ruins.svg"), staticRead("icons/frigid.svg"),
    staticRead("icons/rocky.svg"), staticRead("icons/desert.svg")]
  files[symbol]

proc between(text, first, last: string): string =
  ## The text from the start of `first` to the end of `last`.
  let a = text.find(first)
  let b = text.rfind(last)
  doAssert a >= 0 and b > a, "unexpected icon SVG"
  text[a ..< b + last.len]

proc iconAt*(symbol: Symbol, cx, cy, size: float): string =
  ## The icon as a nested <svg>, `size` mm square, centred at (cx, cy).
  let file = iconFile(symbol)
  const key = "viewBox=\""
  let start = file.find(key) + key.len
  let viewBoxAttr = file[start ..< file.find('"', start)]
  "<svg x=\"" & mm(cx - size / 2) & "\" y=\"" & mm(cy - size / 2) &
    "\" width=\"" & mm(size) & "\" height=\"" & mm(size) & "\" viewBox=\"" &
    viewBoxAttr & "\">" & file.between("<g", "</g>") & "</svg>\n"

proc plateBody*(plate: Plate, cx, cy: float): string =
  ## The plate's cut and engrave elements, centred at (cx, cy).
  result.add cutCircle(cx, cy, PlateDiameter)
  result.add cutCircle(cx, cy, SpindleDiameter)
  let (px, py) = polar(PinRadius, PinAngle)
  result.add cutCircle(cx + px, cy + py, PinDiameter)
  for index in CardIndex:
    let (x, y) = polar(ApertureRingRadius, cardAngle(index))
    if index in plate.holes:
      result.add cutCircle(cx + x, cy + y, ApertureDiameter)
    if index mod 5 == 0:
      # engraved tick and card number every 5 cards, outside the ring
      let (tx, ty) = polar(ApertureRingRadius + 5.0, cardAngle(index))
      result.add engraveText(cx + tx, cy + ty + 1.0, 2.8, $index)
  # Layout inside the ring, avoiding the spindle (centre) and the locating pin
  # (upper right, r = 22 mm at 20°):
  #   small print (notebook letter, cards blocked)  y = -27
  #   name                                          y = -12
  #   spindle                                       y =   0
  #   icon, 24 mm                                   y = +8 .. +32 (corner r = 34 < ring)
  let blocked = $(DeckSize - card(plate.holes)) & " blocked"
  result.add engraveText(cx, cy - 27.0, 2.6,
    (if plate.kind == symbolPlate: Letter[plate.symbol] & " · " & blocked else: blocked))
  result.add engraveText(cx, cy - 12.0, 6.0, plate.title)
  if plate.kind == symbolPlate:
    result.add iconAt(plate.symbol, cx, cy + 20.0, IconSize)

const Style = """<style>
  .cut { fill: none; stroke: #ff0000; stroke-width: 0.1; }
  .engrave { fill: #000; font-family: sans-serif; text-anchor: middle; }
</style>
"""

proc svgDocument(width, height: float, body: string): string =
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & mm(width) & "mm\" height=\"" &
    mm(height) & "mm\" viewBox=\"0 0 " & mm(width) & " " & mm(height) & "\">\n" &
    Style & body & "</svg>\n"

proc plateSvg*(plate: Plate): string =
  let size = PlateDiameter + 2 * Margin
  svgDocument(size, size, plateBody(plate, size / 2, size / 2))

proc allPlates*(deck = NotebookDeck): seq[Plate] =
  for symbol in Symbol: result.add plateFor(symbol, deck)
  result.add blankSafePlate(deck)
  result.add bafflePlate()

proc sheetSvg*(plates: seq[Plate], columns = 4): string =
  ## All plates on one sheet, for a single laser job.
  let cell = PlateDiameter + 2 * Margin
  let rows = (plates.len + columns - 1) div columns
  var body = ""
  for i, plate in plates:
    body.add plateBody(plate, cell * (float(i mod columns) + 0.5),
                              cell * (float(i div columns) + 0.5))
  svgDocument(cell * float(columns), cell * float(rows), body)

## Danger meter artwork (`nim meter`): a replacement dial for an analog panel
## meter, and a vertical scale to stand beside an IN-13 bargraph. Both show
## 0–100 % danger with green / yellow / red zones.
##
## Measure your meter before printing: the visible face size, where the needle
## pivot is, and the needle's sweep. Set the constants below to match.

import std/[math, os, strformat, strutils]

const
  # Panel meter dial (mm). Typical small rectangular meter; change to match yours.
  FaceWidth = 60.0
  FaceHeight = 46.0
  PivotX = FaceWidth / 2
  PivotY = FaceHeight + 6.0      ## needle pivot, often below the visible face
  ArcRadius = 31.0               ## where the scale sits along the needle
  Sweep = 90.0                   ## degrees, full scale

  # Zone boundaries, % danger. Purely a matter of taste.
  YellowFrom = 33.0
  RedFrom = 66.0
  Green = "#0ca30c"
  Yellow = "#fab219"
  Red = "#d03b3b"
  Ink = "#1a1a19"

  # IN-13 scale strip (mm): the glowing column is about 100 mm on the tubes I
  # know of. Check yours.
  BarLength = 100.0
  StripWidth = 14.0

proc f(x: float): string = formatFloat(x, ffDecimal, 2)

proc zoneColour(pct: float): string =
  if pct >= RedFrom: Red elif pct >= YellowFrom: Yellow else: Green

proc onArc(pct, radius: float): (float, float) =
  ## Point at `pct` along the sweep, `radius` from the pivot (0 % on the left).
  let a = degToRad(-Sweep / 2 + Sweep * pct / 100)
  (PivotX + radius * sin(a), PivotY - radius * cos(a))

proc band(fromPct, toPct, r0, r1: float, colour: string): string =
  ## A filled annular sector between two percentages.
  let (x0, y0) = onArc(fromPct, r1)
  let (x1, y1) = onArc(toPct, r1)
  let (x2, y2) = onArc(toPct, r0)
  let (x3, y3) = onArc(fromPct, r0)
  &"<path d=\"M{f(x0)} {f(y0)} A{f(r1)} {f(r1)} 0 0 1 {f(x1)} {f(y1)} L{f(x2)} {f(y2)} " &
    &"A{f(r0)} {f(r0)} 0 0 0 {f(x3)} {f(y3)} Z\" fill=\"{colour}\"/>\n"

proc dial*(): string =
  var body = &"<rect width=\"{f(FaceWidth)}\" height=\"{f(FaceHeight)}\" fill=\"#f4f1ea\"/>\n"
  body.add band(0, YellowFrom, ArcRadius - 4, ArcRadius, Green)
  body.add band(YellowFrom, RedFrom, ArcRadius - 4, ArcRadius, Yellow)
  body.add band(RedFrom, 100, ArcRadius - 4, ArcRadius, Red)
  for pct in countup(0, 100, 5):
    let major = pct mod 10 == 0
    let (x0, y0) = onArc(float(pct), ArcRadius)
    let (x1, y1) = onArc(float(pct), ArcRadius + (if major: 3.5 else: 2.0))
    body.add &"<line x1=\"{f(x0)}\" y1=\"{f(y0)}\" x2=\"{f(x1)}\" y2=\"{f(y1)}\" " &
      &"stroke=\"{Ink}\" stroke-width=\"{(if major: \"0.35\" else: \"0.2\")}\"/>\n"
    if pct mod 20 == 0:
      let (tx, ty) = onArc(float(pct), ArcRadius + 6.0)
      body.add &"<text x=\"{f(tx)}\" y=\"{f(ty + 1.0)}\" font-size=\"2.8\" text-anchor=\"middle\" " &
        &"font-family=\"sans-serif\" fill=\"{Ink}\">{pct}</text>\n"
  body.add &"<text x=\"{f(PivotX)}\" y=\"{f(PivotY - ArcRadius + 14)}\" font-size=\"4.2\" " &
    &"text-anchor=\"middle\" font-family=\"sans-serif\" font-weight=\"700\" letter-spacing=\"0.8\" " &
    &"fill=\"{Ink}\">DANGER</text>\n"
  body.add &"<text x=\"{f(PivotX)}\" y=\"{f(PivotY - ArcRadius + 18.5)}\" font-size=\"2.4\" " &
    &"text-anchor=\"middle\" font-family=\"sans-serif\" fill=\"{Ink}\">% next card</text>\n"
  body.add &"<rect width=\"{f(FaceWidth)}\" height=\"{f(FaceHeight)}\" fill=\"none\" stroke=\"#ff0000\" stroke-width=\"0.1\"/>\n"
  &"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{f(FaceWidth)}mm\" height=\"{f(FaceHeight)}mm\" " &
    &"viewBox=\"0 0 {f(FaceWidth)} {f(FaceHeight)}\">\n<title>Danger meter dial</title>\n{body}</svg>\n"

proc barScale*(): string =
  ## Vertical strip: 0 % at the bottom, 100 % at the top, for beside an IN-13.
  let h = BarLength + 10
  var body = &"<rect width=\"{f(StripWidth)}\" height=\"{f(h)}\" fill=\"#f4f1ea\"/>\n"
  proc y(pct: float): float = 5 + BarLength * (1 - pct / 100)
  for (a, b) in [(0.0, YellowFrom), (YellowFrom, RedFrom), (RedFrom, 100.0)]:
    body.add &"<rect x=\"0\" y=\"{f(y(b))}\" width=\"3\" height=\"{f(y(a) - y(b))}\" fill=\"{zoneColour(a)}\"/>\n"
  for pct in countup(0, 100, 5):
    let major = pct mod 10 == 0
    body.add &"<line x1=\"3\" y1=\"{f(y(float(pct)))}\" x2=\"{(if major: \"7\" else: \"5\")}\" " &
      &"y2=\"{f(y(float(pct)))}\" stroke=\"{Ink}\" stroke-width=\"0.25\"/>\n"
    if pct mod 20 == 0:
      body.add &"<text x=\"8\" y=\"{f(y(float(pct)) + 1)}\" font-size=\"2.8\" font-family=\"sans-serif\" fill=\"{Ink}\">{pct}</text>\n"
  body.add &"<rect width=\"{f(StripWidth)}\" height=\"{f(h)}\" fill=\"none\" stroke=\"#ff0000\" stroke-width=\"0.1\"/>\n"
  &"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{f(StripWidth)}mm\" height=\"{f(h)}mm\" " &
    &"viewBox=\"0 0 {f(StripWidth)} {f(h)}\">\n<title>Danger scale for an IN-13</title>\n{body}</svg>\n"

when isMainModule:
  const dir = "hardware/meter"
  createDir dir
  writeFile(dir / "dial.svg", dial())
  writeFile(dir / "in13-scale.svg", barScale())
  echo "wrote ", dir

## Minimal SVG charts for the simulation reports: line/dot charts and grouped
## bars. Runs inside NimScript (`nim results`), so no strutils.formatFloat
## (it calls C sprintf, which the VM can't).
##
## Every mark carries an SVG <title>, so hovering shows its value. Colours
## follow a validated categorical palette, with light and dark variants.

import std/[math, strutils]

type
  Series* = object
    name*: string
    points*: seq[(float, float)]

  Axis* = object
    label*: string
    min*, max*: float
    unit*: string           ## shown after values in tooltips, e.g. "%"

proc fixed*(x: float, decimals: int): string =
  ## x rounded to `decimals` places, e.g. fixed(3.14159, 2) = "3.14".
  let scale = 10 ^ decimals
  let scaled = int(round(abs(x) * float(scale)))
  result = (if x < 0 and scaled != 0: "-" else: "") & $(scaled div scale)
  if decimals > 0:
    result.add "." & align($(scaled mod scale), decimals, '0')

proc escapeXml(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

const
  Width = 760.0
  Height = 440.0
  Left = 72.0
  Right = 150.0    # room for direct labels at line ends
  Top = 84.0
  Bottom = 56.0
  PlotW = Width - Left - Right
  PlotH = Height - Top - Bottom
  MaxSeries = 4

  Style = """<style>
  .surface { fill: #fcfcfb; }
  .title { fill: #0b0b0b; font: 600 16px sans-serif; }
  .subtitle, .label { fill: #52514e; font: 12px sans-serif; }
  .tick { fill: #898781; font: 11px sans-serif; }
  .grid { stroke: #e1e0d9; stroke-width: 1; }
  .baseline { stroke: #c3c2b7; stroke-width: 1; }
  .ref { stroke: #898781; stroke-width: 1; stroke-dasharray: 4 4; fill: none; }
  .s0 { stroke: #2a78d6; fill: #2a78d6; } .s1 { stroke: #eb6834; fill: #eb6834; }
  .s2 { stroke: #1baf7a; fill: #1baf7a; } .s3 { stroke: #eda100; fill: #eda100; }
  .line { fill: none; stroke-width: 2; stroke-linejoin: round; }
  .dot { stroke: #fcfcfb; stroke-width: 2; }
  @media (prefers-color-scheme: dark) {
    .surface { fill: #1a1a19; }
    .title { fill: #f0efec; } .subtitle, .label { fill: #c3c2b7; }
    .grid { stroke: #2c2c2a; } .baseline { stroke: #383835; }
    .dot { stroke: #1a1a19; }
    .s0 { stroke: #3987e5; fill: #3987e5; } .s1 { stroke: #d95926; fill: #d95926; }
    .s2 { stroke: #199e70; fill: #199e70; } .s3 { stroke: #c98500; fill: #c98500; }
  }
</style>
"""

proc niceTicks(lo, hi: float, target = 5): seq[float] =
  ## Round-numbered tick positions covering [lo, hi].
  let raw = (hi - lo) / float(target)
  let magnitude = pow(10.0, floor(log10(raw)))
  var step = magnitude
  for factor in [1.0, 2.0, 2.5, 5.0, 10.0]:
    step = factor * magnitude
    if step >= raw: break
  var t = ceil(lo / step - 1e-9) * step
  while t <= hi + step * 1e-9:
    result.add (if abs(t) < step * 1e-9: 0.0 else: t)
    t += step

proc decimalsFor(ticks: seq[float]): int =
  ## Enough decimals to tell neighbouring ticks apart.
  if ticks.len < 2: return 0
  let step = ticks[1] - ticks[0]
  max(0, int(ceil(-log10(step) - 1e-9)))

proc header(title, subtitle: string): string =
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " & $int(Width) & " " &
    $int(Height) & "\" width=\"" & $int(Width) & "\" height=\"" & $int(Height) &
    "\" role=\"img\">\n" & Style &
    "<title>" & escapeXml(title) & "</title>\n" &
    "<rect class=\"surface\" width=\"100%\" height=\"100%\"/>\n" &
    "<text class=\"title\" x=\"" & $Left & "\" y=\"28\">" & escapeXml(title) & "</text>\n" &
    "<text class=\"subtitle\" x=\"" & $Left & "\" y=\"48\">" & escapeXml(subtitle) & "</text>\n"

proc legend(names: seq[string]): string =
  ## Swatch + name for each series, in one row under the subtitle.
  var x = Left
  for i, name in names:
    result.add "<rect class=\"s" & $i & "\" x=\"" & fixed(x, 1) &
      "\" y=\"60\" width=\"10\" height=\"10\" rx=\"2\"/>" &
      "<text class=\"label\" x=\"" & fixed(x + 14, 1) & "\" y=\"69\">" &
      escapeXml(name) & "</text>\n"
    x += 24.0 + 7.0 * float(name.len)

proc yAxis(y: Axis): string =
  let ticks = niceTicks(y.min, y.max)
  let decimals = decimalsFor(ticks)
  for t in ticks:
    let py = Top + PlotH * (1 - (t - y.min) / (y.max - y.min))
    result.add "<line class=\"" & (if t == 0.0: "baseline" else: "grid") &
      "\" x1=\"" & $Left & "\" x2=\"" & $(Left + PlotW) & "\" y1=\"" & fixed(py, 1) &
      "\" y2=\"" & fixed(py, 1) & "\"/>" &
      "<text class=\"tick\" x=\"" & $(Left - 8) & "\" y=\"" & fixed(py + 4, 1) &
      "\" text-anchor=\"end\">" & fixed(t, decimals) & "</text>\n"
  result.add "<text class=\"label\" transform=\"translate(18 " & fixed(Top + PlotH / 2, 1) &
    ") rotate(-90)\" text-anchor=\"middle\">" & escapeXml(y.label) & "</text>\n"

proc xLabel(label: string): string =
  "<text class=\"label\" x=\"" & fixed(Left + PlotW / 2, 1) & "\" y=\"" &
    $(Height - 14) & "\" text-anchor=\"middle\">" & escapeXml(label) & "</text>\n"

proc lineChart*(title, subtitle: string, x, y: Axis, series: seq[Series],
                lines = true, dots = false,
                reference: seq[(float, float)] = @[]): string =
  ## Line and/or dot chart. `reference` draws a dashed guide (e.g. zero error).
  doAssert series.len <= MaxSeries
  proc px(v: float): float = Left + PlotW * (v - x.min) / (x.max - x.min)
  proc py(v: float): float = Top + PlotH * (1 - (v - y.min) / (y.max - y.min))
  result = header(title, subtitle)
  if series.len >= 2: result.add legend(block:
    var names: seq[string]
    for s in series: names.add s.name
    names)
  result.add yAxis(y)
  let xTicks = niceTicks(x.min, x.max, 8)
  let xDecimals = decimalsFor(xTicks)
  for t in xTicks:
    result.add "<text class=\"tick\" x=\"" & fixed(px(t), 1) & "\" y=\"" &
      $(Top + PlotH + 18) & "\" text-anchor=\"middle\">" & fixed(t, xDecimals) & "</text>\n"
  result.add "<line class=\"baseline\" x1=\"" & $Left & "\" x2=\"" & $(Left + PlotW) &
    "\" y1=\"" & $(Top + PlotH) & "\" y2=\"" & $(Top + PlotH) & "\"/>\n"
  result.add xLabel(x.label)
  if reference.len >= 2:
    var d = ""
    for i, (vx, vy) in reference:
      d.add (if i == 0: "M" else: "L") & fixed(px(vx), 1) & " " & fixed(py(vy), 1)
    result.add "<path class=\"ref\" d=\"" & d & "\"/>\n"
  for i, s in series:
    if lines and s.points.len >= 2:
      var d = ""
      for j, (vx, vy) in s.points:
        d.add (if j == 0: "M" else: "L") & fixed(px(vx), 2) & " " & fixed(py(vy), 2)
      result.add "<path class=\"line s" & $i & "\" d=\"" & d & "\"><title>" &
        escapeXml(s.name) & "</title></path>\n"
    if dots:
      for (vx, vy) in s.points:
        result.add "<circle class=\"dot s" & $i & "\" cx=\"" & fixed(px(vx), 2) &
          "\" cy=\"" & fixed(py(vy), 2) & "\" r=\"4.5\"><title>" & escapeXml(s.name) &
          ": " & x.label & " " & fixed(vx, 3) & x.unit & ", " & y.label & " " &
          fixed(vy, 4) & y.unit & "</title></circle>\n"
  if series.len >= 2:
    # Direct labels at each series' last point, pushed apart vertically so
    # lines that end together don't print on top of each other.
    const minGap = 15.0
    var labels: seq[(float, float, string)]   # (y, x, name)
    for s in series:
      if s.points.len > 0:
        let (lx, ly) = s.points[^1]
        labels.add (py(ly) + 4, px(lx) + 8, s.name)
    for i in 1 ..< labels.len:                # sort by y (few series)
      var j = i
      while j > 0 and labels[j][0] < labels[j - 1][0]:
        swap(labels[j], labels[j - 1])
        dec j
    for i in 1 ..< labels.len:
      labels[i][0] = max(labels[i][0], labels[i - 1][0] + minGap)
    let overflow = labels.len > 0 and labels[^1][0] > Top + PlotH
    if overflow:
      let shift = labels[^1][0] - (Top + PlotH)
      for label in labels.mitems: label[0] -= shift
    var column = 0.0               # one column, right of the furthest line end
    for label in labels: column = max(column, label[1])
    for (ly, _, name) in labels:
      result.add "<text class=\"label\" x=\"" & fixed(column, 1) & "\" y=\"" &
        fixed(ly, 1) & "\">" & escapeXml(name) & "</text>\n"
  result.add "</svg>\n"

proc barChart*(title, subtitle: string, categories: seq[string], y: Axis,
               series: seq[Series], xAxisLabel = "", labelEvery = 1): string =
  ## Grouped bars: series[i].points[j][1] is the value for categories[j].
  doAssert series.len <= MaxSeries
  proc py(v: float): float = Top + PlotH * (1 - (v - y.min) / (y.max - y.min))
  result = header(title, subtitle)
  if series.len >= 2: result.add legend(block:
    var names: seq[string]
    for s in series: names.add s.name
    names)
  result.add yAxis(y)
  let groupW = PlotW / float(categories.len)
  let gap = 2.0
  let barW = max(1.0, (groupW * 0.8 - gap * float(series.len - 1)) / float(series.len))
  for j, category in categories:
    let x0 = Left + groupW * float(j) + groupW * 0.1
    for i, s in series:
      let value = s.points[j][1]
      let top = py(max(value, 0.0))
      let h = abs(py(value) - py(0.0))
      result.add "<rect class=\"s" & $i & "\" x=\"" & fixed(x0 + float(i) * (barW + gap), 2) &
        "\" y=\"" & fixed(top, 2) & "\" width=\"" & fixed(barW, 2) & "\" height=\"" &
        fixed(max(h, 0.5), 2) & "\" rx=\"" & (if barW >= 8: "2" else: "0") &
        "\"><title>" & escapeXml(s.name & ", " & category & ": " &
        fixed(value, 3) & y.unit) & "</title></rect>\n"
    if j mod labelEvery == 0:
      result.add "<text class=\"tick\" x=\"" & fixed(x0 + groupW * 0.4, 1) & "\" y=\"" &
        $(Top + PlotH + 18) & "\" text-anchor=\"middle\">" & escapeXml(category) & "</text>\n"
  result.add "<line class=\"baseline\" x1=\"" & $Left & "\" x2=\"" & $(Left + PlotW) &
    "\" y1=\"" & fixed(py(0.0), 1) & "\" y2=\"" & fixed(py(0.0), 1) & "\"/>\n"
  result.add xLabel(xAxisLabel)
  result.add "</svg>\n"

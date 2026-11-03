# Build tasks. Run from the repository root:
#
#   nim test    unit tests (C backend)
#   nim build   tests, then compile the app to JS and write index.html
#   nim plates  laser-cutting SVGs for the symbol plates (hardware/plates/)
#   nim sim     simulate the analog chain in ngspice and compare with the app's maths
#
# index.html is self-contained: the stylesheet and compiled app are inlined.

import "src/page.nim"
import "hardware/plates.nim"
import "hardware/simgen.nim"
import "src/model.nim", "src/odds.nim"
import std/math

const
  AppJs = "build/app.js"
  Page = "index.html"

task test, "Run the unit tests":
  for test in ["tests/test_odds.nim", "tests/test_plates.nim"]:
    exec "nim c -r --hints:off --outdir:build/tests " & test

task build, "Test, compile the app to JavaScript and write " & Page:
  exec "nim test"
  exec "nim js -d:release --hints:off -o:" & AppJs & " src/app.nim"
  writeFile(Page, renderPage(css = readFile("src/style.css"),
                             appJs = readFile(AppJs)))
  echo "wrote ", Page

task plates, "Write laser-cutting SVGs for the plates to hardware/plates/":
  const dir = "hardware/plates/"
  mkDir dir
  let plates = allPlates()
  for plate in plates:
    writeFile(dir & plate.fileName, plate.plateSvg)
  writeFile(dir & "sheet.svg", plates.sheetSvg)
  echo "wrote ", plates.len, " plates and sheet.svg to ", dir

task sim, "Simulate the analog chain (ngspice) against the app's maths":
  # (stacked symbols, blank card counts as safe, cards played, danger cards played)
  const scenarios = [
    ({Void}, false, 0, 0),
    ({Void, Caves}, true, 10, 3),
    ({Rocky, Desert, Caves}, false, 20, 5),
    ({Ruins}, true, 37, 1),
    ({Void .. Desert}, false, 0, 0),
    ({Hostile, Crystalline}, false, 30, 27)]
  var worst = 0.0
  for (symbols, blankSafe, played, dangerPlayed) in scenarios:
    var stack: seq[Plate]
    for symbol in symbols: stack.add plateFor(symbol)
    if blankSafe: stack.add blankSafePlate()
    let rule = if blankSafe: blankIsSafe else: blankIsDanger
    let safe = NotebookDeck.safe(symbols, rule)
    let odds = analyse(safe, Observation(played: played,
      counts: @[Count(cards: safe, played: played - dangerPlayed)]))
    let expected = 10.0 * odds.chanceAtLeastOne(1, Danger)
    let netlist = "build/sim/chain.cir"
    mkDir "build/sim"
    writeFile(netlist, chainNetlist(stack, played, dangerPlayed))
    let (output, code) = gorgeEx("ngspice -b " & netlist)
    if code != 0: quit "ngspice failed:\n" & output
    let vp = measured(output, "vp")
    let errorPercent = abs(vp - expected) * 10.0   # % of 10 V full scale
    worst = max(worst, errorPercent)
    echo $symbols, (if blankSafe: " +blank-safe" else: ""), "  n=", played,
      " d=", dangerPlayed, "  lit=", card(litPositions(stack)),
      "  app ", round(expected * 10, 2), "%  circuit ", round(vp * 10, 2), "%"
  echo "worst error ", round(worst, 3), "% of full scale"
  if worst > 0.5: quit "circuit disagrees with the app"
